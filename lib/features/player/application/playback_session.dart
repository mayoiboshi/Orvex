import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/playback_engine.dart';
import '../domain/playback_defaults.dart';
import '../../subtitles/domain/subtitle_models.dart';

class PlaybackSession extends ChangeNotifier {
  PlaybackSession({
    required this.createEngine,
    required this.resumeStore,
    this.onCheckpoint,
    this.prepare,
    this.subtitleSupport,
  });

  final PlaybackEngine Function() createEngine;
  final ResumeStore resumeStore;
  final SubtitleSupport? subtitleSupport;
  SubtitleChoice subtitleChoice = const SubtitleChoice.automatic();
  List<SubtitleCandidate> localSubtitles = const [];
  bool automaticSubtitles = true,
      subtitleBusy = false,
      findingSubtitles = false;
  String subtitleStatus = '', subtitleIssue = '', subtitleScanIssue = '';
  int _subtitleRevision = 0, _subtitleScanRevision = 0;
  bool _subtitleChoiceLoaded = false;
  Future<void> _subtitleRestoration = Future.value();
  Future<void> get subtitlesReady => _subtitleRestoration;
  String? get selectedLocalSubtitle =>
      _active?.externalTracks[frame.subtitleTrackId]?.key;
  final Future<void> Function(LocalMedia media, PlaybackFrame frame)?
  onCheckpoint;
  final Future<PreparedPlayback> Function(LocalMedia media)? prepare;
  List<LocalMedia> playlist = const [];
  bool autoNext = false;
  bool allowAutoNext = true;
  PlaybackDefaults defaults = const PlaybackDefaults();
  PlaybackDefaults currentDefaults = const PlaybackDefaults();
  PlaybackFit pictureFit = PlaybackFit.contain;
  bool Function(List<LocalMedia>, int)? _canAutoAdvance;
  int get playlistIndex =>
      playlist.indexWhere((item) => item.resumeKey == media?.resumeKey);
  bool get hasPrevious => playlistIndex > 0;
  bool get hasNext => playlistIndex >= 0 && playlistIndex + 1 < playlist.length;
  Future<void> previous() => hasPrevious
      ? open(
          playlist[playlistIndex - 1],
          queue: playlist,
          canAutoAdvance: _canAutoAdvance,
        )
      : Future.value();
  Future<void> next() => hasNext
      ? open(
          playlist[playlistIndex + 1],
          queue: playlist,
          canAutoAdvance: _canAutoAdvance,
        )
      : Future.value();

  /// Select from the active queue without changing its auto-advance boundary.
  Future<void> selectFromPlaylist(LocalMedia item, {Duration? startAt}) {
    if (!playlist.any((media) => media.resumeKey == item.resumeKey)) {
      return Future.value();
    }
    return open(
      item,
      queue: playlist,
      startAt: startAt,
      canAutoAdvance: _canAutoAdvance,
    );
  }

  void replacePlaylist(
    List<LocalMedia> queue, {
    bool Function(List<LocalMedia>, int)? canAutoAdvance,
  }) {
    if (_disposed || !queue.any((item) => item.resumeKey == media?.resumeKey)) {
      return;
    }
    playlist = List.unmodifiable(queue);
    _canAutoAdvance = canAutoAdvance;
    _notify();
  }

  _ActiveSession? _active;
  LocalMedia? media;
  PlaybackFrame frame = const PlaybackFrame();
  bool loading = false;
  String? error;
  int _generation = 0;
  bool _disposed = false;
  Future<void> _operations = Future.value();
  Future<void> _writes = Future.value();

  PlaybackEngine? get engine =>
      _active?.generation == _generation ? _active?.engine : null;
  bool get ready => engine != null && !loading;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void reportError(String message) {
    error = message;
    _notify();
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final result = _operations.then((_) => action());
    _operations = result.catchError((Object exception) {
      if (!_disposed) reportError('操作失败：$exception');
    });
    return _operations;
  }

  Future<void> open(
    LocalMedia source, {
    List<LocalMedia>? queue,
    Duration? startAt,
    bool Function(List<LocalMedia>, int)? canAutoAdvance,
  }) {
    if (_disposed) return Future.value();
    final generation = ++_generation;
    ++_subtitleRevision;
    ++_subtitleScanRevision;
    subtitleChoice = const SubtitleChoice.automatic();
    _subtitleChoiceLoaded = false;
    localSubtitles = const [];
    subtitleStatus = subtitleSupport == null ? '' : '正在恢复字幕选择…';
    subtitleIssue = subtitleScanIssue = '';
    subtitleBusy = findingSubtitles = false;
    media = source;
    playlist = List.unmodifiable(queue ?? [source]);
    _canAutoAdvance = canAutoAdvance;
    final preferences = currentDefaults = defaults;
    pictureFit = preferences.fit;
    frame = const PlaybackFrame();
    loading = true;
    error = null;
    _notify();
    return _enqueue(() async {
      try {
        await _retire();
        if (_disposed || generation != _generation) return;
        var start = startAt ?? Duration.zero;
        if (startAt == null) {
          try {
            start = await resumeStore.read(source.resumeKey);
          } catch (_) {
            if (generation == _generation) error = '无法读取上次进度，将从头播放';
          }
        }
        if (_disposed || generation != _generation) return;
        final prepared =
            await prepare?.call(source) ?? PreparedPlayback(source);
        if (_disposed || generation != _generation) {
          await prepared.release?.call();
          return;
        }
        _ActiveSession active;
        try {
          active = _ActiveSession(
            generation,
            prepared.media,
            createEngine(),
            prepared.release,
          );
        } catch (_) {
          await prepared.release?.call();
          rethrow;
        }
        media = prepared.media;
        _active = active;
        // VideoController initializes after a Flutter frame. Publish the
        // surface before awaiting open, otherwise first playback can deadlock.
        _notify();
        active.subscriptions.addAll([
          active.engine.frames.listen((next) => _onFrame(active, next)),
          active.engine.errors.listen((message) {
            if (_current(active)) reportError('播放失败：$message');
          }),
          active.engine.interruptions.listen((_) {
            if (_current(active)) unawaited(pauseForInterruption());
          }),
        ]);
        await active.engine.open(active.media, start: start);
        if (_current(active) && preferences.rate != 1) {
          try {
            await active.engine.setRate(preferences.rate);
          } catch (_) {
            if (_current(active)) error = '默认倍速未能应用，已沿用播放器速度';
          }
        }
      } catch (exception) {
        if (generation == _generation) error = '无法打开视频：$exception';
        await _retire();
      } finally {
        if (!_disposed && generation == _generation) {
          loading = false;
          if (_active case final active?) {
            _applyAudioDefault(active);
            _subtitleRestoration = _restoreSubtitles(active, _subtitleRevision);
          }
          _notify();
        }
      }
    });
  }

  bool _current(_ActiveSession active) =>
      !_disposed &&
      active.generation == _generation &&
      identical(_active, active);

  void _onFrame(_ActiveSession active, PlaybackFrame next) {
    if (!_current(active)) return;
    active.frame = next;
    frame = next;
    if (next.subtitleTracks.isNotEmpty && !active.tracksReady.isCompleted) {
      active.tracksReady.complete();
    }
    _applyAudioDefault(active);
    final pending = active.pendingSubtitle;
    if (pending != null) {
      for (final track in next.subtitleTracks) {
        if (track.id == next.subtitleTrackId &&
            track.label == pending.reference.name &&
            (!pending.before.contains(track.id) ||
                active.externalTracks[track.id]?.key ==
                    pending.reference.key)) {
          active.externalTracks[track.id] = pending.reference;
          if (!pending.selected.isCompleted) pending.selected.complete();
        }
      }
    }
    // Playback intent and buffering are separate fields, so buffering cannot
    // accidentally resume a video the user paused.
    if (next.duration > Duration.zero &&
        (next.completed ||
            (next.position - active.lastCheckpoint).abs() >=
                const Duration(seconds: 5) ||
            (active.wasPlaying && !next.playing))) {
      active.lastCheckpoint = next.position;
      unawaited(_save(active));
    }
    if (next.completed && !active.completedHandled) {
      active.completedHandled = true;
      if (autoNext &&
          allowAutoNext &&
          hasNext &&
          (_canAutoAdvance?.call(playlist, playlistIndex) ?? true)) {
        unawaited(this.next());
      }
    } else if (!next.completed) {
      active.completedHandled = false;
    }
    active.wasPlaying = next.playing;
    _notify();
  }

  Future<void> _save(_ActiveSession active) {
    final snapshot = active.frame;
    // Never overwrite a valid checkpoint with initialization's zero duration.
    if (snapshot.duration <= Duration.zero) return _writes;
    final position = snapshot.completed ? Duration.zero : snapshot.position;
    final key = active.media.resumeKey;
    _writes = _writes
        .then((_) async {
          await resumeStore.write(key, position);
          await onCheckpoint?.call(active.media, snapshot);
        })
        .catchError((Object _) {
          if (_current(active)) reportError('播放进度保存失败');
        });
    return _writes;
  }

  Future<void> checkpoint() async {
    final active = _active;
    if (active != null) await _save(active);
  }

  Future<void> _control(Future<void> Function(PlaybackEngine) action) {
    final generation = _generation;
    return _enqueue(() async {
      if (_disposed || generation != _generation || !ready) return;
      try {
        await action(engine!);
      } catch (exception) {
        if (generation == _generation) reportError('操作失败：$exception');
      }
    });
  }

  Future<void> togglePause() => _control((engine) => engine.togglePause());

  /// Interruptions are one-way pauses. Ending a call or returning to the app
  /// must never turn a user's pause into an unexpected automatic resume.
  Future<void> pauseForInterruption() {
    final generation = _generation;
    return _enqueue(() async {
      if (_disposed || generation != _generation) return;
      final active = _active;
      if (active == null) return;
      await active.engine.pause();
      await _save(active);
    });
  }

  Future<void> setRate(double rate) =>
      _control((engine) => engine.setRate(rate.clamp(0.25, 3)));
  void setPictureFit(PlaybackFit fit) {
    if (!ready) return;
    pictureFit = fit;
    _notify();
  }

  Future<void> setVolume(double volume) =>
      _control((engine) => engine.setVolume(volume.clamp(0, 100)));

  Future<void> seek(Duration target) => _control((engine) {
    final duration = frame.duration;
    if (duration <= Duration.zero) return Future.value();
    final bounded = target.inMilliseconds.clamp(0, duration.inMilliseconds);
    return engine.seek(Duration(milliseconds: bounded));
  });

  Future<void> selectAudio(String id) {
    if (_active case final active?) active.manualAudio = true;
    return _control((engine) => engine.selectAudio(id));
  }

  void _applyAudioDefault(_ActiveSession active) {
    if (loading ||
        active.manualAudio ||
        active.audioDefaultApplied ||
        currentDefaults.audioLanguage == TrackLanguage.fileDefault ||
        frame.audioTracks.isEmpty) {
      return;
    }
    active.audioDefaultApplied = true;
    final preferred = _preferredTrack(
      frame.audioTracks,
      frame.audioTrackId,
      currentDefaults.audioLanguage,
    );
    if (preferred == null) return;
    if (preferred.id == frame.audioTrackId) return;
    unawaited(
      _enqueue(() async {
        if (_current(active) &&
            !active.manualAudio &&
            frame.audioTracks.any((track) => track.id == preferred.id)) {
          await active.engine.selectAudio(preferred.id);
        }
      }),
    );
  }

  MediaTrack? _preferredTrack(
    List<MediaTrack> tracks,
    String? selected,
    TrackLanguage language,
  ) {
    final matches = tracks.where((track) => language.matches(track.language));
    return matches.where((track) => track.id == selected).firstOrNull ??
        matches.firstOrNull;
  }

  Future<void> selectSubtitle(String id) {
    if (subtitleSupport == null) {
      return _control((engine) => engine.selectSubtitle(id));
    }
    final active = _active;
    if (active == null || !ready) return Future.value();
    final revision = ++_subtitleRevision;
    subtitleBusy = false;
    return _enqueue(() async {
      if (!_subtitleCurrent(active, revision)) return;
      try {
        await active.engine.selectSubtitle(id);
        if (!_subtitleCurrent(active, revision)) return;
        final external = active.externalTracks[id];
        final track = frame.subtitleTracks
            .where((track) => track.id == id)
            .firstOrNull;
        subtitleChoice = id == 'no'
            ? const SubtitleChoice.off()
            : id == 'auto'
            ? const SubtitleChoice.automatic()
            : external != null
            ? SubtitleChoice.external(external)
            : track != null
            ? SubtitleChoice.embedded(track)
            : const SubtitleChoice.automatic();
        _subtitleChoiceLoaded = true;
        subtitleIssue = '';
        subtitleStatus = id == 'no'
            ? '已记住：关闭字幕'
            : id == 'auto'
            ? '自动选择字幕'
            : '已记住：${track?.label ?? id}';
        final remembered = await _rememberSubtitle(active, revision);
        if (id == 'auto' && _subtitleCurrent(active, revision)) {
          final choice = subtitleChoice;
          _subtitleRestoration = () async {
            await _restoreSubtitles(active, revision, choice: choice);
            if (!remembered && _subtitleCurrent(active, revision)) {
              subtitleIssue = '本次选择已生效，但字幕记忆未能保存';
              _notify();
            }
          }();
        }
      } catch (error) {
        if (_subtitleCurrent(active, revision)) subtitleIssue = '字幕选择失败：$error';
      } finally {
        if (_subtitleCurrent(active, revision)) _notify();
      }
    });
  }

  Future<void> loadSubtitle(LocalMedia source) => subtitleSupport != null
      ? chooseLocalSubtitle(SubtitleReference.imported(source))
      : _control((engine) async {
          error = null;
          _notify();
          // Selection is derived from the engine's track stream, never set optimistically.
          await engine.loadSubtitle(source.uri, source.name);
        });

  bool _subtitleCurrent(_ActiveSession active, int revision) =>
      _current(active) && revision == _subtitleRevision;

  Future<bool> _rememberSubtitle(_ActiveSession active, int revision) async {
    if (!_subtitleCurrent(active, revision)) return false;
    try {
      await subtitleSupport!.remember(active.media, subtitleChoice);
      return true;
    } catch (_) {
      if (_subtitleCurrent(active, revision)) {
        subtitleIssue = '本次选择已生效，但字幕记忆未能保存';
      }
      return false;
    }
  }

  Future<List<SubtitleCandidate>?> refreshLocalSubtitles() async {
    final active = _active;
    if (subtitleSupport == null || active == null || !ready) return null;
    final scan = ++_subtitleScanRevision;
    findingSubtitles = true;
    subtitleScanIssue = '';
    _notify();
    try {
      final results = await subtitleSupport!.discover(active.media);
      if (!_current(active) || scan != _subtitleScanRevision) return null;
      localSubtitles = results;
      return results;
    } catch (error) {
      if (_current(active) && scan == _subtitleScanRevision) {
        subtitleScanIssue = '本地字幕暂不可读取：$error';
      }
      return null;
    } finally {
      if (_current(active) && scan == _subtitleScanRevision) {
        findingSubtitles = false;
        _notify();
      }
    }
  }

  Future<void> _restoreSubtitles(
    _ActiveSession active,
    int revision, {
    SubtitleChoice? choice,
  }) async {
    if (subtitleSupport == null || !_subtitleCurrent(active, revision)) return;
    subtitleBusy = true;
    _notify();
    try {
      final saved = choice ?? await subtitleSupport!.readChoice(active.media);
      final automatic = await subtitleSupport!.automaticMatching();
      if (!_subtitleCurrent(active, revision)) return;
      subtitleChoice = saved;
      _subtitleChoiceLoaded = true;
      automaticSubtitles = automatic;
      if (saved.mode == SubtitleChoiceMode.external) {
        subtitleStatus = '记住的字幕：${saved.reference!.name}';
        await _applySubtitleReference(
          active,
          revision,
          saved.reference!,
          remember: false,
        );
      } else if (saved.mode == SubtitleChoiceMode.off) {
        await _enqueue(() async {
          if (!_subtitleCurrent(active, revision)) return;
          await active.engine.selectSubtitle('no');
          if (_subtitleCurrent(active, revision)) subtitleStatus = '已恢复：关闭字幕';
        });
      } else if (saved.mode == SubtitleChoiceMode.embedded) {
        if (frame.subtitleTracks.isEmpty) {
          await active.tracksReady.future.timeout(
            const Duration(seconds: 2),
            onTimeout: () {},
          );
        }
        if (!_subtitleCurrent(active, revision)) return;
        final tracks = frame.subtitleTracks
            .where((t) => t.label == saved.track!.label)
            .toList();
        final track =
            tracks.where((t) => t.id == saved.track!.id).firstOrNull ??
            (tracks.length == 1 ? tracks.single : null);
        if (track == null) {
          subtitleIssue = '记住的字幕轨道已不可用，请重新选择';
        } else {
          await _enqueue(() async {
            if (!_subtitleCurrent(active, revision)) return;
            await active.engine.selectSubtitle(track.id);
            if (_subtitleCurrent(active, revision)) {
              subtitleStatus = '已恢复：${track.label}';
            }
          });
        }
      } else {
        // An explicitly configured language takes precedence over filename matching.
        if (await _applyPreferredSubtitle(active, revision) ||
            !_subtitleCurrent(active, revision)) {
          return;
        }
        if (!automatic) {
          subtitleStatus = '本地字幕自动匹配已关闭';
          return;
        }
        final candidates = await refreshLocalSubtitles();
        if (!_subtitleCurrent(active, revision) || candidates == null) return;
        final match = uniqueSubtitleMatch(candidates);
        if (match == null) {
          subtitleStatus = candidates.any((c) => c.match != SubtitleMatch.none)
              ? '找到多个匹配字幕，请手动选择'
              : '没有匹配的本地字幕，可手动选择';
        } else {
          await _applySubtitleReference(
            active,
            revision,
            match.reference,
            remember: false,
            reason: match.reason,
          );
        }
      }
      if (_subtitleCurrent(active, revision) &&
          saved.mode != SubtitleChoiceMode.automatic &&
          subtitleIssue.isNotEmpty) {
        final preferred = await _applyPreferredSubtitle(active, revision);
        if (!preferred) {
          await _enqueue(() async {
            if (_subtitleCurrent(active, revision)) {
              final useFileDefault =
                  currentDefaults.subtitleLanguage != TrackLanguage.fileDefault;
              await active.engine.selectSubtitle(
                useFileDefault ? 'auto' : 'no',
              );
            }
          });
        }
      }
    } catch (error) {
      if (_subtitleCurrent(active, revision)) {
        subtitleIssue = '字幕恢复失败，请重新选择：$error';
      }
    } finally {
      if (_subtitleCurrent(active, revision)) {
        subtitleBusy = false;
        _notify();
      }
    }
  }

  Future<bool> _applyPreferredSubtitle(
    _ActiveSession active,
    int revision,
  ) async {
    final language = currentDefaults.subtitleLanguage;
    if (language == TrackLanguage.fileDefault) return false;
    if (frame.subtitleTracks.isEmpty) {
      await active.tracksReady.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
    }
    if (!_subtitleCurrent(active, revision)) return false;
    final preferred = _preferredTrack(
      frame.subtitleTracks
          .where((track) => !active.externalTracks.containsKey(track.id))
          .toList(),
      frame.subtitleTrackId,
      language,
    );
    if (preferred == null) return false;
    await _enqueue(() async {
      if (!_subtitleCurrent(active, revision)) return;
      if (frame.subtitleTrackId != preferred.id) {
        await active.engine.selectSubtitle(preferred.id);
      }
      if (_subtitleCurrent(active, revision)) {
        subtitleStatus = '已按语言偏好选择：${preferred.label}';
      }
    });
    return _subtitleCurrent(active, revision);
  }

  Future<void> _applySubtitleReference(
    _ActiveSession active,
    int revision,
    SubtitleReference reference, {
    required bool remember,
    String? reason,
  }) async {
    PreparedSubtitle? prepared;
    var retained = false;
    try {
      prepared = await subtitleSupport!.prepare(reference);
      if (!_subtitleCurrent(active, revision)) return;
      await _enqueue(() async {
        if (!_subtitleCurrent(active, revision)) return;
        if (prepared!.release != null) {
          active.subtitleReleases.add(prepared.release!);
        }
        retained = true;
        final pending = _SubtitleLoad(
          reference,
          frame.subtitleTracks.map((t) => t.id).toSet(),
        );
        active.pendingSubtitle = pending;
        try {
          await active.engine.loadSubtitle(
            prepared.media.uri,
            prepared.media.name,
          );
          if (_subtitleCurrent(active, revision) &&
              !pending.selected.isCompleted) {
            await pending.selected.future.timeout(
              const Duration(seconds: 1),
              onTimeout: () {},
            );
          }
          if (!_subtitleCurrent(active, revision)) return;
          subtitleIssue = '';
          subtitleStatus =
              '${remember ? '已记住' : reason ?? '已恢复'}：${reference.name}';
          if (remember) {
            subtitleChoice = SubtitleChoice.external(reference);
            _subtitleChoiceLoaded = true;
            await _rememberSubtitle(active, revision);
          }
        } catch (error) {
          if (_subtitleCurrent(active, revision)) {
            subtitleIssue = '字幕未能加载，可重新选择：$error';
          }
        } finally {
          if (identical(active.pendingSubtitle, pending)) {
            active.pendingSubtitle = null;
          }
        }
      });
    } catch (error) {
      if (_subtitleCurrent(active, revision)) {
        subtitleIssue = '字幕未能加载，可重新选择：$error';
      }
    } finally {
      if (!retained) {
        try {
          await prepared?.release?.call();
        } catch (_) {
          if (_subtitleCurrent(active, revision)) {
            subtitleIssue = '字幕授权未能释放，请重启 App';
          }
        }
      }
    }
  }

  Future<void> chooseLocalSubtitle(SubtitleReference reference) async {
    final active = _active;
    if (subtitleSupport == null || active == null || !ready) return;
    final revision = ++_subtitleRevision;
    subtitleBusy = true;
    _notify();
    try {
      await _applySubtitleReference(
        active,
        revision,
        reference,
        remember: true,
      );
    } finally {
      if (_subtitleCurrent(active, revision)) {
        subtitleBusy = false;
        _notify();
      }
    }
  }

  Future<void> setAutomaticSubtitleMatching(bool value) async {
    final support = subtitleSupport;
    if (support == null) return;
    final active = _active;
    final revision = ++_subtitleRevision;
    automaticSubtitles = value;
    subtitleBusy = false;
    _notify();
    try {
      await support.setAutomaticMatching(value);
      if (active != null &&
          _subtitleCurrent(active, revision) &&
          (!_subtitleChoiceLoaded ||
              subtitleChoice.mode == SubtitleChoiceMode.automatic)) {
        _subtitleRestoration = _restoreSubtitles(active, revision);
      }
    } catch (_) {
      if (active != null && _subtitleCurrent(active, revision)) {
        subtitleIssue = '自动匹配设置未能保存';
      }
    }
    if (!_disposed) _notify();
  }

  Future<void> _retire() async {
    final active = _active;
    _active = null;
    if (active == null) return;
    for (final subscription in active.subscriptions) {
      await subscription.cancel();
    }
    try {
      await _save(active);
    } finally {
      try {
        await active.engine.dispose();
      } finally {
        try {
          await Future.wait(
            active.subtitleReleases.map((release) => release()),
          );
        } finally {
          await active.release?.call();
        }
      }
    }
  }

  Future<void> close() {
    ++_generation;
    ++_subtitleRevision;
    ++_subtitleScanRevision;
    subtitleBusy = findingSubtitles = false;
    media = null;
    playlist = const [];
    frame = const PlaybackFrame();
    loading = false;
    error = null;
    _notify();
    return _enqueue(_retire);
  }

  Future<void> shutdown() {
    _disposed = true;
    ++_generation;
    return _enqueue(_retire);
  }

  @override
  void dispose() {
    unawaited(shutdown());
    super.dispose();
  }
}

class _ActiveSession {
  _ActiveSession(this.generation, this.media, this.engine, this.release);
  final int generation;
  final LocalMedia media;
  final PlaybackEngine engine;
  final Future<void> Function()? release;
  bool completedHandled = false;
  bool manualAudio = false, audioDefaultApplied = false;
  final List<StreamSubscription<dynamic>> subscriptions = [];
  PlaybackFrame frame = const PlaybackFrame();
  Duration lastCheckpoint = Duration.zero;
  bool wasPlaying = false;
  final tracksReady = Completer<void>();
  final subtitleReleases = <Future<void> Function()>[];
  final externalTracks = <String, SubtitleReference>{};
  _SubtitleLoad? pendingSubtitle;
}

class _SubtitleLoad {
  _SubtitleLoad(this.reference, this.before);
  final SubtitleReference reference;
  final Set<String> before;
  final selected = Completer<void>();
}

class PreparedPlayback {
  const PreparedPlayback(this.media, [this.release]);
  final LocalMedia media;
  final Future<void> Function()? release;
}
