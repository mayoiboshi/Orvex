import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/playback_engine.dart';
import '../domain/playback_defaults.dart';
import '../domain/subtitle_style.dart';
import '../../subtitles/domain/subtitle_models.dart';

class PlaybackSession extends ChangeNotifier {
  PlaybackSession({
    required this.createEngine,
    required this.resumeStore,
    this.onCheckpoint,
    this.prepare,
    this.subtitleSupport,
    this.subtitleStyleStore,
    this.exclusivePlayback = false,
    this.playbackReservation,
  });

  final PlaybackEngine Function() createEngine;
  final bool exclusivePlayback;
  final PlaybackReservation? playbackReservation;
  bool _nativeReservationHeld = false;
  static Future<void>? _quarantinedCleanup;
  static bool _cleanupFailed = false;
  static PlaybackSession? _resourceOwner;

  bool _acquireResources() {
    if (_resourceOwner != null && !identical(_resourceOwner, this)) {
      return false;
    }
    _resourceOwner = this;
    return true;
  }

  void _releaseResources() {
    if (identical(_resourceOwner, this) &&
        _quarantinedCleanup == null &&
        !_cleanupFailed) {
      if (_nativeReservationHeld) {
        final pending = playbackReservation!.release();
        _quarantinedCleanup = pending;
        pending.then(
          (_) {
            _nativeReservationHeld = false;
            if (identical(_quarantinedCleanup, pending)) {
              _quarantinedCleanup = null;
            }
            if (identical(_resourceOwner, this)) _resourceOwner = null;
            _notify();
          },
          onError: (Object _, StackTrace trace) {
            _cleanupFailed = true;
            if (!_disposed) reportError('无法确认播放器资源已释放，请重启应用');
          },
        );
      } else {
        _resourceOwner = null;
      }
    }
  }

  Future<void> _acquireNativeReservation() async {
    final pending = playbackReservation!.acquire();
    try {
      await pending.timeout(const Duration(seconds: 3));
      _nativeReservationHeld = true;
    } on TimeoutException {
      final cleanup = () async {
        try {
          await pending;
          _nativeReservationHeld = true;
          await playbackReservation!.release();
          _nativeReservationHeld = false;
        } on PlaybackReservationBusy {
          // A rejected reservation did not acquire native resources.
        }
      }();
      _quarantinedCleanup = cleanup;
      cleanup.then(
        (_) {
          if (identical(_quarantinedCleanup, cleanup)) {
            _quarantinedCleanup = null;
          }
          _releaseResources();
          _notify();
        },
        onError: (Object _, StackTrace trace) {
          _cleanupFailed = true;
          if (!_disposed) reportError('无法确认播放器资源已释放，请重启应用');
        },
      );
      throw StateError('播放器资源申请尚未确认，请稍候');
    } on PlaybackReservationBusy {
      rethrow;
    } catch (_) {
      _cleanupFailed = true;
      rethrow;
    }
  }

  Future<void> _releasePrepared(PreparedPlayback prepared) async {
    final release = Future<void>.sync(() async => prepared.release?.call());
    _quarantinedCleanup = release;
    var timedOut = false;
    release.then(
      (_) {
        if (identical(_quarantinedCleanup, release)) {
          _quarantinedCleanup = null;
          if (timedOut) _releaseResources();
          _notify();
        }
      },
      onError: (Object _, StackTrace trace) {
        _cleanupFailed = true;
        if (!_disposed) reportError('无法确认目录权限已释放，请重启应用');
      },
    );
    try {
      await release.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      timedOut = true;
      if (!_disposed) reportError('目录权限清理尚未完成，暂时无法打开视频');
    } catch (_) {
      _cleanupFailed = true;
      rethrow;
    }
  }

  final ResumeStore resumeStore;
  final SubtitleSupport? subtitleSupport;
  final SubtitleStyleStore? subtitleStyleStore;
  SubtitleStyle subtitleStyle = const SubtitleStyle();
  String subtitleStyleIssue = '';
  late final Future<void> _subtitleStyleLoaded = _readSubtitleStyle();
  Future<void> _subtitleStyleWrites = Future.value();
  int _subtitleStyleRevision = 0;
  int _subtitlePreviewRevision = 0;

  Future<void> _readSubtitleStyle() async {
    try {
      final saved = await subtitleStyleStore?.read();
      if (saved != null && !_disposed && _subtitleStyleRevision == 0) {
        subtitleStyle = saved;
      }
    } catch (_) {
      if (!_disposed) subtitleStyleIssue = '字幕设置读取失败，已使用默认值';
    }
  }

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
  String? _pendingSubtitleTrack;
  String? _pendingSubtitleExpected;
  bool _pendingSubtitleComplete = false;
  int? _inFlightSubtitleGeneration;
  int _subtitleSelectionGeneration = 0;

  void _clearPendingSubtitle() {
    _pendingSubtitleTrack = null;
    _pendingSubtitleExpected = null;
    _pendingSubtitleComplete = false;
  }

  void _confirmPendingSubtitle() {
    if (_pendingSubtitleTrack != null &&
        _pendingSubtitleComplete &&
        _pendingSubtitleExpected != null &&
        frame.subtitleTrackId == _pendingSubtitleExpected) {
      _clearPendingSubtitle();
    }
  }

  Future<void> _finishSubtitleSelection(
    PlaybackEngine engine,
    String requested,
    int revision,
  ) async {
    String? selected = requested;
    if (requested == 'auto') {
      try {
        selected = await engine.confirmedSubtitleTrackId();
      } catch (_) {
        selected = null;
      }
    }
    if (_disposed ||
        revision != _subtitleSelectionGeneration ||
        _pendingSubtitleTrack == null) {
      return;
    }
    _pendingSubtitleExpected = selected;
    _pendingSubtitleComplete = true;
    _confirmPendingSubtitle();
    _notify();
  }

  SubtitleTrackFormat get currentSubtitleFormat {
    if (loading || subtitleBusy || _pendingSubtitleTrack != null) {
      return SubtitleTrackFormat.unknown;
    }
    final id = frame.subtitleTrackId;
    if (id == 'auto' || id == 'no') return SubtitleTrackFormat.unknown;
    final track = frame.subtitleTracks
        .where((item) => item.id == id)
        .firstOrNull;
    if (track == null) return SubtitleTrackFormat.unknown;
    final codec = track.codec?.trim().toLowerCase();
    if (codec == 'ass' || codec == 'ssa') return SubtitleTrackFormat.ass;
    if (const {'subrip', 'srt', 'webvtt', 'mov_text', 'text'}.contains(codec)) {
      return SubtitleTrackFormat.text;
    }
    if (const {
      'hdmv_pgs_subtitle',
      'dvd_subtitle',
      'dvb_subtitle',
      'xsub',
    }.contains(codec)) {
      return SubtitleTrackFormat.bitmap;
    }
    // Only trust an extension from the reference associated with the active
    // native track, never an arbitrary embedded track label or old selection.
    final name = _active?.externalTracks[id]?.name.toLowerCase();
    if (name != null) {
      if (name.endsWith('.ass') || name.endsWith('.ssa')) {
        return SubtitleTrackFormat.ass;
      }
      if (name.endsWith('.srt') || name.endsWith('.vtt')) {
        return SubtitleTrackFormat.text;
      }
    }
    return SubtitleTrackFormat.unknown;
  }

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
  bool get _mediaSelectionLocked =>
      engine is PlaybackMediaSelectionGuard &&
      (engine! as PlaybackMediaSelectionGuard).mediaSelectionLocked;
  bool get hasPrevious => !_mediaSelectionLocked && playlistIndex > 0;
  bool get hasNext =>
      !_mediaSelectionLocked &&
      playlistIndex >= 0 &&
      playlistIndex + 1 < playlist.length;
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
    if (_mediaSelectionLocked) {
      reportError('请先结束视频投屏再切换视频');
      return Future.value();
    }
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

  void clearError() {
    if (error == null) return;
    error = null;
    _notify();
  }

  void _reportEngineError(String message) {
    // mpv reports option parsing errors on the same stream as decoding errors.
    // Limit classification to the exact subtitle options we set ourselves.
    final subtitleOption = RegExp(
      r'^The (?:--)?sub-(?:delay|scale|pos|bold|italic|color|border-color|border-size|ass-override) option\b',
      caseSensitive: false,
    );
    if (subtitleOption.hasMatch(message.trimLeft())) {
      subtitleStyleIssue = '字幕设置未完全应用，部分设置可能已生效';
      _notify();
    } else {
      reportError('播放失败：$message');
    }
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
    if (_quarantinedCleanup != null || _cleanupFailed) {
      reportError('播放器清理尚未完成，暂时无法打开视频');
      return Future.value();
    }
    if ((_resourceOwner != null && !identical(_resourceOwner, this)) ||
        (exclusivePlayback && !_acquireResources())) {
      reportError('其他播放器尚未关闭，暂时无法打开视频');
      return Future.value();
    }
    if (_mediaSelectionLocked) {
      reportError('请先结束视频投屏再切换视频');
      return Future.value();
    }
    if (_active case final active?) _freezeAndStop(active);
    final generation = ++_generation;
    ++_subtitleSelectionGeneration;
    _clearPendingSubtitle();
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
        await _retire(keepOwnership: true);
        if (_quarantinedCleanup != null || _cleanupFailed) {
          throw StateError('播放器清理尚未完成，暂时无法打开视频');
        }
        if (_disposed || generation != _generation) return;
        if (playbackReservation != null && !_nativeReservationHeld) {
          await _acquireNativeReservation();
        }
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
          await _releasePrepared(prepared);
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
          await _releasePrepared(prepared);
          rethrow;
        }
        media = prepared.media;
        _active = active;
        if (active.engine is PlaybackSafetyCriticalDisposal &&
            !exclusivePlayback) {
          throw StateError('此播放器需要独占资源');
        }
        final guard = active.engine;
        if (guard is PlaybackMediaSelectionGuard) {
          final routeGuard = guard as PlaybackMediaSelectionGuard;
          active.guardListener = () {
            if (!_current(active)) return;
            final issue = routeGuard.mediaSelectionIssue;
            if (issue != null) {
              error = issue;
              active.guardIssue = issue;
            } else if (active.guardIssue != null &&
                error == active.guardIssue) {
              error = null;
              active.guardIssue = null;
            }
            _notify();
          };
          routeGuard.mediaSelectionChanges.addListener(active.guardListener!);
        }
        // VideoController initializes after a Flutter frame. Publish the
        // surface before awaiting open, otherwise first playback can deadlock.
        _notify();
        active.subscriptions.addAll([
          active.engine.frames.listen((next) => _onFrame(active, next)),
          active.engine.errors.listen((message) {
            if (_current(active)) _reportEngineError(message);
          }),
          active.engine.interruptions.listen((_) {
            if (_current(active)) unawaited(pauseForInterruption());
          }),
        ]);
        await active.engine.open(active.media, start: start);
        await _subtitleStyleLoaded;
        if (_current(active)) {
          try {
            await active.engine.setSubtitleStyle(subtitleStyle);
          } catch (_) {
            if (_current(active)) subtitleStyleIssue = '字幕设置未完全应用，部分设置可能已生效';
          }
        }
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
        if ((generation == _generation || _disposed) && _active == null) {
          _releaseResources();
        }
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
    _confirmPendingSubtitle();
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

  Future<void> setSubtitleStyle(SubtitleStyle style) async {
    await _subtitleStyleLoaded;
    if (_disposed) return;
    final normalized = SubtitleStyle.fromJson(style.toJson());
    final revision = ++_subtitleStyleRevision;
    ++_subtitlePreviewRevision;
    final generation = _generation;
    subtitleStyle = normalized;
    subtitleStyleIssue = '';
    _notify();
    _subtitleStyleWrites = _subtitleStyleWrites.then((_) async {
      try {
        await subtitleStyleStore?.write(normalized);
      } catch (_) {
        if (!_disposed && revision == _subtitleStyleRevision) {
          subtitleStyleIssue = '字幕设置保存失败';
          _notify();
        }
      }
    });
    final applied = _enqueue(() async {
      if (_disposed || generation != _generation || !ready) return;
      try {
        await engine!.setSubtitleStyle(normalized);
      } catch (_) {
        if (generation == _generation && revision == _subtitleStyleRevision) {
          subtitleStyleIssue = '字幕设置未完全应用，部分设置可能已生效';
          _notify();
        }
        return;
      }
    });
    await Future.wait([applied, _subtitleStyleWrites]);
  }

  /// Preview does not persist or modify the selected style. Older queued
  /// previews are dropped, and session changes never target a new engine.
  Future<void> previewSubtitleStyle(SubtitleStyle style) {
    final revision = ++_subtitlePreviewRevision;
    final generation = _generation;
    final normalized = SubtitleStyle.fromJson(style.toJson());
    return _enqueue(() async {
      if (_disposed ||
          generation != _generation ||
          revision != _subtitlePreviewRevision ||
          !ready) {
        return;
      }
      try {
        await engine!.setSubtitleStyle(normalized);
      } catch (_) {
        if (!_disposed &&
            generation == _generation &&
            revision == _subtitlePreviewRevision) {
          subtitleStyleIssue = '字幕设置未完全应用，部分设置可能已生效';
          _notify();
        }
      }
    });
  }

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
    if (_disposed || !ready) return Future.value();
    if (subtitleSupport != null && _active == null) return Future.value();
    final selectionGeneration = ++_subtitleSelectionGeneration;
    _pendingSubtitleTrack =
        id == frame.subtitleTrackId && _inFlightSubtitleGeneration == null
        ? null
        : id;
    _pendingSubtitleExpected = null;
    _pendingSubtitleComplete = false;
    _notify();
    if (subtitleSupport == null) {
      return _control((engine) async {
        if (selectionGeneration != _subtitleSelectionGeneration) return;
        _inFlightSubtitleGeneration = selectionGeneration;
        try {
          await engine.selectSubtitle(id);
          await _finishSubtitleSelection(engine, id, selectionGeneration);
        } catch (_) {
          if (selectionGeneration == _subtitleSelectionGeneration) {
            _clearPendingSubtitle();
            _notify();
          }
          rethrow;
        } finally {
          if (_inFlightSubtitleGeneration == selectionGeneration) {
            _inFlightSubtitleGeneration = null;
          }
        }
      });
    }
    final active = _active;
    if (active == null || !ready) {
      _clearPendingSubtitle();
      return Future.value();
    }
    final revision = ++_subtitleRevision;
    subtitleBusy = false;
    return _enqueue(() async {
      if (!_subtitleCurrent(active, revision)) return;
      try {
        if (selectionGeneration != _subtitleSelectionGeneration) return;
        _inFlightSubtitleGeneration = selectionGeneration;
        await active.engine.selectSubtitle(id);
        await _finishSubtitleSelection(active.engine, id, selectionGeneration);
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
        if (selectionGeneration == _subtitleSelectionGeneration) {
          _clearPendingSubtitle();
        }
        if (_subtitleCurrent(active, revision)) {
          subtitleIssue = '字幕选择失败：$error';
        }
      } finally {
        if (_inFlightSubtitleGeneration == selectionGeneration) {
          _inFlightSubtitleGeneration = null;
        }
        if (_current(active)) _notify();
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
    ++_subtitleSelectionGeneration;
    _clearPendingSubtitle();
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
    if (_inFlightSubtitleGeneration != _subtitleSelectionGeneration) {
      ++_subtitleSelectionGeneration;
      if (_inFlightSubtitleGeneration == null) {
        _clearPendingSubtitle();
      } else {
        // A newer queued selection is cancelled, but an older native command
        // is already running and cannot be cancelled. Do not present its old
        // frame as confirmed; an explicit later choice can resolve unknown.
        _pendingSubtitleTrack = 'auto';
        _pendingSubtitleExpected = null;
        _pendingSubtitleComplete = false;
      }
    }
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

  Future<void> _retire({bool keepOwnership = false}) async {
    if (_quarantinedCleanup != null || _cleanupFailed) {
      if (!_disposed) reportError('播放器清理尚未完成，暂时无法打开视频');
      return;
    }
    final active = _active;
    _active = null;
    if (active == null) {
      if (!keepOwnership) _releaseResources();
      return;
    }
    final guard = active.engine;
    if (guard is PlaybackMediaSelectionGuard && active.guardListener != null) {
      (guard as PlaybackMediaSelectionGuard).mediaSelectionChanges
          .removeListener(active.guardListener!);
    }
    if (active.engine is PlaybackSafetyCriticalDisposal) {
      final cleanup = _retireSafely(active);
      _quarantinedCleanup = cleanup;
      var timedOut = false;
      cleanup.then(
        (_) {
          if (identical(_quarantinedCleanup, cleanup)) {
            _quarantinedCleanup = null;
            if (!keepOwnership || timedOut) _releaseResources();
            _notify();
          }
        },
        onError: (Object _, StackTrace trace) {
          _cleanupFailed = true;
          if (!_disposed) reportError('无法确认播放器已关闭，请重启应用');
        },
      );
      try {
        await cleanup.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        timedOut = true;
        if (!_disposed) reportError('播放器清理尚未完成，暂时无法打开视频');
      } catch (_) {
        // Keep the scope and block all future sessions on unconfirmed close.
      }
      return;
    }
    try {
      for (final subscription in active.subscriptions) {
        await subscription.cancel();
      }
    } catch (_) {
      _cleanupFailed = true;
      rethrow;
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
    if (!keepOwnership) _releaseResources();
  }

  Future<void> _retireSafely(_ActiveSession active) async {
    _freezeAndStop(active);
    await Future.wait([
      active.finalCheckpoint!,
      active.stopping!,
      for (final subscription in active.subscriptions) subscription.cancel(),
    ]);
    await Future.wait(active.subtitleReleases.map((release) => release()));
    await active.release?.call();
  }

  void _freezeAndStop(_ActiveSession active) {
    if (active.engine is! PlaybackSafetyCriticalDisposal ||
        active.stopping != null) {
      return;
    }
    active.finalCheckpoint = _save(active);
    active.stopping = active.engine.dispose();
    active.stopping!.ignore();
  }

  Future<void> close() {
    if (_active case final active?) _freezeAndStop(active);
    ++_generation;
    final closingGeneration = _generation;
    ++_subtitleSelectionGeneration;
    _clearPendingSubtitle();
    ++_subtitleRevision;
    ++_subtitleScanRevision;
    subtitleBusy = findingSubtitles = false;
    media = null;
    playlist = const [];
    frame = const PlaybackFrame();
    loading = false;
    error = null;
    _notify();
    final cleanup = _enqueue(
      () => _retire(
        keepOwnership: !_disposed && closingGeneration != _generation,
      ),
    );
    return cleanup.timeout(
      const Duration(seconds: 3),
      onTimeout: () {
        if (!_disposed) reportError('播放器清理尚未完成，暂时无法打开视频');
      },
    );
  }

  Future<void> shutdown() {
    if (_active case final active?) _freezeAndStop(active);
    _disposed = true;
    ++_generation;
    ++_subtitleSelectionGeneration;
    _clearPendingSubtitle();
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
  Future<void>? stopping;
  Future<void>? finalCheckpoint;
  bool completedHandled = false;
  bool manualAudio = false, audioDefaultApplied = false;
  final List<StreamSubscription<dynamic>> subscriptions = [];
  VoidCallback? guardListener;
  String? guardIssue;
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
