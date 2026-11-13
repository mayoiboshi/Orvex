import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/playback_defaults.dart';
import '../domain/playback_engine.dart';
import '../domain/subtitle_style.dart';

enum AirPlayPhase { idle, preparing, choosing, connecting, active, failed }

class _PhaseNotifier extends ValueNotifier<AirPlayPhase> {
  _PhaseNotifier() : super(AirPlayPhase.idle);
  void signal() => notifyListeners();
}

/// The iOS route uses a second native player but only this engine publishes
/// playback frames to PlaybackSession. The local player stays alive, paused,
/// keeping the session's existing file authorization lease until disposal.
class AirPlayPlaybackEngine
    implements
        PlaybackEngine,
        PlaybackMediaSelectionGuard,
        PlaybackSafetyCriticalDisposal {
  AirPlayPlaybackEngine(this.local, {AirPlayTransport? transport})
    : transport = transport ?? MethodChannelAirPlayTransport() {
    _subscriptions.addAll([
      local.frames.listen(_onLocalFrame),
      local.errors.listen((value) {
        if (!_remote && !_errors.isClosed) _errors.add(value);
      }),
      local.interruptions.listen((value) {
        if (!_interruptions.isClosed) _interruptions.add(value);
      }),
      this.transport.events.listen(
        _onNativeEvent,
        onError: (Object _) {
          if (!_disposed && phase != AirPlayPhase.idle) {
            unawaited(
              _remote
                  ? _returnToLocal('AirPlay 连接中断，播放已暂停')
                  : _fail('AirPlay 连接失败，播放已暂停'),
            );
          }
        },
      ),
    ]);
  }

  final PlaybackEngine local;
  final AirPlayTransport transport;
  final _frames = StreamController<PlaybackFrame>.broadcast(sync: true);
  final _errors = StreamController<String>.broadcast(sync: true);
  final _interruptions = StreamController<PlaybackInterruption>.broadcast(
    sync: true,
  );
  final _subscriptions = <StreamSubscription<dynamic>>[];
  LocalMedia? _media;
  PlaybackFrame _localFrame = const PlaybackFrame();
  PlaybackFrame _remoteFrame = const PlaybackFrame();
  AirPlayPhase phase = AirPlayPhase.idle;
  final phaseNotifier = _PhaseNotifier();
  String? issue;

  /// A second routing adapter may hold the shared local playback authority.
  bool Function()? routeAllowed;
  bool _remote = false,
      _disposed = false,
      _committing = false,
      _returning = false;
  bool _wasPlaying = false;
  int? _commitToken;
  int _lastNativeSequence = 0;
  Duration _handoffPosition = Duration.zero;
  Duration? _localSeekTarget;
  static int _nextTokenBase = 0;
  static int _allocateTokenBase() {
    final base = _nextTokenBase;
    _nextTokenBase += 1 << 32;
    return base;
  }

  int _token = _allocateTokenBase();
  Timer? _timeout;
  Completer<void>? _returnDone;
  Future<void>? _disposeFuture;
  bool _disposeComplete = false;
  bool _disposeUncertain = false;
  int? _candidateToken;
  Future<void>? _candidateClose;
  bool _cleanupBlocked = false;

  bool get externalActive => _remote;
  @override
  bool get mediaSelectionLocked =>
      _cleanupBlocked ||
      _remote ||
      phase == AirPlayPhase.preparing ||
      phase == AirPlayPhase.choosing ||
      phase == AirPlayPhase.connecting;
  @override
  String? get mediaSelectionIssue =>
      phase == AirPlayPhase.failed ? issue : null;
  @override
  Listenable get mediaSelectionChanges => phaseNotifier;
  @override
  Stream<PlaybackFrame> get frames => _frames.stream;
  @override
  Stream<String> get errors => _errors.stream;
  @override
  Stream<PlaybackInterruption> get interruptions => _interruptions.stream;

  void _setPhase(AirPlayPhase value, [String? message]) {
    if (_disposed) return;
    phase = value;
    issue = message;
    phaseNotifier.value = value;
  }

  void _onLocalFrame(PlaybackFrame frame) {
    _localFrame = frame;
    if (_localSeekTarget case final target?) {
      if ((frame.position - target).abs() > const Duration(seconds: 1) ||
          frame.playing) {
        return;
      }
      _localSeekTarget = null;
    }
    if (!_remote && !_frames.isClosed) _frames.add(frame);
  }

  void _mergeRemoteFrame(AirPlayNativeEvent event) {
    final frame = event.frame;
    if (frame == null) return;
    _remoteFrame = PlaybackFrame(
      position: event.positionValid ? frame.position : _remoteFrame.position,
      duration: event.durationValid ? frame.duration : _remoteFrame.duration,
      playing: frame.playing,
      buffering: frame.buffering,
      completed: frame.completed,
      rate: frame.rate,
      volume: frame.volume,
      audioTracks: frame.audioTracks,
      subtitleTracks: frame.subtitleTracks,
      audioTrackId: frame.audioTrackId,
      subtitleTrackId: frame.subtitleTrackId,
    );
  }

  @override
  Widget buildVideo({PlaybackFit fit = PlaybackFit.contain}) =>
      local.buildVideo(fit: fit);
  @override
  Future<void> open(LocalMedia media, {required Duration start}) async {
    _media = media;
    await local.open(media, start: start);
  }

  /// Prepare while keeping the local engine and file scope alive. The caller
  /// presents the actual system picker only after this returns successfully.
  Future<bool> prepareRoute() async {
    if (_disposed ||
        _cleanupBlocked ||
        routeAllowed?.call() == false ||
        (phase != AirPlayPhase.idle && phase != AirPlayPhase.failed) ||
        _remote ||
        _media == null) {
      return false;
    }
    final token = ++_token;
    _candidateToken = token;
    _wasPlaying = _localSeekTarget == null && _localFrame.playing;
    _setPhase(AirPlayPhase.preparing);
    try {
      await local.pause();
      if (_disposed || token != _token) return false;
      _handoffPosition = _localSeekTarget ?? _localFrame.position;
      await transport
          .prepare(_media!, _handoffPosition, token)
          .timeout(const Duration(seconds: 20));
      if (_disposed || token != _token) return false;
      _setPhase(AirPlayPhase.choosing);
      return true;
    } catch (_) {
      if (!_disposed && token == _token) {
        try {
          await _closeCandidate(token).timeout(const Duration(seconds: 3));
        } on TimeoutException {
          if (!_disposed && token == _token) {
            _setPhase(AirPlayPhase.failed, '投屏关闭尚未确认，播放已锁定');
          }
          return false;
        } catch (_) {
          return false;
        }
        if (!_disposed && token == _token) {
          _setPhase(AirPlayPhase.failed, '无法准备 AirPlay，播放已暂停');
        }
      }
      return false;
    }
  }

  Future<void> cancelRoute() async {
    final operation = _cancelRoute();
    try {
      await operation.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      _setPhase(AirPlayPhase.failed, '投屏关闭尚未确认，播放已锁定');
    } catch (_) {
      // The candidate remains locked; _closeCandidate already reports why.
    }
  }

  Future<void> _cancelRoute() async {
    if (_remote) {
      await _returnToLocal('视频投屏已结束，播放已暂停；音频输出可通过系统切换');
      return;
    }
    final old = _token++;
    final revision = _token;
    _committing = false;
    _commitToken = null;
    _timeout?.cancel();
    await _closeCandidate(old);
    if (revision == _token) _setPhase(AirPlayPhase.idle);
  }

  Future<void> _closeCandidate(int token) {
    if (_candidateToken == null) return Future.value();
    if (_candidateClose != null) return _candidateClose!;
    _cleanupBlocked = true;
    final candidate = _candidateToken!;
    final close = _candidateClose = Future<void>(
      () => _performClose(candidate),
    );
    phaseNotifier.signal();
    return close;
  }

  Future<void> _performClose(int candidate) async {
    try {
      await transport.close(candidate);
      _candidateToken = null;
      _candidateClose = null;
      _cleanupBlocked = false;
      phaseNotifier.signal();
    } catch (_) {
      _candidateClose = null;
      _setPhase(AirPlayPhase.failed, '无法确认投屏已关闭，播放已锁定');
      rethrow;
    }
  }

  void _onNativeEvent(AirPlayNativeEvent event) {
    if (_disposed || event.token != _token) return;
    var staleInterruption = false;
    if (event.sequence > 0) {
      if (event.sequence <= _lastNativeSequence) {
        if (event.kind != 'interrupted') return;
        staleInterruption = true;
      }
      if (event.sequence > _lastNativeSequence) {
        _lastNativeSequence = event.sequence;
      }
    }
    if (event.kind == 'pickerOpened' && phase == AirPlayPhase.choosing) {
      _setPhase(AirPlayPhase.connecting);
      final token = _token;
      unawaited(
        transport.probe(token).catchError((Object _) async {
          if (!_disposed && token == _token) await _fail('无法连接 AirPlay');
        }),
      );
    } else if (event.kind == 'pickerClosed' && !_remote) {
      _timeout?.cancel();
      _timeout = Timer(const Duration(seconds: 15), () {
        if (!_remote && !_committing) unawaited(_fail('未连接到 AirPlay 视频设备'));
      });
    } else if (event.kind == 'state') {
      _mergeRemoteFrame(event);
      if (event.external &&
          !_remote &&
          !_committing &&
          (phase == AirPlayPhase.choosing ||
              phase == AirPlayPhase.connecting)) {
        unawaited(_commit(event.token));
      } else if (!event.external && _remote) {
        unawaited(_returnToLocal('AirPlay 视频连接已断开，播放已暂停'));
      } else if (_remote && !_frames.isClosed) {
        _frames.add(_remoteFrame);
      }
    } else if (event.kind == 'routeLost') {
      _mergeRemoteFrame(event);
      if (_remote) {
        unawaited(_returnToLocal('AirPlay 视频连接已断开，播放已暂停'));
      } else {
        unawaited(_fail('AirPlay 连接中断，播放已暂停'));
      }
    } else if (event.kind == 'interrupted') {
      _wasPlaying = false;
      if (!staleInterruption) _mergeRemoteFrame(event);
      if (_remote && !_frames.isClosed) _frames.add(_remoteFrame);
      if (!_interruptions.isClosed) {
        _interruptions.add(PlaybackInterruption.audioFocusLost);
      }
    } else if (event.kind == 'error') {
      unawaited(
        _remote
            ? _returnToLocal('AirPlay 播放失败，已返回本地暂停')
            : _fail('AirPlay 连接失败，播放已暂停'),
      );
    }
  }

  Future<void> _commit(int token) async {
    _committing = true;
    _commitToken = token;
    _timeout?.cancel();
    try {
      await transport
          .seek(_handoffPosition, token)
          .timeout(const Duration(seconds: 10));
      if (_disposed || token != _token) return;
      final afterSeek = await _freshSnapshot(token);
      if (!afterSeek.external) {
        throw StateError('AirPlay 视频路由已断开');
      }
      if (_disposed || token != _token) return;
      if (_wasPlaying) {
        await transport.play(token).timeout(const Duration(seconds: 10));
      } else {
        await transport.pause(token).timeout(const Duration(seconds: 10));
      }
      if (_disposed || token != _token) return;
      final confirmed = await _freshSnapshot(token);
      if (!confirmed.external) throw StateError('AirPlay 视频路由已断开');
      if (_disposed || token != _token) return;
      _remote = true;
      _remoteFrame = PlaybackFrame(
        position: _handoffPosition,
        duration: _localFrame.duration,
        buffering: _wasPlaying,
      );
      _mergeRemoteFrame(confirmed);
      _frames.add(_remoteFrame);
      _setPhase(AirPlayPhase.active);
    } catch (_) {
      if (!_disposed && token == _token) await _fail('AirPlay 移交失败，播放已暂停');
    } finally {
      if (_commitToken == token) {
        _committing = false;
        _commitToken = null;
      }
    }
  }

  Future<AirPlayNativeEvent> _freshSnapshot(int token) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final value = await transport
          .snapshot(token)
          .timeout(const Duration(seconds: 3));
      if (_disposed || token != _token) throw StateError('投屏会话已失效');
      if (value.sequence == 0 || value.sequence >= _lastNativeSequence) {
        if (value.sequence > 0) _lastNativeSequence = value.sequence;
        return value;
      }
    }
    throw StateError('AirPlay 状态持续变化，请重试');
  }

  Future<void> _fail(String message) async {
    final old = _token++;
    final revision = _token;
    _timeout?.cancel();
    try {
      await _closeCandidate(old);
    } catch (_) {
      return;
    }
    if (!_disposed && revision == _token) {
      _setPhase(AirPlayPhase.failed, message);
    }
  }

  Future<void> _returnToLocal(String message) async {
    if (_returning) return _returnDone?.future;
    if (!_remote) return;
    _returning = true;
    final done = _returnDone = Completer<void>();
    final old = _token++;
    final revision = _token;
    _timeout?.cancel();
    final warning = Timer(const Duration(seconds: 3), () {
      if (_returning && !_disposed) {
        _setPhase(AirPlayPhase.failed, '投屏关闭或本地恢复尚未完成，播放已锁定');
      }
    });
    if (!_frames.isClosed) {
      _frames.add(
        PlaybackFrame(
          position: _remoteFrame.position,
          duration: _remoteFrame.duration,
          rate: _remoteFrame.rate,
          volume: _remoteFrame.volume,
        ),
      );
    }
    try {
      try {
        await transport.pause(old).timeout(const Duration(seconds: 3));
      } catch (_) {}
      if (_disposed || revision != _token) return;
      try {
        await _closeCandidate(old);
      } catch (_) {
        return;
      }
      if (_disposed || revision != _token) return;
      var restored = false;
      try {
        _localSeekTarget = _remoteFrame.position;
        await local.seek(_remoteFrame.position);
        if (_disposed || revision != _token) return;
        await local.pause();
        if (_disposed || revision != _token) return;
        restored = true;
      } catch (_) {
        if (!_errors.isClosed) _errors.add('AirPlay 已断开，无法恢复本地位置');
      }
      if (!restored) {
        // Keep the last known remote checkpoint authoritative until the user
        // closes/reopens the media; do not overwrite it with an old local frame.
        _setPhase(AirPlayPhase.failed, '无法恢复本地位置，请重新打开视频');
        return;
      }
      _remote = false;
      if (!_frames.isClosed) {
        _frames.add(
          PlaybackFrame(
            position: _remoteFrame.position,
            duration: _remoteFrame.duration,
            playing: false,
            rate: _localFrame.rate,
            volume: _localFrame.volume,
            audioTracks: _localFrame.audioTracks,
            subtitleTracks: _localFrame.subtitleTracks,
            audioTrackId: _localFrame.audioTrackId,
            subtitleTrackId: _localFrame.subtitleTrackId,
          ),
        );
      }
      _setPhase(AirPlayPhase.failed, message);
    } finally {
      warning.cancel();
      _returning = false;
      if (!done.isCompleted) done.complete();
    }
  }

  @override
  Future<void> togglePause() => _remote && phase == AirPlayPhase.failed
      ? Future.error(StateError('无法恢复本地位置，请重新打开视频'))
      : !_remote && mediaSelectionLocked
      ? Future.error(StateError('正在连接 AirPlay，请先取消连接'))
      : _remote
      ? (_remoteFrame.playing
            ? transport.pause(_token)
            : transport.play(_token, userInitiated: true))
      : local.togglePause();
  @override
  Future<void> pause() {
    _wasPlaying = false;
    if (_remote) return transport.pause(_candidateToken ?? _token);
    if (phase == AirPlayPhase.preparing ||
        phase == AirPlayPhase.choosing ||
        phase == AirPlayPhase.connecting) {
      return cancelRoute();
    }
    return local.pause();
  }

  @override
  Future<void> seek(Duration position) =>
      _remote && phase == AirPlayPhase.failed
      ? Future.error(StateError('无法恢复本地位置，请重新打开视频'))
      : !_remote && mediaSelectionLocked
      ? Future.error(StateError('正在连接 AirPlay，请先取消连接'))
      : _remote
      ? transport.seek(position, _token)
      : local.seek(position);
  @override
  Future<void> setRate(double rate) => mediaSelectionLocked
      ? Future.error(StateError('AirPlay 暂不支持调整倍速'))
      : local.setRate(rate);
  @override
  Future<void> setVolume(double volume) =>
      _remote ? Future.error(StateError('请使用系统音量')) : local.setVolume(volume);
  @override
  Future<void> setSubtitleStyle(SubtitleStyle style) => _remote
      ? Future.error(StateError('AirPlay 暂不支持字幕样式'))
      : local.setSubtitleStyle(style);
  @override
  Future<void> selectAudio(String id) => mediaSelectionLocked
      ? Future.error(StateError('AirPlay 暂不支持切换音轨'))
      : local.selectAudio(id);
  @override
  Future<void> selectSubtitle(String id) => mediaSelectionLocked
      ? Future.error(StateError('AirPlay 暂不支持切换字幕'))
      : local.selectSubtitle(id);
  @override
  Future<String?> confirmedSubtitleTrackId() =>
      _remote ? Future.value(null) : local.confirmedSubtitleTrackId();
  @override
  Future<void> loadSubtitle(Uri uri, String name) => mediaSelectionLocked
      ? Future.error(StateError('AirPlay 暂不支持外挂字幕'))
      : local.loadSubtitle(uri, name);
  @override
  Future<void> dispose() {
    if (_disposeComplete) return Future.value();
    if (_disposeFuture != null) return _disposeFuture!;
    if (_disposeUncertain) return Future.error(StateError('播放器销毁状态未确认'));
    return _disposeFuture = _disposeOnce();
  }

  Future<void> _disposeOnce() async {
    _disposed = true;
    final old = _token++;
    _timeout?.cancel();
    try {
      await _closeCandidate(old);
      await _returnDone?.future;
      _disposeUncertain = true;
      for (final subscription in _subscriptions) {
        await subscription.cancel();
      }
      await transport.dispose();
      await local.dispose();
      await _frames.close();
      await _errors.close();
      await _interruptions.close();
      phaseNotifier.dispose();
      _disposeComplete = true;
      _disposeUncertain = false;
    } catch (_) {
      _disposeFuture = null;
      rethrow;
    }
  }
}

class AirPlayNativeEvent {
  const AirPlayNativeEvent({
    required this.token,
    required this.kind,
    this.external = false,
    this.frame,
    this.positionValid = true,
    this.durationValid = true,
    this.sequence = 0,
  });
  final int token;
  final String kind;
  final bool external;
  final PlaybackFrame? frame;
  final bool positionValid;
  final bool durationValid;
  final int sequence;
}

abstract interface class AirPlayTransport {
  Stream<AirPlayNativeEvent> get events;
  Future<void> prepare(LocalMedia media, Duration position, int token);
  Future<void> probe(int token);
  Future<void> seek(Duration position, int token);
  Future<void> play(int token, {bool userInitiated = false});
  Future<void> pause(int token);
  Future<void> close(int token);
  Future<AirPlayNativeEvent> snapshot(int token);
  Future<void> dispose();
}

class NativePlaybackReservation implements PlaybackReservation {
  static const _channel = MethodChannel('dev.orvex/airplay');
  late final Future<String> bridgeID = _channel
      .invokeMethod<String>('identity')
      .then((value) => value ?? (throw StateError('投屏组件不可用')));
  String? _claim;
  String get claim => _claim ?? (throw StateError('播放会话未取得所有权'));
  @override
  Future<void> acquire() async {
    try {
      _claim = await _channel.invokeMethod<String>('claimPlayback', {
        'bridgeId': await bridgeID,
      });
      if (_claim == null) throw StateError('未能确认播放所有权');
    } on PlatformException catch (error) {
      if (error.code == 'owner_busy') throw const PlaybackReservationBusy();
      rethrow;
    }
  }

  @override
  Future<void> release() async {
    await _channel.invokeMethod<void>('releasePlayback', {
      'bridgeId': await bridgeID,
      'claimId': claim,
    });
    _claim = null;
  }
}

class MethodChannelAirPlayTransport implements AirPlayTransport {
  MethodChannelAirPlayTransport({NativePlaybackReservation? reservation})
    : reservation = reservation ?? NativePlaybackReservation();
  final NativePlaybackReservation reservation;
  static const _channel = MethodChannel('dev.orvex/airplay');
  static const _events = EventChannel('dev.orvex/airplay/events');
  final _subscriptionID = List.generate(
    4,
    (_) => Random.secure().nextInt(1 << 32).toRadixString(16),
  ).join('-');
  @override
  late final Stream<AirPlayNativeEvent>
  events = Stream.fromFuture(reservation.bridgeID)
      .asyncExpand(
        (id) => _events.receiveBroadcastStream({
          'subscriptionId': _subscriptionID,
          'bridgeId': id,
          'claimId': reservation.claim,
        }),
      )
      .where((value) => value is Map)
      .map((value) {
        final data = Map<Object?, Object?>.from(value as Map);
        final event = data['event'] as String? ?? '';
        return AirPlayNativeEvent(
          token: (data['token'] as num?)?.toInt() ?? -1,
          kind: switch (event) {
            'routeChanged' ||
            'ready' ||
            'playing' ||
            'paused' ||
            'completed' ||
            'seeked' ||
            'snapshot' => 'state',
            'routeLost' => 'routeLost',
            'interrupted' => 'interrupted',
            'timeout' || 'failed' => 'error',
            _ => event,
          },
          external: data['external'] == true,
          sequence: (data['sequence'] as num?)?.toInt() ?? 0,
          positionValid: data['positionValid'] == true,
          durationValid: data['durationValid'] == true,
          frame:
              const {
                'state',
                'routeChanged',
                'routeLost',
                'ready',
                'playing',
                'paused',
                'completed',
                'seeked',
                'snapshot',
                'interrupted',
              }.contains(event)
              ? PlaybackFrame(
                  position: Duration(
                    milliseconds: (data['positionMs'] as num?)?.toInt() ?? 0,
                  ),
                  duration: Duration(
                    milliseconds: (data['durationMs'] as num?)?.toInt() ?? 0,
                  ),
                  playing: data['playing'] == true,
                  buffering: data['buffering'] == true,
                  completed: data['completed'] == true,
                )
              : null,
        );
      });
  @override
  Future<void> prepare(LocalMedia media, Duration position, int token) async {
    await _channel.invokeMethod<Object?>('prepare', {
      'uri': media.uri.toString(),
      if (media.accessHandle != null) 'handle': media.accessHandle,
      if (media.accessPath != null) 'path': media.accessPath,
      if (media.accessIdentity != null) 'identity': media.accessIdentity,
      if (media.relativeImportPath != null)
        'importPath': media.relativeImportPath,
      'positionMs': position.inMilliseconds,
      'token': token,
      'bridgeId': await reservation.bridgeID,
      'claimId': reservation.claim,
    });
  }

  @override
  Future<void> probe(int token) async => _channel.invokeMethod<void>('probe', {
    'token': token,
    'bridgeId': await reservation.bridgeID,
    'claimId': reservation.claim,
  });
  @override
  Future<void> seek(Duration position, int token) async {
    await _channel.invokeMethod<Object?>('seek', {
      'positionMs': position.inMilliseconds,
      'token': token,
      'bridgeId': await reservation.bridgeID,
      'claimId': reservation.claim,
    });
  }

  @override
  Future<void> play(int token, {bool userInitiated = false}) async =>
      _channel.invokeMethod<void>('play', {
        'token': token,
        'bridgeId': await reservation.bridgeID,
        'claimId': reservation.claim,
        'userInitiated': userInitiated,
      });
  @override
  Future<void> pause(int token) async => _channel.invokeMethod<void>('pause', {
    'token': token,
    'bridgeId': await reservation.bridgeID,
    'claimId': reservation.claim,
  });
  @override
  Future<void> close(int token) async => _channel.invokeMethod<void>('close', {
    'token': token,
    'bridgeId': await reservation.bridgeID,
    'claimId': reservation.claim,
  });
  @override
  Future<AirPlayNativeEvent> snapshot(int token) async {
    final value = await _channel.invokeMapMethod<Object?, Object?>('status', {
      'token': token,
      'bridgeId': await reservation.bridgeID,
      'claimId': reservation.claim,
    });
    if (value == null || (value['token'] as num?)?.toInt() != token) {
      throw StateError('AirPlay 状态不可用');
    }
    return AirPlayNativeEvent(
      token: token,
      kind: 'state',
      external: value['external'] == true,
      sequence: (value['sequence'] as num?)?.toInt() ?? 0,
      positionValid: value['positionValid'] == true,
      durationValid: value['durationValid'] == true,
      frame: PlaybackFrame(
        position: Duration(
          milliseconds: (value['positionMs'] as num?)?.toInt() ?? 0,
        ),
        duration: Duration(
          milliseconds: (value['durationMs'] as num?)?.toInt() ?? 0,
        ),
        playing: value['playing'] == true,
        buffering: value['buffering'] == true,
        completed: value['completed'] == true,
      ),
    );
  }

  @override
  Future<void> dispose() async {}
}
