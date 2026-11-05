import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/playback_engine.dart';

class PlaybackSession extends ChangeNotifier {
  PlaybackSession({
    required this.createEngine,
    required this.resumeStore,
    this.onCheckpoint,
  });

  final PlaybackEngine Function() createEngine;
  final ResumeStore resumeStore;
  final Future<void> Function(LocalMedia media, PlaybackFrame frame)?
  onCheckpoint;
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

  Future<void> open(LocalMedia source) {
    if (_disposed) return Future.value();
    final generation = ++_generation;
    media = source;
    frame = const PlaybackFrame();
    loading = true;
    error = null;
    _notify();
    return _enqueue(() async {
      try {
        await _retire();
        if (_disposed || generation != _generation) return;
        var start = Duration.zero;
        try {
          start = await resumeStore.read(source.resumeKey);
        } catch (_) {
          if (generation == _generation) error = '无法读取上次进度，将从头播放';
        }
        if (_disposed || generation != _generation) return;
        final active = _ActiveSession(generation, source, createEngine());
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
        await active.engine.open(source, start: start);
      } catch (exception) {
        if (generation == _generation) error = '无法打开视频：$exception';
        await _retire();
      } finally {
        if (!_disposed && generation == _generation) {
          loading = false;
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
  Future<void> setVolume(double volume) =>
      _control((engine) => engine.setVolume(volume.clamp(0, 100)));

  Future<void> seek(Duration target) => _control((engine) {
    final duration = frame.duration;
    if (duration <= Duration.zero) return Future.value();
    final bounded = target.inMilliseconds.clamp(0, duration.inMilliseconds);
    return engine.seek(Duration(milliseconds: bounded));
  });

  Future<void> selectAudio(String id) =>
      _control((engine) => engine.selectAudio(id));
  Future<void> selectSubtitle(String id) =>
      _control((engine) => engine.selectSubtitle(id));

  Future<void> loadSubtitle(LocalMedia source) => _control((engine) async {
    error = null;
    _notify();
    // Selection is derived from the engine's track stream, never set optimistically.
    await engine.loadSubtitle(source.uri, source.name);
  });

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
      await active.engine.dispose();
    }
  }

  Future<void> close() {
    ++_generation;
    media = null;
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
  _ActiveSession(this.generation, this.media, this.engine);
  final int generation;
  final LocalMedia media;
  final PlaybackEngine engine;
  final List<StreamSubscription<dynamic>> subscriptions = [];
  PlaybackFrame frame = const PlaybackFrame();
  Duration lastCheckpoint = Duration.zero;
  bool wasPlaying = false;
}
