import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../player/domain/playback_engine.dart';
import '../domain/anime_episode.dart';
import '../domain/anime_filename.dart';
import '../domain/anime_subject.dart';
import '../infrastructure/bangumi_client.dart';
import '../infrastructure/bangumi_data_index.dart';
import '../infrastructure/metadata_store.dart';

class AnimeMetadataController extends ChangeNotifier {
  AnimeMetadataController({
    BangumiClient? client,
    MetadataStore? store,
    this.queryResolver,
    this.groupResolver,
    this.localIndex,
    this.isOffline = definitelyOffline,
  }) : client = client ?? BangumiClient(),
       store = store ?? MetadataStore();
  final String Function(LocalMedia)? queryResolver, groupResolver;
  String queryFor(LocalMedia media) =>
      queryResolver?.call(media) ?? AnimeFilename.parse(media.name).query;
  final BangumiClient client;
  final BangumiDataAsset? localIndex;
  final Future<bool> Function() isOffline;
  static const offlineFallbackKey = 'orvex.metadata.offline-fallback.v1';
  bool offlineFallback = true;
  int _fallbackRevision = 0;
  DateTime? _unavailableUntil;
  String? _unavailableReason;
  final MetadataStore store;
  final Map<String, AnimeMatch> _entries = {};
  final Map<String, int> _revisions = {};
  final Map<String, ({DateTime date, List<AnimeSubject> subjects})> _queries =
      {};
  final Map<String, LocalMedia> _queue = {};
  final Map<int, AnimeSubject> _onlineDetails = {};
  final Map<int, String> _posters = {};
  final Map<int, Future<void>> _posterJobs = {};
  final _episodes = <int, List<AnimeEpisode>>{};
  final _episodeRequests = <int, Future<List<AnimeEpisode>>>{};
  late final _episodePreferences = SharedPreferencesAsync();
  List<LocalMedia> _media = [];
  Future<void>? _initialization;
  bool _loaded = false;
  bool _running = false;
  bool _disposed = false;
  bool automatic = true;
  String? error;

  bool get busy => _running || _queue.isNotEmpty || _posterJobs.isNotEmpty;
  String? posterPath(int subjectId) => _posters[subjectId];
  AnimeMatch? matchFor(LocalMedia media) => _entries[animeMediaKey(media)];
  AnimeSubject? subjectFor(LocalMedia media) => matchFor(media)?.subject;

  Future<List<AnimeEpisode>> episodesFor(int subjectId) async {
    final cached = _episodes[subjectId];
    if (cached != null) return cached;
    final pending = _episodeRequests[subjectId];
    if (pending != null) return pending;
    final request = _episodeRequests[subjectId] = client.episodes(subjectId);
    try {
      final episodes = await request;
      if (!_disposed) {
        if (_episodes.length >= 8) _episodes.remove(_episodes.keys.first);
        _episodes[subjectId] = episodes;
      }
      return episodes;
    } finally {
      _episodeRequests.remove(subjectId);
    }
  }

  String _episodeKey(LocalMedia media, int subjectId) =>
      'orvex.bangumi.episode.v1:$subjectId:${media.resumeKey}';

  Future<AnimeEpisode?> savedEpisode(LocalMedia media, int subjectId) async {
    final saved = await _episodePreferences.getString(
      _episodeKey(media, subjectId),
    );
    if (saved == null) return null;
    try {
      return AnimeEpisode.fromJson(jsonDecode(saved) as Map<String, dynamic>);
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Future<void> saveEpisode(
    LocalMedia media,
    int subjectId,
    AnimeEpisode? episode,
  ) {
    final key = _episodeKey(media, subjectId);
    return episode == null
        ? _episodePreferences.remove(key)
        : _episodePreferences.setString(key, jsonEncode(episode.toJson()));
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() => _initialization ??= _load();

  Future<void> _load() async {
    try {
      final data = await store.read();
      if (_disposed) return;
      automatic = data.automatic;
      _entries.addEntries(
        data.entries.entries.where(
          (entry) => entry.value.status != AnimeMatchStatus.queued,
        ),
      );
      _posters.addAll(await store.posters());
      if (localIndex != null) {
        try {
          offlineFallback =
              await _episodePreferences.getBool(offlineFallbackKey) ?? true;
        } catch (_) {
          // A preference read failure must not make existing metadata unusable.
        }
      }
      for (final entry in _entries.values) {
        _rememberOnlineDetails(entry.subject);
        if (entry.manual ||
            entry.usedLocalIndex ||
            entry.status == AnimeMatchStatus.failed ||
            entry.status == AnimeMatchStatus.queued ||
            entry.status == AnimeMatchStatus.ignored) {
          continue;
        }
        final key = normalizedAnimeTitle(entry.query);
        if (_queries[key] == null ||
            entry.updatedAt.isAfter(_queries[key]!.date)) {
          _queries[key] = (date: entry.updatedAt, subjects: entry.candidates);
        }
      }
      _loaded = true;
      error = null;
    } catch (_) {
      error = '番剧资料缓存未能读取，请重试';
    }
    _notify();
  }

  Future<void> scan(List<LocalMedia> media) async {
    _media = List.of(media);
    await initialize();
    if (_disposed || !_loaded || !automatic) return;
    final manualGroups = <String, AnimeMatch>{};
    if (groupResolver != null) {
      for (final item in media) {
        final saved = _entries[animeMediaKey(item)];
        if (saved?.manual == true) {
          final group = groupResolver!(item);
          if (manualGroups[group] == null ||
              saved!.updatedAt.isAfter(manualGroups[group]!.updatedAt)) {
            manualGroups[group] = saved!;
          }
        }
      }
    }
    var inherited = false;
    for (final video in media) {
      final key = animeMediaKey(video);
      var entry = _entries[key];
      if (entry != null &&
          !entry.manual &&
          ((entry.matcherVersion < animeMatcherVersion &&
                  entry.status != AnimeMatchStatus.matched) ||
              normalizedAnimeTitle(entry.query) !=
                  normalizedAnimeTitle(queryFor(video)))) {
        _entries.remove(key);
        _revisions[key] = (_revisions[key] ?? 0) + 1;
        _queue.remove(key);
        entry = null;
      }
      final manual = groupResolver == null
          ? null
          : manualGroups[groupResolver!(video)];
      if (entry == null && manual != null) {
        entry = AnimeMatch(
          query: queryFor(video),
          status: manual.status,
          updatedAt: manual.updatedAt,
          subject: manual.subject,
          manual: true,
          usedLocalIndex: manual.usedLocalIndex,
        );
        _entries[key] = entry;
        inherited = true;
      }
      if (entry?.subject case final AnimeSubject subject
          when entry?.usedLocalIndex != true) {
        unawaited(_ensurePoster(subject));
      }
      if (entry != null) {
        if (entry.manual ||
            entry.status == AnimeMatchStatus.matched ||
            entry.status == AnimeMatchStatus.ignored) {
          continue;
        }
        final age = DateTime.now().difference(entry.updatedAt);
        if (entry.status == AnimeMatchStatus.failed &&
            age < const Duration(minutes: 15)) {
          continue;
        }
        if ((entry.status == AnimeMatchStatus.notFound ||
                entry.status == AnimeMatchStatus.needsReview) &&
            age < const Duration(days: 7)) {
          continue;
        }
      }
      _enqueue(video);
    }
    if (inherited) await _save();
    if (!_running) unawaited(_run());
  }

  void _enqueue(LocalMedia media) {
    final key = animeMediaKey(media);
    if (_queue.containsKey(key) ||
        _entries[key]?.status == AnimeMatchStatus.queued) {
      return;
    }
    final query = queryFor(media);
    if (query.trim().length < 2) return;
    _entries[key] = AnimeMatch(
      query: query,
      status: AnimeMatchStatus.queued,
      updatedAt: DateTime.now(),
    );
    _queue[key] = media;
  }

  Future<void> _run() async {
    var unsavedLocal = 0;
    _running = true;
    _notify();
    try {
      while (_queue.isNotEmpty && !_disposed && automatic) {
        final groups = <String, List<String>>{};
        for (final item in _queue.entries) {
          (groups[normalizedAnimeTitle(queryFor(item.value))] ??= []).add(
            item.key,
          );
        }
        for (final group in groups.entries) {
          if (_disposed || !automatic) break;
          final queryKey = group.key;
          final batch = <String, ({LocalMedia media, int revision})>{};
          for (final key in group.value) {
            final video = _queue[key];
            if (video == null ||
                normalizedAnimeTitle(queryFor(video)) != queryKey) {
              continue;
            }
            _queue.remove(key);
            batch[key] = (media: video, revision: _revisions[key] ?? 0);
          }
          if (batch.isEmpty) continue;
          final key = batch.keys.first;
          final query = queryFor(batch[key]!.media);
          bool current(String key) =>
              !_disposed &&
              automatic &&
              batch[key]?.revision == (_revisions[key] ?? 0) &&
              _entries[key]?.status == AnimeMatchStatus.queued;
          bool anyCurrent() => batch.keys.any(current);
          final fallbackRevision = _fallbackRevision;
          List<AnimeSubject>? online;
          BangumiDataIndex? local;
          String? failure;
          var usedLocal = false;
          try {
            online = await _online(query, queryKey, anyCurrent);
          } catch (exception) {
            if (!anyCurrent()) continue;
            failure = exception is BangumiException
                ? exception.message
                : '番剧匹配暂未完成，可稍后重试';
            if (localIndex != null &&
                offlineFallback &&
                fallbackRevision == _fallbackRevision &&
                _unavailable(exception)) {
              usedLocal = true;
              try {
                local = await localIndex!.index;
              } catch (_) {
                failure = '本地番剧索引加载失败（资源缺失、损坏或版本不兼容）';
              }
            }
          }
          for (final item in batch.entries) {
            if (!current(item.key)) continue;
            if (usedLocal &&
                (fallbackRevision != _fallbackRevision || !offlineFallback)) {
              _entries.remove(item.key);
              continue;
            }
            final video = item.value.media;
            final found = local?.match(queryFor(video), video.name);
            final candidates =
                online ?? found?.candidates ?? const <AnimeSubject>[];
            final foundSubject = online != null
                ? online.firstOrNull
                : found?.subject;
            final subject = _preferSavedDetails(foundSubject);
            _rememberOnlineDetails(subject);
            _entries[item.key] = AnimeMatch(
              query: queryFor(video),
              status: subject != null
                  ? AnimeMatchStatus.matched
                  : online != null
                  ? AnimeMatchStatus.notFound
                  : found == null
                  ? AnimeMatchStatus.failed
                  : candidates.isEmpty
                  ? AnimeMatchStatus.notFound
                  : AnimeMatchStatus.needsReview,
              updatedAt: DateTime.now(),
              subject: subject,
              candidates: candidates,
              error: local == null ? failure : null,
              usedLocalIndex: usedLocal,
            );
          }
          if (_disposed) break;
          if (usedLocal) {
            // Commit local work in groups. The CPU and UI get a turn between groups.
            if (++unsavedLocal < 20) {
              await Future<void>.delayed(Duration.zero);
              continue;
            }
          }
          await _save();
          unsavedLocal = 0;
          _notify();
          if (_entries[key]?.subject case final AnimeSubject subject
              when !usedLocal) {
            await _ensurePoster(subject);
          }
        }
      }
    } finally {
      if (!_disposed && unsavedLocal > 0) await _save();
      _running = false;
      _notify();
      if (!_disposed && automatic && _queue.isNotEmpty) unawaited(_run());
    }
  }

  Future<void> _save() async {
    try {
      await store.write(automatic, Map.of(_entries));
      error = null;
    } catch (_) {
      error = '番剧资料暂未保存到本机，请检查剩余空间后重试';
    }
  }

  Future<void> setAutomatic(bool enabled) async {
    await initialize();
    if (!_loaded || _disposed) return;
    automatic = enabled;
    if (!enabled) {
      for (final key
          in _entries.keys
              .where((key) => _entries[key]?.status == AnimeMatchStatus.queued)
              .toList()) {
        _entries.remove(key);
        _revisions[key] = (_revisions[key] ?? 0) + 1;
      }
      _queue.clear();
    }
    await _save();
    _notify();
    if (enabled) await scan(_media);
  }

  static bool _unavailable(Object error) =>
      error is SocketException ||
      error is TimeoutException ||
      error is BangumiException && error.kind == BangumiFailure.unavailable;

  Future<List<AnimeSubject>> _online(
    String query,
    String? cacheKey,
    bool Function() isCurrent,
  ) async {
    final cached = _queries[cacheKey];
    final fresh =
        cached != null &&
        DateTime.now().difference(cached.date) <= const Duration(days: 7);
    if (fresh && (localIndex == null || cached.subjects.isNotEmpty)) {
      return cached.subjects;
    }
    if (localIndex != null) {
      if (_unavailableUntil?.isAfter(DateTime.now()) == true) {
        throw BangumiException(
          _unavailableReason!,
          kind: BangumiFailure.unavailable,
        );
      }
      if (await isOffline()) {
        const reason = '设备没有可用网络接口';
        if (isCurrent()) {
          _unavailableUntil = DateTime.now().add(const Duration(seconds: 2));
          _unavailableReason = reason;
        }
        throw const BangumiException(reason, kind: BangumiFailure.unavailable);
      }
    }
    if (!isCurrent()) {
      throw const BangumiException('搜索已取消', kind: BangumiFailure.cancelled);
    }
    if (fresh) return cached.subjects;
    try {
      final subjects = await client.search(query);
      if (cacheKey != null && isCurrent()) {
        _queries[cacheKey] = (date: DateTime.now(), subjects: subjects);
      }
      return subjects;
    } catch (error) {
      if (localIndex != null && isCurrent() && _unavailable(error)) {
        _unavailableUntil = DateTime.now().add(const Duration(seconds: 60));
        _unavailableReason = error is BangumiException
            ? error.message
            : 'Bangumi 无法访问';
      }
      rethrow;
    }
  }

  void _rememberOnlineDetails(AnimeSubject? subject) {
    final id = subject?.bangumiId;
    if (id != null && !subject!.fromLocalIndex) _onlineDetails[id] = subject;
  }

  AnimeSubject? _preferSavedDetails(
    AnimeSubject? subject, {
    bool preserveNames = false,
  }) {
    final online = _onlineDetails[subject?.bangumiId];
    return subject != null && subject.fromLocalIndex && online != null
        ? subject.withBangumiDetails(online, preserveNames: preserveNames)
        : subject;
  }

  Future<void> setOfflineFallback(bool enabled) async {
    await initialize();
    if (_disposed) return;
    final revision = ++_fallbackRevision;
    try {
      await _episodePreferences.setBool(offlineFallbackKey, enabled);
      if (_disposed || revision != _fallbackRevision) return;
      offlineFallback = enabled;
      _notify();
    } catch (_) {
      error = '离线备用偏好未能保存，请重试';
      _notify();
    }
  }

  Future<({List<AnimeSubject> subjects, bool local})> search(
    String query, {
    bool localOnly = false,
    bool Function()? isCurrent,
  }) async {
    await initialize();
    bool current() => !_disposed && (isCurrent?.call() ?? true);
    if (!current()) return (subjects: const <AnimeSubject>[], local: false);
    if (!localOnly) {
      // An explicit search can try the online source again.
      _unavailableUntil = null;
      try {
        final subjects = await _online(query, null, current);
        return (subjects: subjects, local: false);
      } catch (error) {
        if (!current() ||
            !_unavailable(error) ||
            !offlineFallback ||
            localIndex == null) {
          rethrow;
        }
      }
    }
    if (!current()) return (subjects: const <AnimeSubject>[], local: true);
    try {
      final index = await localIndex!.index;
      return (
        subjects: current() ? index.search(query) : const <AnimeSubject>[],
        local: true,
      );
    } catch (_) {
      throw const FormatException('本地番剧索引加载失败（资源缺失、损坏或版本不兼容）');
    }
  }

  Future<void> completeFromBangumi(
    LocalMedia media, {
    bool Function()? isCurrent,
  }) async {
    await initialize();
    final target = matchFor(media);
    final subject = target?.subject;
    final id = subject?.bangumiId;
    if (_disposed || id == null || subject?.fromLocalIndex != true) return;
    final pending = Map.of(_entries)
      ..removeWhere(
        (_, match) =>
            match.subject?.bangumiId != id ||
            match.subject?.fromLocalIndex != true,
      );
    final online = await client.subject(id);
    if (_disposed ||
        (isCurrent?.call() == false) ||
        !identical(matchFor(media), target)) {
      return;
    }
    _rememberOnlineDetails(online);
    for (final entry in pending.entries) {
      if (!identical(_entries[entry.key], entry.value)) continue;
      final saved = entry.value;
      _entries[entry.key] = AnimeMatch(
        query: saved.query,
        status: saved.status,
        updatedAt: saved.updatedAt,
        subject: saved.subject!.withBangumiDetails(
          online,
          preserveNames: saved.manual,
        ),
        candidates: saved.candidates,
        manual: saved.manual,
        usedLocalIndex: saved.usedLocalIndex,
        matcherVersion: saved.matcherVersion,
      );
    }
    await _save();
    _notify();
    unawaited(_ensurePoster(online));
  }

  Future<void> select(LocalMedia media, AnimeSubject? subject) =>
      selectMany([media], subject);
  Future<void> selectMany(List<LocalMedia> media, AnimeSubject? subject) async {
    await initialize();
    if (!_loaded || _disposed) throw StateError('番剧资料缓存不可用，请重试');
    for (final item in media) {
      final key = animeMediaKey(item);
      _revisions[key] = (_revisions[key] ?? 0) + 1;
      _queue.remove(key);
      _entries[key] = AnimeMatch(
        query: queryFor(item),
        status: subject == null
            ? AnimeMatchStatus.ignored
            : AnimeMatchStatus.matched,
        updatedAt: DateTime.now(),
        subject: _preferSavedDetails(subject, preserveNames: true),
        manual: true,
        usedLocalIndex: subject?.fromLocalIndex ?? false,
      );
    }
    try {
      await store.write(automatic, Map.of(_entries));
      error = null;
    } catch (_) {
      error = '番剧关联未能保存，请重试';
      _notify();
      rethrow;
    }
    _rememberOnlineDetails(subject);
    _notify();
    if (subject != null && !subject.fromLocalIndex) {
      unawaited(_ensurePoster(subject));
    }
  }

  Future<void> _ensurePoster(AnimeSubject subject) async {
    if (_disposed ||
        subject.posterUrl == null ||
        subject.bangumiId == null ||
        _posters.containsKey(subject.id)) {
      return;
    }
    if (_posterJobs[subject.id] case final Future<void> pending) return pending;
    final job = _downloadPoster(subject);
    _posterJobs[subject.id] = job;
    _notify();
    try {
      await job;
    } finally {
      _posterJobs.remove(subject.id);
      _notify();
    }
  }

  Future<void> _downloadPoster(AnimeSubject subject) async {
    try {
      final bytes = await client.fetchPoster(subject.posterUrl!);
      if (_disposed) return;
      _posters[subject.id] = await store.savePoster(subject.id, bytes);
    } catch (_) {
      if (!_disposed) error = '部分封面未能下载，联网后可重试；番剧资料仍可查看';
    }
  }

  Future<void> retry([LocalMedia? media]) async {
    error = null;
    _unavailableUntil = null;
    if (!_loaded) {
      _initialization = null;
      await initialize();
    }
    if (!_loaded || _disposed || !automatic) return;
    if (media != null && matchFor(media)?.subject?.fromLocalIndex == true) {
      await completeFromBangumi(media);
      return;
    }
    if (media != null && matchFor(media)?.manual == true) return;
    final items = media == null ? _media : [media];
    for (final item in items) {
      final key = animeMediaKey(item);
      if (media == null &&
          ((_entries[key]?.manual ?? false) ||
              _entries[key]?.status == AnimeMatchStatus.matched ||
              _entries[key]?.status == AnimeMatchStatus.queued)) {
        if (_entries[key]?.subject case final AnimeSubject subject) {
          unawaited(_ensurePoster(subject));
        }
        continue;
      }
      _revisions[key] = (_revisions[key] ?? 0) + 1;
      _entries.remove(key);
      _queries.remove(normalizedAnimeTitle(queryFor(item)));
      if (automatic) _enqueue(item);
    }
    if (!_running && automatic) unawaited(_run());
    await _save();
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _queue.clear();
    client.close();
    super.dispose();
  }
}
