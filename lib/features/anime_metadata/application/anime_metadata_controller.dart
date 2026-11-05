import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../player/domain/playback_engine.dart';
import '../domain/anime_filename.dart';
import '../domain/anime_subject.dart';
import '../infrastructure/bangumi_client.dart';
import '../infrastructure/metadata_store.dart';

class AnimeMetadataController extends ChangeNotifier {
  AnimeMetadataController({BangumiClient? client, MetadataStore? store})
    : client = client ?? BangumiClient(),
      store = store ?? MetadataStore();
  final BangumiClient client;
  final MetadataStore store;
  final Map<String, AnimeMatch> _entries = {};
  final Map<String, int> _revisions = {};
  final Map<String, ({DateTime date, List<AnimeSubject> subjects})> _queries =
      {};
  final Map<String, LocalMedia> _queue = {};
  final Map<int, String> _posters = {};
  final Map<int, Future<void>> _posterJobs = {};
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
      for (final entry in _entries.values) {
        if (entry.matcherVersion < animeMatcherVersion ||
            entry.manual ||
            entry.status == AnimeMatchStatus.failed ||
            entry.status == AnimeMatchStatus.queued ||
            entry.status == AnimeMatchStatus.ignored) {
          continue;
        }
        _queries[entry.query] = (
          date: entry.updatedAt,
          subjects: entry.candidates,
        );
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
    for (final video in media) {
      final key = animeMediaKey(video);
      var entry = _entries[key];
      if (entry != null &&
          !entry.manual &&
          ((entry.matcherVersion < animeMatcherVersion &&
                  entry.status != AnimeMatchStatus.matched) ||
              entry.query != AnimeFilename.parse(video.name).query)) {
        _entries.remove(key);
        entry = null;
      }
      if (entry?.subject case final AnimeSubject subject) {
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
    if (!_running) unawaited(_run());
  }

  void _enqueue(LocalMedia media) {
    final key = animeMediaKey(media);
    if (_queue.containsKey(key) ||
        _entries[key]?.status == AnimeMatchStatus.queued) {
      return;
    }
    final parsed = AnimeFilename.parse(media.name);
    if (parsed.title.isEmpty) return;
    _entries[key] = AnimeMatch(
      query: parsed.query,
      status: AnimeMatchStatus.queued,
      updatedAt: DateTime.now(),
    );
    _queue[key] = media;
  }

  Future<void> _run() async {
    _running = true;
    _notify();
    try {
      while (_queue.isNotEmpty && !_disposed && automatic) {
        final key = _queue.keys.first;
        final media = _queue.remove(key)!;
        final revision = _revisions[key] ?? 0;
        if (_entries[key]?.manual ?? false) continue;
        final parsed = AnimeFilename.parse(media.name);
        try {
          var cached = _queries[parsed.query];
          if (cached == null ||
              DateTime.now().difference(cached.date) >
                  const Duration(days: 7)) {
            final subjects = await client.search(parsed.query);
            cached = (date: DateTime.now(), subjects: subjects);
            _queries[parsed.query] = cached;
          }
          if (_disposed || revision != (_revisions[key] ?? 0)) continue;
          if (!automatic) {
            _entries.remove(key);
            continue;
          }
          final subject = confidentAnimeMatch(parsed, cached.subjects);
          _entries[key] = AnimeMatch(
            query: parsed.query,
            status: subject != null
                ? AnimeMatchStatus.matched
                : cached.subjects.isEmpty
                ? AnimeMatchStatus.notFound
                : AnimeMatchStatus.needsReview,
            updatedAt: DateTime.now(),
            subject: subject,
            candidates: cached.subjects,
          );
        } catch (exception) {
          if (_disposed || revision != (_revisions[key] ?? 0)) continue;
          _entries[key] = AnimeMatch(
            query: parsed.query,
            status: AnimeMatchStatus.failed,
            updatedAt: DateTime.now(),
            error: exception is BangumiException
                ? exception.message
                : '番剧匹配暂未完成，可稍后重试',
          );
        }
        await _save();
        _notify();
        if (_entries[key]?.subject case final AnimeSubject subject) {
          await _ensurePoster(subject);
        }
      }
    } finally {
      _running = false;
      _notify();
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

  Future<List<AnimeSubject>> search(String query) => client.search(query);

  Future<void> select(LocalMedia media, AnimeSubject? subject) async {
    await initialize();
    if (!_loaded || _disposed) throw StateError('番剧资料缓存不可用，请重试');
    final key = animeMediaKey(media);
    _revisions[key] = (_revisions[key] ?? 0) + 1;
    _queue.remove(key);
    _entries[key] = AnimeMatch(
      query: AnimeFilename.parse(media.name).query,
      status: subject == null
          ? AnimeMatchStatus.ignored
          : AnimeMatchStatus.matched,
      updatedAt: DateTime.now(),
      subject: subject,
      manual: true,
    );
    try {
      await store.write(automatic, Map.of(_entries));
      error = null;
    } catch (_) {
      error = '番剧关联未能保存，请重试';
      _notify();
      rethrow;
    }
    _notify();
    if (subject != null) unawaited(_ensurePoster(subject));
  }

  Future<void> _ensurePoster(AnimeSubject subject) async {
    if (_disposed ||
        subject.posterUrl == null ||
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
    if (!_loaded) {
      _initialization = null;
      await initialize();
    }
    if (!_loaded || _disposed || !automatic) return;
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
      _queries.remove(AnimeFilename.parse(item.name).query);
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
