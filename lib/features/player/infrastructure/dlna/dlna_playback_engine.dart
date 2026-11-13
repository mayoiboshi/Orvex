import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/playback_defaults.dart';
import '../../domain/playback_engine.dart';
import '../../domain/subtitle_style.dart';
import '../airplay_playback_engine.dart';
import 'dlna_client.dart';
import 'media_server.dart';

class _DlnaNotifier extends ValueNotifier<DlnaPhase> {
  _DlnaNotifier() : super(DlnaPhase.idle);
  void signal() => notifyListeners();
}

enum DlnaPhase { idle, connecting, active, closing, uncertain }

class DlnaResolvedTarget {
  const DlnaResolvedTarget(this.device, this.local, this.peer);
  final DlnaDevice device;
  final InternetAddress local, peer;
}

typedef DlnaTargetResolver = Future<DlnaResolvedTarget> Function(
  String address,
);

class DlnaPlaybackEngine
    implements
        PlaybackEngine,
        PlaybackMediaSelectionGuard,
        PlaybackSafetyCriticalDisposal {
  DlnaPlaybackEngine(
    this.airplay,
    this.reservation, {
    this._resolveTarget,
    this._closeServer,
    this.connectTimeout = const Duration(seconds: 15),
    this._startServer,
  }) {
    _subscriptions.addAll([
      airplay.frames.listen((frame) {
        _local = frame;
        if (!_authoritative && !_frames.isClosed) _frames.add(frame);
      }),
      airplay.errors.listen((error) {
        if (!_errors.isClosed) _errors.add(error);
      }),
      airplay.interruptions.listen((event) {
        if (!_interruptions.isClosed) _interruptions.add(event);
      }),
    ]);
    airplay.mediaSelectionChanges.addListener(_signal);
    airplay.routeAllowed = () =>
        !_disposed &&
        !_connectQueued &&
        !_disconnectPending &&
        _pendingInterruption == null &&
        !_localPauseFailed &&
        phase.value == DlnaPhase.idle;
  }
  final AirPlayPlaybackEngine airplay;
  final NativePlaybackReservation reservation;
  final DlnaTargetResolver? _resolveTarget;
  final Duration connectTimeout;
  final Future<LeasedMediaServer> Function(
    File file,
    InternetAddress local,
    InternetAddress peer,
  )?
  _startServer;
  final Future<void> Function(LeasedMediaServer)? _closeServer;
  final phase = _DlnaNotifier();
  final _frames = StreamController<PlaybackFrame>.broadcast(sync: true);
  final _errors = StreamController<String>.broadcast(sync: true);
  final _interruptions = StreamController<PlaybackInterruption>.broadcast(
    sync: true,
  );
  final _subscriptions = <StreamSubscription<dynamic>>[];
  PlaybackFrame _local = const PlaybackFrame(), _remote = const PlaybackFrame();
  LocalMedia? _media;
  DlnaDevice? _device;
  LeasedMediaServer? _server;
  String? _expectedTrack;
  int _remoteMutations = 0;
  bool _authoritative = false, _disposed = false, _remoteTouched = false;
  int _pendingPlays = 0;
  bool get _playPending => _pendingPlays > 0;
  bool _connectQueued = false;
  bool _connectCancelled = false;
  bool _disconnectPending = false;
  Future<void>? _boundedDisconnect;
  bool _remoteStopConfirmed = false;
  bool _localPauseFailed = false;
  bool _cleanupUnconfirmed = false;
  Future<void>? _pendingInterruption;
  Future<void>? _boundedInterruption;
  String? _issue;
  Timer? _poll;
  int _generation = 0;
  Future<void> _operations = Future.value();
  Future<void>? _dispose;
  void _signal() {
    if (!_disposed) phase.signal();
  }

  void _set(DlnaPhase next, [String? message]) {
    _issue = message;
    phase.value = next;
    _signal();
  }

  bool get _dlnaLocked =>
      _connectQueued ||
      _disconnectPending ||
      _pendingInterruption != null ||
      phase.value != DlnaPhase.idle;
  @override
  bool get mediaSelectionLocked =>
      _connectQueued ||
      _disconnectPending ||
      _pendingInterruption != null ||
      phase.value != DlnaPhase.idle ||
      airplay.mediaSelectionLocked;
  @override
  String? get mediaSelectionIssue => _issue ?? airplay.mediaSelectionIssue;
  @override
  Listenable get mediaSelectionChanges => phase;
  @override
  Stream<PlaybackFrame> get frames => _frames.stream;
  @override
  Stream<String> get errors => _errors.stream;
  @override
  Stream<PlaybackInterruption> get interruptions => _interruptions.stream;
  @override
  Widget buildVideo({PlaybackFit fit = PlaybackFit.contain}) =>
      airplay.buildVideo(fit: fit);
  @override
  Future<void> open(LocalMedia media, {required Duration start}) async {
    if (_disposed) throw StateError('播放器已关闭');
    _media = media;
    await airplay.open(media, start: start);
  }

  Future<void> _serial(Future<void> Function() action) {
    final result = _operations.then((_) => action());
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<DlnaResolvedTarget> _resolve(String address) async {
    final target = InternetAddress.tryParse(address.trim());
    if (target == null ||
        target.type != InternetAddressType.IPv4 ||
        target.isLoopback ||
        target.isMulticast) {
      throw DlnaFailure('请输入同一局域网内的 IPv4 地址');
    }
    final host = await const MethodChannel('dev.orvex/airplay')
        .invokeMethod<String>('localRouteForIPv4', {
          'bridgeId': await reservation.bridgeID,
          'target': target.address,
        })
        .timeout(const Duration(seconds: 3));
    if (host == null) throw DlnaFailure('无法确定局域网接口');
    final local = InternetAddress.tryParse(host);
    if (local == null) throw DlnaFailure('局域网接口无效');
    final description = await DlnaDevice.discover(target, local);
    return DlnaResolvedTarget(
      await DlnaDevice.inspect(description, sourceAddress: local),
      local,
      target,
    );
  }

  Future<void> connect(String address) async {
    if (_disposed ||
        _connectQueued ||
        _pendingInterruption != null ||
        _localPauseFailed ||
        phase.value != DlnaPhase.idle ||
        airplay.mediaSelectionLocked) {
      throw DlnaFailure('播放器暂时不可投屏');
    }
    _connectQueued = true;
    _connectCancelled = false;
    _signal();
    final operation = _connectOperation(address);
    operation.then<void>(
      (_) {
        _connectQueued = false;
        _signal();
      },
      onError: (Object _, StackTrace _) {
        _connectQueued = false;
        _signal();
      },
    );
    await operation.timeout(
      connectTimeout,
      onTimeout: () {
        _connectCancelled = true;
        ++_generation;
        if (_server != null) {
          unawaited(
            _quarantine(
              _remoteTouched
                  ? '投屏连接超时；请停止接收端播放，缓冲内容可能继续播放'
                  : '投屏连接尚未完成，本地资源正在清理',
            ),
          );
        } else {
          _set(DlnaPhase.uncertain, '投屏连接尚未完成，本地资源正在清理');
        }
        throw DlnaFailure('投屏连接超时，本地资源尚未确认释放');
      },
    );
  }

  Future<void> _connectOperation(String address) => _serial(() async {
    if (_disposed ||
        _connectCancelled ||
        phase.value != DlnaPhase.idle ||
        airplay.mediaSelectionLocked ||
        _media == null) {
      throw DlnaFailure('播放器暂时不可投屏');
    }
    _set(DlnaPhase.connecting);
    _remoteStopConfirmed = false;
    final generation = ++_generation;
    var touchedRemote = false;
    try {
      final resolved = await (_resolveTarget ?? _resolve)(address);
      final target = resolved.peer;
      final local = resolved.local;
      final device = resolved.device;
      _device = device;
      if (_disposed || generation != _generation) throw DlnaFailure('会话已关闭');
      final wasPlaying = _local.playing;
      await airplay.pause();
      if (_disposed || generation != _generation) throw DlnaFailure('会话已关闭');
      final position = _local.position;
      final file = File.fromUri(_media!.uri);
      final server =
          await (_startServer?.call(file, local, target) ??
              LeasedMediaServer.start(file: file, bind: local, peer: target));
      _server = server;
      _expectedTrack = server.uri.toString();
      unawaited(
        server.expired.then((_) async {
          if (!_disposed &&
              identical(_server, server) &&
              phase.value == DlnaPhase.active) {
            await _quarantine('投屏文件授权已过期，请确认接收设备已停止');
          }
        }),
      );
      if (_disposed || generation != _generation) throw DlnaFailure('会话已关闭');
      touchedRemote = true;
      _remoteTouched = true;
      await device.command('SetAVTransportURI', {
        'InstanceID': '0',
        'CurrentURI': server.uri.toString(),
        'CurrentURIMetaData': DlnaDevice.mediaMetadata(
          server.uri,
          _media!.name,
          server.mimeType,
        ),
      });
      if (_disposed || generation != _generation) throw DlnaFailure('会话已关闭');
      if (position > Duration.zero) {
        await device.command('Seek', {
          'InstanceID': '0',
          'Unit': 'REL_TIME',
          'Target': _time(position),
        });
      }
      if (_disposed || generation != _generation) throw DlnaFailure('会话已关闭');
      final confirmedPosition = await _confirmPosition(position);
      if (_disposed || generation != _generation) throw DlnaFailure('会话已关闭');
      if (wasPlaying) {
        await device.command('Play', {'InstanceID': '0', 'Speed': '1'});
      }
      if (_disposed || generation != _generation) throw DlnaFailure('会话已关闭');
      final transportState = await _confirmTransport(
        wasPlaying
            ? {'PLAYING', 'TRANSITIONING'}
            : {'PAUSED_PLAYBACK', 'STOPPED'},
      );
      if (_disposed || generation != _generation) throw DlnaFailure('会话已关闭');
      _authoritative = true;
      _remote = PlaybackFrame(
        position: confirmedPosition,
        duration: _local.duration,
        playing: transportState == 'PLAYING',
        buffering: transportState == 'TRANSITIONING',
      );
      _frames.add(_remote);
      _set(DlnaPhase.active);
      _startPoll(generation);
    } catch (_) {
      if (touchedRemote) {
        await _quarantine('设备状态未知；请在接收设备停止播放，缓冲内容可能继续播放');
      } else {
        final server = _server;
        if (server != null) {
          final pending = Future<void>.sync(
            () => _closeServer?.call(server) ?? server.close(),
          );
          pending.ignore();
          try {
            await pending.timeout(const Duration(seconds: 3));
          } catch (_) {
            _cleanupUnconfirmed = true;
            _set(DlnaPhase.uncertain, '无法确认本地文件服务已关闭，请重启应用');
            rethrow;
          }
        }
        _server = null;
        _device = null;
        if (!_localPauseFailed && _pendingInterruption == null) {
          _set(DlnaPhase.idle);
        }
      }
      rethrow;
    }
  });
  static String _time(Duration d) {
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${pad(d.inHours)}:${pad(d.inMinutes % 60)}:${pad(d.inSeconds % 60)}';
  }

  static Duration? _parseTime(String? value) {
    final m = RegExp(r'^(\d+):(\d\d):(\d\d)(?:\.\d+)?$')
        .firstMatch(value ?? '');
    if (m == null) return null;
    final h = int.tryParse(m[1]!),
        mm = int.tryParse(m[2]!),
        ss = int.tryParse(m[3]!);
    if (h == null || mm == null || ss == null || mm > 59 || ss > 59) {
      return null;
    }
    return Duration(hours: h, minutes: mm, seconds: ss);
  }

  void _startPoll(int generation) {
    _poll?.cancel();
    var pending = false;
    _poll = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (pending || _disposed || phase.value != DlnaPhase.active) return;
      pending = true;
      try {
        final info = await _device!.command('GetPositionInfo', {
          'InstanceID': '0',
        });
        final state = await _device!.command('GetTransportInfo', {
          'InstanceID': '0',
        });
        if (_disposed ||
            generation != _generation ||
            phase.value != DlnaPhase.active) {
          return;
        }
        _checkTrack(info);
        final position = _parseTime(info['RelTime']) ?? _remote.position;
        final duration = _parseTime(info['TrackDuration']) ?? _remote.duration;
        final status = state['CurrentTransportState'];
        if (!const {
          'PLAYING',
          'PAUSED_PLAYBACK',
          'TRANSITIONING',
          'STOPPED',
        }.contains(status)) {
          throw DlnaFailure('设备状态未知');
        }
        _server!.renew();
        _remote = PlaybackFrame(
          position: position,
          duration: duration,
          playing: status == 'PLAYING',
          buffering: status == 'TRANSITIONING',
        );
        _frames.add(_remote);
      } catch (_) {
        if (!_disposed && generation == _generation) {
          await _quarantine('无法确认设备状态；请在接收设备停止播放，缓冲内容可能继续播放');
        }
      } finally {
        pending = false;
      }
    });
  }

  Future<void> _quarantine(String message) async {
    ++_generation;
    _poll?.cancel();
    _set(DlnaPhase.uncertain, message);
    try {
      final server = _server;
      if (server != null) {
        final pending = Future<void>.sync(
          () => _closeServer?.call(server) ?? server.close(),
        );
        pending.ignore();
        await pending.timeout(const Duration(seconds: 3));
      }
    } catch (_) {
      _cleanupUnconfirmed = true;
      _set(DlnaPhase.uncertain, '无法确认本地文件服务已关闭；请停止接收端播放并重启应用');
    }
  }

  void _checkTrack(Map<String, String> info) {
    final expected = _expectedTrack;
    if (expected == null || info['TrackURI'] != expected) {
      throw DlnaFailure('接收设备播放内容无法确认');
    }
  }

  Future<void> _verifyCurrentTrack() async {
    final info = await _device!.command('GetPositionInfo', {
      'InstanceID': '0',
    }, timeout: const Duration(seconds: 1));
    _checkTrack(info);
  }

  Future<Duration> _confirmPosition(Duration target) async {
    final deadline = Stopwatch()..start();
    while (deadline.elapsed < const Duration(seconds: 4)) {
      try {
        final info = await _device!.command('GetPositionInfo', {
          'InstanceID': '0',
        }, timeout: const Duration(seconds: 1));
        _checkTrack(info);
        final observed = _parseTime(info['RelTime']);
        if (observed != null &&
            (observed - target).abs() <= const Duration(seconds: 3)) {
          return observed;
        }
      } catch (_) {
        // Retain the last confirmed position until the device agrees.
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw DlnaFailure('接收设备播放位置未确认');
  }

  Future<String> _confirmTransport(Set<String> allowed) async {
    final deadline = Stopwatch()..start();
    while (deadline.elapsed < const Duration(seconds: 4)) {
      try {
        final status = await _device!.command('GetTransportInfo', {
          'InstanceID': '0',
        }, timeout: const Duration(seconds: 1));
        if (allowed.contains(status['CurrentTransportState'])) {
          await _verifyCurrentTrack();
          return status['CurrentTransportState']!;
        }
      } catch (_) {
        // A failed status query is not a confirmation.
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw DlnaFailure('接收设备状态未确认');
  }

  Future<void> disconnect() {
    if (_disposed || _disconnectPending || phase.value != DlnaPhase.active) {
      return Future.error(DlnaFailure('设备状态尚未确认'));
    }
    _disconnectPending = true;
    _signal();
    final operation = _disconnectOperation();
    operation.then<void>(
      (_) {
        _disconnectPending = false;
        _boundedDisconnect = null;
        _signal();
      },
      onError: (Object _, StackTrace _) {
        _disconnectPending = false;
        _boundedDisconnect = null;
        _signal();
      },
    );
    return _boundedDisconnect = operation.timeout(
      const Duration(seconds: 3),
      onTimeout: () {
        ++_generation;
        final message = _remoteStopConfirmed
            ? '接收设备已停止，本地恢复尚未完成，请重新打开视频'
            : '无法确认接收设备已停止；请停止接收端播放，缓冲内容可能继续播放';
        if (_server != null) {
          unawaited(_quarantine(message));
        } else {
          _set(DlnaPhase.uncertain, message);
        }
        throw DlnaFailure('停止投屏或本地恢复尚未确认');
      },
    );
  }

  Future<void> _disconnectOperation() => _serial(() async {
    if (_disposed || phase.value != DlnaPhase.active) {
      throw DlnaFailure('设备状态尚未确认');
    }
    _set(DlnaPhase.closing);
    final generation = ++_generation;
    _poll?.cancel();
    var remoteStopped = false;
    try {
      await _verifyCurrentTrack();
      if (_disposed || generation != _generation) {
        throw DlnaFailure('停止请求已失效');
      }
      await _device!.command('Stop', {'InstanceID': '0'});
      await _confirmTransport({'STOPPED'});
      remoteStopped = true;
      _remoteStopConfirmed = true;
      await _server!.close();
      _server = null;
      _device = null;
      _expectedTrack = null;
      if (_disposed || generation != _generation) {
        _remoteTouched = false;
        if (_disposed) {
          _authoritative = false;
          _set(DlnaPhase.idle);
        } else {
          _set(DlnaPhase.uncertain, '接收设备已停止，本地位置尚未恢复，请重新打开视频');
        }
        return;
      }
      await airplay.seek(_remote.position);
      if (_disposed || generation != _generation) {
        _remoteTouched = false;
        if (_disposed) {
          _authoritative = false;
          _set(DlnaPhase.idle);
        } else {
          _set(DlnaPhase.uncertain, '接收设备已停止，本地位置尚未恢复，请重新打开视频');
        }
        return;
      }
      await airplay.pause();
      if (_disposed || generation != _generation) {
        _remoteTouched = false;
        if (_disposed) {
          _authoritative = false;
          _set(DlnaPhase.idle);
        } else {
          _set(DlnaPhase.uncertain, '接收设备已停止，本地位置尚未恢复，请重新打开视频');
        }
        return;
      }
      _authoritative = false;
      _remoteTouched = false;
      _frames.add(
        PlaybackFrame(position: _remote.position, duration: _remote.duration),
      );
      _set(DlnaPhase.idle);
    } catch (_) {
      await _quarantine(
        remoteStopped
            ? '接收设备已停止，本地恢复或文件清理失败，请重启应用'
            : '无法确认设备已停止；请在接收设备停止播放，缓冲内容可能继续播放',
      );
      rethrow;
    }
  });
  Future<void> _remoteCommand(String action, Map<String, String> args) {
    final intent = _generation;
    _remoteMutations++;
    if (action == 'Play') _pendingPlays++;
    final operation = _serial(() async {
      if (_disposed ||
          intent != _generation ||
          phase.value != DlnaPhase.active) {
        throw DlnaFailure('设备状态尚未确认');
      }
      _poll?.cancel();
      final generation = ++_generation;
      try {
        await _verifyCurrentTrack();
        if (_disposed || generation != _generation) return;
        await _device!.command(action, args);
        if (_disposed || generation != _generation) return;
        String? confirmedState;
        Duration? confirmedPosition;
        if (action == 'Pause') {
          confirmedState = await _confirmTransport({
            'PAUSED_PLAYBACK',
            'STOPPED',
          });
        }
        if (action == 'Play') {
          confirmedState = await _confirmTransport({
            'PLAYING',
            'TRANSITIONING',
          });
        }
        if (action == 'Seek') {
          final target = _parseTime(args['Target']);
          if (target == null) throw DlnaFailure('无效的播放位置');
          confirmedPosition = await _confirmPosition(target);
        }
        if (_disposed || generation != _generation) return;
        _remote = PlaybackFrame(
          position: confirmedPosition ?? _remote.position,
          duration: _remote.duration,
          playing: confirmedState == null
              ? _remote.playing
              : confirmedState == 'PLAYING',
          buffering: confirmedState == 'TRANSITIONING',
        );
        _frames.add(_remote);
        _startPoll(generation);
      } catch (_) {
        await _quarantine('设备指令未确认；请在接收设备停止播放，缓冲内容可能继续播放');
        rethrow;
      }
    });
    return operation.whenComplete(() {
      _remoteMutations--;
      if (action == 'Play') _pendingPlays--;
    });
  }

  @override
  Future<void> togglePause() => _disposed
      ? Future.error(StateError('播放器已关闭'))
      : !_authoritative && _dlnaLocked
      ? Future.error(StateError('投屏正在连接或状态未确认'))
      : _authoritative
      ? _remoteCommand(_remote.playing ? 'Pause' : 'Play', {
          'InstanceID': '0',
          if (!_remote.playing) 'Speed': '1',
        })
      : airplay.togglePause();
  Future<void> _interruptConnecting() {
    if (_pendingInterruption != null) return _boundedInterruption!;
    _connectCancelled = true;
    ++_generation;
    if (_remoteTouched) {
      unawaited(_quarantine('投屏已中断；请在接收设备停止播放，缓冲内容可能继续播放'));
    }
    final previous = _operations;
    final localPause = Future<void>.sync(airplay.pause)
        .catchError((Object error, StackTrace trace) {
          _localPauseFailed = true;
          _set(DlnaPhase.uncertain, '无法确认本地播放已暂停，请关闭播放器后重启应用');
          Error.throwWithStackTrace(error, trace);
        });
    final pending = Future.wait<void>([previous, localPause])
        .then<void>((_) {});
    _operations = pending.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _pendingInterruption = pending;
    pending.then<void>(
      (_) {
        if (identical(_pendingInterruption, pending)) {
          _pendingInterruption = null;
          _boundedInterruption = null;
        }
        if (!_localPauseFailed && !_cleanupUnconfirmed && !_remoteTouched) {
          _set(DlnaPhase.idle);
        }
        _signal();
      },
      onError: (Object _, StackTrace _) {
        if (identical(_pendingInterruption, pending)) {
          _pendingInterruption = null;
          _boundedInterruption = null;
        }
        _signal();
      },
    );
    return _boundedInterruption = pending.timeout(
      const Duration(seconds: 3),
      onTimeout: () {
        _set(DlnaPhase.uncertain, '本地暂停或连接清理尚未完成');
        throw DlnaFailure('本地暂停尚未确认');
      },
    );
  }

  @override
  Future<void> pause() {
    if (_disposed) return Future.error(StateError('播放器已关闭'));
    if (_disconnectPending && _boundedDisconnect != null) {
      return _boundedDisconnect!;
    }
    if (_pendingInterruption != null) return _boundedInterruption!;
    if (_connectQueued && !_authoritative) return _interruptConnecting();
    if (_playPending) {
      ++_generation;
      unawaited(_quarantine('播放已中断；请在接收设备停止播放，缓冲内容可能继续播放'));
      return _operations;
    }
    if (!_authoritative && phase.value != DlnaPhase.idle) {
      return Future.error(StateError('投屏状态未确认'));
    }
    return _authoritative
        ? _remoteCommand('Pause', {'InstanceID': '0'})
        : airplay.pause();
  }

  @override
  Future<void> seek(Duration p) => _disposed
      ? Future.error(StateError('播放器已关闭'))
      : !_authoritative && _dlnaLocked
      ? Future.error(StateError('投屏正在连接或状态未确认'))
      : _authoritative
      ? _remoteCommand('Seek', {
          'InstanceID': '0',
          'Unit': 'REL_TIME',
          'Target': _time(p),
        })
      : airplay.seek(p);
  @override
  Future<void> setRate(double rate) => _disposed
      ? Future.error(StateError('播放器已关闭'))
      : mediaSelectionLocked
      ? Future.error(StateError('投屏期间不能调整倍速'))
      : airplay.setRate(rate);
  @override
  Future<void> setVolume(double volume) => _disposed
      ? Future.error(StateError('播放器已关闭'))
      : _authoritative
      ? Future.error(StateError('请使用接收设备的音量控制'))
      : airplay.setVolume(volume);
  @override
  Future<void> setSubtitleStyle(SubtitleStyle style) => _disposed
      ? Future.error(StateError('播放器已关闭'))
      : _authoritative
      ? Future.error(StateError('投屏期间无法调整字幕样式'))
      : airplay.setSubtitleStyle(style);
  @override
  Future<void> selectAudio(String id) => _disposed
      ? Future.error(StateError('播放器已关闭'))
      : mediaSelectionLocked
      ? Future.error(StateError('投屏期间不能选择音轨'))
      : airplay.selectAudio(id);
  @override
  Future<void> selectSubtitle(String id) => _disposed
      ? Future.error(StateError('播放器已关闭'))
      : mediaSelectionLocked
      ? Future.error(StateError('投屏期间不能选择字幕'))
      : airplay.selectSubtitle(id);
  @override
  Future<String?> confirmedSubtitleTrackId() => _disposed
      ? Future.error(StateError('播放器已关闭'))
      : _authoritative
      ? Future.value(null)
      : airplay.confirmedSubtitleTrackId();
  @override
  Future<void> loadSubtitle(Uri uri, String name) => _disposed
      ? Future.error(StateError('播放器已关闭'))
      : mediaSelectionLocked
      ? Future.error(StateError('投屏期间不能加载外挂字幕'))
      : airplay.loadSubtitle(uri, name);
  @override
  Future<void> dispose() => _dispose ??= _disposeOnce();
  Future<void> _disposeOnce() async {
    _disposed = true;
    ++_generation;
    _poll?.cancel();
    final phaseAtClose = phase.value;
    final busyRemote = _remoteMutations > 0;
    if (busyRemote && _authoritative) {
      _set(DlnaPhase.uncertain, '播放状态未知；请在接收设备停止播放');
    }
    // Revoke the source synchronously before awaiting any unrelated cleanup.
    final server = _server;
    final serverClose = server == null
        ? Future<void>.value()
        : Future<void>.sync(server.close);
    airplay.mediaSelectionChanges.removeListener(_signal);
    final priorOperations = _operations;
    // A connecting/interrupting local pause may still use the underlying engine.
    final localDispose =
        _connectQueued ||
            _pendingInterruption != null ||
            _disconnectPending ||
            phaseAtClose == DlnaPhase.closing
        ? priorOperations.then((_) => airplay.dispose())
        : Future<void>.sync(airplay.dispose);
    Future<void> stopRemote() async {
      if (phaseAtClose != DlnaPhase.active || busyRemote) return;
      try {
        await _verifyCurrentTrack();
        await _device!.command('Stop', {'InstanceID': '0'});
        await _confirmTransport({'STOPPED'});
      } catch (_) {
        _set(DlnaPhase.uncertain, '无法确认设备已停止');
        rethrow;
      }
    }

    final remoteStop = stopRemote();
    // Await all even if one fails; ownership and source scope stay retained.
    await Future.wait([priorOperations, serverClose, localDispose, remoteStop]);
    airplay.routeAllowed = null;
    if (phase.value == DlnaPhase.uncertain ||
        phase.value == DlnaPhase.connecting ||
        phase.value == DlnaPhase.closing) {
      throw StateError('远端设备状态未知');
    }
    for (final s in _subscriptions) {
      await s.cancel();
    }
    await _frames.close();
    await _errors.close();
    await _interruptions.close();
    phase.dispose();
  }
}
