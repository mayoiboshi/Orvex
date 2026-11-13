import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:orvex/features/player/infrastructure/airplay_playback_engine.dart';
import 'package:orvex/features/player/infrastructure/dlna/dlna_client.dart';
import 'package:orvex/features/player/infrastructure/dlna/dlna_playback_engine.dart';
import 'package:orvex/features/player/infrastructure/dlna/media_server.dart';

import 'support/fakes.dart';

class NoAirPlay implements AirPlayTransport {
  int? token;
  int pauses = 0;
  final c = StreamController<AirPlayNativeEvent>.broadcast(sync: true);
  @override
  Stream<AirPlayNativeEvent> get events => c.stream;
  @override
  Future<void> close(int token) async {}
  @override
  Future<void> dispose() async {
    await c.close();
  }

  @override
  Future<void> pause(int token) async {
    pauses++;
  }

  @override
  Future<void> play(int token, {bool userInitiated = false}) async {}
  @override
  Future<void> prepare(LocalMedia m, Duration p, int token) async {
    this.token = token;
  }

  @override
  Future<void> probe(int token) async {}
  @override
  Future<void> seek(Duration p, int token) async {}
  @override
  Future<AirPlayNativeEvent> snapshot(int token) async => AirPlayNativeEvent(
    token: token,
    kind: 'state',
    external: true,
    frame: const PlaybackFrame(playing: true),
  );
}

class PauseGateEngine extends FakeEngine {
  final started = Completer<void>();
  final gate = Completer<void>();
  @override
  Future<void> pause() async {
    if (!started.isCompleted) started.complete();
    await gate.future;
  }
}

class FailPauseEngine extends FakeEngine {
  @override
  Future<void> pause() async {
    throw StateError('pause failed');
  }
}

class HangingDisposeEngine extends FakeEngine {
  final gate = Completer<void>();
  @override
  Future<void> dispose() async {
    await gate.future;
    await super.dispose();
  }
}

class HangingLocalSeekEngine extends FakeEngine {
  final gate = Completer<void>();
  final started = Completer<void>();
  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    if (!started.isCompleted) started.complete();
    await gate.future;
  }
}

class HangingRestorePauseEngine extends FakeEngine {
  int count = 0;
  final gate = Completer<void>(), started = Completer<void>();
  @override
  Future<void> pause() async {
    pauses++;
    count++;
    if (count >= 2) {
      if (!started.isCompleted) started.complete();
      await gate.future;
    }
  }
}

class FailedLocalSeekEngine extends FakeEngine {
  @override
  Future<void> seek(Duration position) async {
    throw StateError('local seek failed');
  }
}

class Renderer {
  late HttpServer server;
  final actions = <String>[];
  String status = 'STOPPED',
      position = '00:00:00',
      duration = '00:02:00',
      track = '';
  bool ignoreStop = false,
      ignorePause = false,
      ignoreSeek = false,
      switchOnStop = false;
  Duration stopDelay = Duration.zero;
  Completer<void>? setGate, stopGate, positionGate, playGate, seekGate;
  Completer<void> observedSet = Completer<void>(),
      observedStop = Completer<void>(),
      observedSeek = Completer<void>(),
      observedPlay = Completer<void>(),
      observedPosition = Completer<void>();
  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final res = req.response;
      try {
        if (req.method == 'GET') {
          res.write(
            '<root><device><deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType><serviceList><service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>/control</controlURL></service></serviceList></device></root>',
          );
        } else {
          final action = (req.headers.value('soapaction') ?? '')
              .split('#')
              .last
              .replaceAll('"', '');
          final body = await utf8.decoder.bind(req).join();
          final xml = XmlDocument.parse(body);
          String field(String name) => xml.descendants
              .whereType<XmlElement>()
              .singleWhere((x) => x.name.local == name)
              .innerText;
          actions.add(action);
          final oldPosition = position;
          if (action == 'SetAVTransportURI') track = field('CurrentURI');
          if (action == 'Seek') {
            if (!observedSeek.isCompleted) observedSeek.complete();
            await seekGate?.future;
            if (!ignoreSeek) position = field('Target');
          }

          if (action == 'SetAVTransportURI') {
            if (!observedSet.isCompleted) observedSet.complete();
            await setGate?.future;
          }
          if (action == 'GetPositionInfo') {
            if (!observedPosition.isCompleted) observedPosition.complete();
            final gate = positionGate;
            positionGate = null;
            await gate?.future;
          }
          if (action == 'Stop') {
            if (!observedStop.isCompleted) observedStop.complete();
            await stopGate?.future;
            if (!ignoreStop) {
              if (stopDelay == Duration.zero) {
                status = 'STOPPED';
              } else {
                Timer(stopDelay, () {
                  status = 'STOPPED';
                });
              }
            }
          }
          if (action == 'Stop' && switchOnStop) {
            track = 'http://127.0.0.1/other-video';
          }
          if (action == 'Play') {
            if (!observedPlay.isCompleted) observedPlay.complete();
            await playGate?.future;
            status = 'PLAYING';
            if (position == '00:00:00') position = '00:00:20';
          }
          if (action == 'Pause' && !ignorePause) status = 'PAUSED_PLAYBACK';
          final fields = action == 'GetPositionInfo'
              ? '<RelTime>$oldPosition</RelTime><TrackDuration>$duration</TrackDuration><TrackURI>$track</TrackURI>'
              : action == 'GetTransportInfo'
              ? '<CurrentTransportState>$status</CurrentTransportState>'
              : '';
          res.write(
            '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:${action}Response xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">$fields</u:${action}Response></s:Body></s:Envelope>',
          );
        }
        await res.close();
      } catch (_) {
        try {
          await res.close();
        } catch (_) {}
      }
    });
  }

  Future<DlnaResolvedTarget> resolve(String _) async {
    final loop = InternetAddress.loopbackIPv4;
    final d = await DlnaDevice.inspect(
      Uri.parse('http://127.0.0.1:${server.port}/description'),
      allowLoopback: true,
      sourceAddress: loop,
    );
    return DlnaResolvedTarget(d, loop, loop);
  }

  Future<void> close() async {
    setGate?.complete();
    stopGate?.complete();
    positionGate?.complete();
    playGate?.complete();
    seekGate?.complete();
    await server.close(force: true);
  }
}

void main() {
  late Directory dir;
  late Renderer remote;
  late FakeEngine local;
  late DlnaPlaybackEngine engine;
  late NoAirPlay native;
  var failServerClose = false;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('orvex-dlna-test-');
    final file = File('${dir.path}/fixture')..writeAsStringSync('0123456789');
    remote = Renderer();
    await remote.start();
    local = FakeEngine();
    native = NoAirPlay();
    final air = AirPlayPlaybackEngine(local, transport: native);
    failServerClose = false;
    engine = DlnaPlaybackEngine(
      air,
      NativePlaybackReservation(),
      resolveTarget: remote.resolve,
      closeServer: (server) async {
        if (failServerClose) throw StateError('test server close failed');
        await server.close();
      },
    );
    await engine.open(
      LocalMedia(uri: file.uri, name: 'fixture'),
      start: Duration.zero,
    );
    local.frameController.add(
      const PlaybackFrame(
        position: Duration.zero,
        duration: Duration(minutes: 2),
        playing: true,
      ),
    );
  });
  tearDown(() async {
    await remote.close();
    await dir.delete(recursive: true);
  });
  test('poll rejects overflowing remote position and duration', () async {
    await engine.connect('test');

    Future<PlaybackFrame> poll(String position, String duration) {
      final next = engine.frames.first.timeout(const Duration(seconds: 3));
      remote.position = position;
      remote.duration = duration;
      return next;
    }

    final normal = await poll('00:00:21', '00:02:03');
    expect(normal.position, const Duration(seconds: 21));
    expect(normal.duration, const Duration(seconds: 123));

    final overflowing = await poll(
      '2562047789:00:00',
      '999999999999999999:00:00',
    );
    expect(overflowing.position, normal.position);
    expect(overflowing.duration, normal.duration);

    // The largest whole second in a signed 64-bit microsecond Duration is
    // accepted, but the immediately following second must be ignored.
    const maximum = Duration(seconds: 9223372036854);
    final boundary = await poll('2562047788:00:54', '2562047788:00:54');
    expect(boundary.position, maximum);
    expect(boundary.duration, maximum);
    final tooLarge = await poll('2562047788:00:55', '00:60:00');
    expect(tooLarge.position, maximum);
    expect(tooLarge.duration, maximum);

    await engine.disconnect();
    await engine.dispose();
  });
  test('hung local pause times out visibly but retains owner until late completion', () async {
    final localGate = PauseGateEngine();
    // Discovery must finish before the 50 ms budget starts: this test is
    // about a blocked local pause, not loopback HTTP scheduling latency.
    final target = await remote.resolve('test');
    final other = DlnaPlaybackEngine(
      AirPlayPlaybackEngine(localGate, transport: NoAirPlay()),
      NativePlaybackReservation(),
      resolveTarget: (_) async => target,
      connectTimeout: const Duration(milliseconds: 50),
    );
    addTearDown(() async {
      if (!localGate.gate.isCompleted) localGate.gate.complete();
      await other.dispose().timeout(const Duration(seconds: 3));
      await engine.dispose().timeout(const Duration(seconds: 3));
    });
    await other.open(
      LocalMedia(uri: File('${dir.path}/fixture').uri, name: 'fixture'),
      start: Duration.zero,
    );
    final result = other.connect('test');
    // Observe failures immediately even if starting the pause fails or hangs.
    final timedOut = expectLater(result, throwsA(isA<DlnaFailure>()));
    await localGate.started.future.timeout(const Duration(seconds: 3));
    await timedOut.timeout(const Duration(seconds: 3));
    expect(other.phase.value, DlnaPhase.uncertain);
    expect(other.mediaSelectionLocked, isTrue);
    var closed = false;
    final closing = other.dispose().then((_) {
      closed = true;
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(closed, isFalse);
    expect(localGate.disposed, isFalse);
    expect(await other.airplay.prepareRoute(), isFalse);
    localGate.gate.complete();
    await closing.timeout(const Duration(seconds: 3));
    expect(localGate.disposed, isTrue);
    expect(remote.actions, isNot(contains('SetAVTransportURI')));
  });
  test(
    'hung file server startup retains owner and closes late source',
    () async {
      final local2 = FakeEngine();
      final gate = Completer<void>();
      final serverStarted = Completer<void>();
      final target = await remote.resolve('test');
      LeasedMediaServer? lateServer;
      final other = DlnaPlaybackEngine(
        AirPlayPlaybackEngine(local2, transport: NoAirPlay()),
        NativePlaybackReservation(),
        resolveTarget: (_) async => target,
        connectTimeout: const Duration(milliseconds: 50),
        startServer: (file, local, peer) async {
          serverStarted.complete();
          await gate.future;
          return lateServer = await LeasedMediaServer.start(
            file: file,
            bind: local,
            peer: peer,
          );
        },
      );
      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
        await other.dispose().timeout(const Duration(seconds: 3));
        await engine.dispose().timeout(const Duration(seconds: 3));
      });
      await other.open(
        LocalMedia(uri: File('${dir.path}/fixture').uri, name: 'fixture'),
        start: Duration.zero,
      );
      final timedOut = expectLater(
        other.connect('test'),
        throwsA(isA<DlnaFailure>()),
      );
      await serverStarted.future.timeout(const Duration(seconds: 3));
      await timedOut.timeout(const Duration(seconds: 3));
      expect(other.phase.value, DlnaPhase.uncertain);
      var closed = false;
      final closing = other.dispose().then((_) {
        closed = true;
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(closed, isFalse);
      expect(local2.disposed, isFalse);
      gate.complete();
      await closing.timeout(const Duration(seconds: 3));
      expect(lateServer, isNotNull);
      expect(local2.disposed, isTrue);
      expect(remote.actions, isNot(contains('SetAVTransportURI')));
    },
  );
  test(
    'close during discovery releases resources if no device command was sent',
    () async {
      final gate = Completer<DlnaResolvedTarget>();
      final otherLocal = FakeEngine();
      final other = DlnaPlaybackEngine(
        AirPlayPlaybackEngine(otherLocal, transport: NoAirPlay()),
        NativePlaybackReservation(),
        resolveTarget: (_) => gate.future,
      );
      final file = File('${dir.path}/fixture');
      await other.open(
        LocalMedia(uri: file.uri, name: 'fixture'),
        start: Duration.zero,
      );
      final connect = other.connect('test');
      await Future<void>.delayed(Duration.zero);
      final close = other.dispose();
      gate.complete(await remote.resolve('test'));
      await expectLater(connect, throwsA(isA<DlnaFailure>()));
      await close;
      expect(otherLocal.disposed, isTrue);
      await engine.dispose();
    },
  );
  for (final hang in [false, true]) {
    test(
      'source close ${hang ? 'hang' : 'failure'} before remote command remains quarantined',
      () async {
        final local = FakeEngine();
        final closeGate = Completer<void>();
        final started = Completer<void>();
        final returnGate = Completer<void>();
        final other = DlnaPlaybackEngine(
          AirPlayPlaybackEngine(local, transport: NoAirPlay()),
          NativePlaybackReservation(),
          resolveTarget: remote.resolve,
          startServer: (file, bind, peer) async {
            final server = await LeasedMediaServer.start(
              file: file,
              bind: bind,
              peer: peer,
            );
            started.complete();
            await returnGate.future;
            return server;
          },
          closeServer: (_) async {
            if (hang) {
              await closeGate.future;
            } else {
              throw StateError('close failed');
            }
          },
        );
        final file = File('${dir.path}/fixture');
        await other.open(
          LocalMedia(uri: file.uri, name: 'fixture'),
          start: Duration.zero,
        );
        final connecting = other.connect('test');
        await started.future;
        final cancel = other.pause();
        final cancelCheck = hang
            ? expectLater(cancel, throwsA(isA<DlnaFailure>()))
            : cancel;
        returnGate.complete();
        await expectLater(connecting, throwsA(anything));
        await cancelCheck;
        expect(other.phase.value, DlnaPhase.uncertain);
        expect(
          other.mediaSelectionIssue,
          anyOf(contains('文件服务已关闭'), contains('清理尚未完成')),
        );
        expect(remote.actions, isNot(contains('SetAVTransportURI')));
        if (hang) closeGate.complete();
        await expectLater(other.dispose(), throwsStateError);
        await engine.dispose();
      },
    );
  }
  test(
    'background in same turn as queued connect cancels before network',
    () async {
      final connecting = engine.connect('test');
      final toggleCheck = expectLater(engine.togglePause(), throwsStateError);
      final seekCheck = expectLater(
        engine.seek(const Duration(seconds: 10)),
        throwsStateError,
      );
      final paused = engine.pause();
      await expectLater(connecting, throwsA(isA<DlnaFailure>()));
      await toggleCheck;
      await seekCheck;
      await paused;
      expect(local.pauses, 1);
      expect(local.toggles, 0);
      expect(local.seeks, isEmpty);
      expect(remote.actions, isEmpty);
      expect(engine.mediaSelectionLocked, isFalse);
      await engine.dispose();
    },
  );
  test(
    'repeated background pause is bounded while raw pause remains owned',
    () async {
      final local2 = PauseGateEngine();
      final other = DlnaPlaybackEngine(
        AirPlayPlaybackEngine(local2, transport: NoAirPlay()),
        NativePlaybackReservation(),
        resolveTarget: remote.resolve,
      );
      await other.open(
        LocalMedia(uri: File('${dir.path}/fixture').uri, name: 'fixture'),
        start: Duration.zero,
      );
      final connecting = other.connect('test');
      final first = other.pause();
      final second = other.pause();
      final firstCheck = expectLater(first, throwsA(isA<DlnaFailure>()));
      final secondCheck = expectLater(second, throwsA(isA<DlnaFailure>()));
      await expectLater(connecting, throwsA(isA<DlnaFailure>()));
      await firstCheck;
      await secondCheck;
      expect(other.mediaSelectionLocked, isTrue);
      expect(local2.disposed, isFalse);
      final closing = other.dispose();
      local2.gate.complete();
      await closing;
      expect(local2.disposed, isTrue);
      await engine.dispose();
    },
  );
  test('background during discovery pauses local immediately', () async {
    final gate = Completer<DlnaResolvedTarget>();
    final local2 = FakeEngine();
    final other = DlnaPlaybackEngine(
      AirPlayPlaybackEngine(local2, transport: NoAirPlay()),
      NativePlaybackReservation(),
      resolveTarget: (_) => gate.future,
    );
    await other.open(
      LocalMedia(uri: File('${dir.path}/fixture').uri, name: 'fixture'),
      start: Duration.zero,
    );
    final connecting = other.connect('test');
    await Future<void>.delayed(Duration.zero);
    final pause = other.pause();
    await Future<void>.delayed(Duration.zero);
    expect(local2.pauses, 1);
    gate.complete(await remote.resolve('test'));
    await expectLater(connecting, throwsA(isA<DlnaFailure>()));
    await pause;
    expect(remote.actions, isEmpty);
    await other.dispose();
    await engine.dispose();
  });
  test('background after discovery timeout still pauses local', () async {
    final gate = Completer<DlnaResolvedTarget>();
    final local2 = FakeEngine();
    final other = DlnaPlaybackEngine(
      AirPlayPlaybackEngine(local2, transport: NoAirPlay()),
      NativePlaybackReservation(),
      resolveTarget: (_) => gate.future,
      connectTimeout: const Duration(milliseconds: 50),
    );
    await other.open(
      LocalMedia(uri: File('${dir.path}/fixture').uri, name: 'fixture'),
      start: Duration.zero,
    );
    await expectLater(other.connect('test'), throwsA(isA<DlnaFailure>()));
    final pause = other.pause();
    await Future<void>.delayed(Duration.zero);
    expect(local2.pauses, 1);
    gate.complete(await remote.resolve('test'));
    await pause;
    await other.dispose();
    await engine.dispose();
  });
  test('pending local interruption blocks both new routing protocols until settled', () async {
    final local2 = PauseGateEngine();
    final other = DlnaPlaybackEngine(
      AirPlayPlaybackEngine(local2, transport: NoAirPlay()),
      NativePlaybackReservation(),
      resolveTarget: remote.resolve,
    );
    await other.open(
      LocalMedia(uri: File('${dir.path}/fixture').uri, name: 'fixture'),
      start: Duration.zero,
    );
    final connecting = other.connect('test');
    final pause = other.pause();
    await local2.started.future;
    await expectLater(connecting, throwsA(isA<DlnaFailure>()));
    expect(other.mediaSelectionLocked, isTrue);
    expect(await other.airplay.prepareRoute(), isFalse);
    await expectLater(other.connect('test'), throwsA(isA<DlnaFailure>()));
    local2.gate.complete();
    await pause;
    await other.dispose();
    await engine.dispose();
  });
  test('failed background local pause stays locked and stops local during disposal', () async {
    final local2 = FailPauseEngine();
    final other = DlnaPlaybackEngine(
      AirPlayPlaybackEngine(local2, transport: NoAirPlay()),
      NativePlaybackReservation(),
      resolveTarget: remote.resolve,
    );
    await other.open(
      LocalMedia(uri: File('${dir.path}/fixture').uri, name: 'fixture'),
      start: Duration.zero,
    );
    final connecting = other.connect('test');
    final pause = other.pause();
    final pauseCheck = expectLater(pause, throwsStateError);
    await expectLater(connecting, throwsA(isA<DlnaFailure>()));
    await pauseCheck;
    expect(other.phase.value, DlnaPhase.uncertain);
    await expectLater(other.dispose(), throwsStateError);
    expect(local2.disposed, isTrue);
    await engine.dispose();
  });
  test(
    'closing revokes file and issues Stop even while local dispose hangs',
    () async {
      final local2 = HangingDisposeEngine();
      final other = DlnaPlaybackEngine(
        AirPlayPlaybackEngine(local2, transport: NoAirPlay()),
        NativePlaybackReservation(),
        resolveTarget: remote.resolve,
      );
      await other.open(
        LocalMedia(uri: File('${dir.path}/fixture').uri, name: 'fixture'),
        start: Duration.zero,
      );
      local2.frameController.add(
        const PlaybackFrame(duration: Duration(minutes: 2), playing: true),
      );
      await other.connect('test');
      final uri = Uri.parse(remote.track);
      final closing = other.dispose();
      await remote.observedStop.future.timeout(const Duration(seconds: 2));
      final client = HttpClient()..findProxy = ((_) => 'DIRECT');
      try {
        final req = await client.getUrl(uri);
        final response = await req.close();
        expect(response.statusCode, isNot(200));
      } on SocketException {
        // Refusal means the source is no longer reachable.
      } finally {
        client.close(force: true);
      }
      expect(local2.disposed, isFalse);
      local2.gate.complete();
      await closing;
      expect(local2.disposed, isTrue);
      await engine.dispose();
    },
  );
  test('local dispose error does not prevent source revoke and Stop', () async {
    final local2 = FakeEngine()..failDispose = true;
    final other = DlnaPlaybackEngine(
      AirPlayPlaybackEngine(local2, transport: NoAirPlay()),
      NativePlaybackReservation(),
      resolveTarget: remote.resolve,
    );
    await other.open(
      LocalMedia(uri: File('${dir.path}/fixture').uri, name: 'fixture'),
      start: Duration.zero,
    );
    local2.frameController.add(
      const PlaybackFrame(duration: Duration(minutes: 2), playing: true),
    );
    await other.connect('test');
    final uri = Uri.parse(remote.track);
    final closing = other.dispose();
    final failure = expectLater(closing, throwsStateError);
    await remote.observedStop.future.timeout(const Duration(seconds: 2));
    await failure;
    final client = HttpClient()..findProxy = ((_) => 'DIRECT');
    try {
      final req = await client.getUrl(uri);
      final response = await req.close();
      expect(response.statusCode, isNot(200));
    } on SocketException {
      // Refusal means the source is no longer reachable.
    } finally {
      client.close(force: true);
    }
    await engine.dispose();
  });
  test(
    'closing during hung initial Play immediately revokes media source',
    () async {
      remote.playGate = Completer<void>();
      final gate = remote.playGate!;
      final connecting = engine.connect('test');
      await remote.observedPlay.future;
      final uri = Uri.parse(remote.track);
      final closing = engine.dispose();
      final client = HttpClient()..findProxy = ((_) => 'DIRECT');
      try {
        final req = await client.getUrl(uri);
        final response = await req.close();
        expect(response.statusCode, isNot(200));
      } on SocketException {
        // Refusal means the source is no longer reachable.
      } finally {
        client.close(force: true);
      }
      gate.complete();
      remote.playGate = null;
      await expectLater(connecting, throwsA(isA<DlnaFailure>()));
      await expectLater(closing, throwsStateError);
    },
  );
  test(
    'dispose during delayed confirmed Stop skips disposed local restore',
    () async {
      await engine.connect('test');
      remote.stopGate = Completer<void>();
      final gate = remote.stopGate!;
      final stopping = engine.disconnect();
      await remote.observedStop.future;
      final closing = engine.dispose();
      gate.complete();
      remote.stopGate = null;
      await stopping;
      await closing;
      expect(local.disposed, isTrue);
      expect(local.seeks, isEmpty);
      expect(remote.actions.where((action) => action == 'Stop').length, 1);
    },
  );
  test('dispose waits for local restore seek then skips stale pause', () async {
    final local2 = HangingLocalSeekEngine();
    final other = DlnaPlaybackEngine(
      AirPlayPlaybackEngine(local2, transport: NoAirPlay()),
      NativePlaybackReservation(),
      resolveTarget: remote.resolve,
    );
    await other.open(
      LocalMedia(uri: File('${dir.path}/fixture').uri, name: 'fixture'),
      start: Duration.zero,
    );
    local2.frameController.add(
      const PlaybackFrame(duration: Duration(minutes: 2), playing: true),
    );
    await other.connect('test');
    final stopping = other.disconnect();
    await local2.started.future;
    final closing = other.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(local2.disposed, isFalse);
    expect(await other.airplay.prepareRoute(), isFalse);
    local2.gate.complete();
    await stopping;
    await closing;
    expect(local2.disposed, isTrue);
    expect(local2.pauses, 1);
    await engine.dispose();
  });
  test('queued disconnect and dispose issue only one Stop', () async {
    await engine.connect('test');
    final stopping = engine.disconnect();
    final stopCheck = expectLater(stopping, throwsA(isA<DlnaFailure>()));
    final closing = engine.dispose();
    await stopCheck;
    await closing;
    expect(remote.actions.where((action) => action == 'Stop').length, 1);
  });
  test(
    'hanging local seek returns bounded feedback without releasing owner',
    () async {
      final local2 = HangingLocalSeekEngine();
      final other = DlnaPlaybackEngine(
        AirPlayPlaybackEngine(local2, transport: NoAirPlay()),
        NativePlaybackReservation(),
        resolveTarget: remote.resolve,
      );
      await other.open(
        LocalMedia(uri: File('${dir.path}/fixture').uri, name: 'fixture'),
        start: Duration.zero,
      );
      local2.frameController.add(
        const PlaybackFrame(duration: Duration(minutes: 2), playing: true),
      );
      await other.connect('test');
      final stopping = other.disconnect();
      final checked = expectLater(stopping, throwsA(isA<DlnaFailure>()));
      await local2.started.future;
      await checked;
      expect(other.mediaSelectionLocked, isTrue);
      var closed = false;
      final closing = other.dispose().then((_) {
        closed = true;
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(closed, isFalse);
      expect(local2.disposed, isFalse);
      local2.gate.complete();
      await closing;
      expect(local2.disposed, isTrue);
      await engine.dispose();
    },
  );
  test(
    'hanging local pause returns bounded feedback without releasing owner',
    () async {
      final local2 = HangingRestorePauseEngine();
      final other = DlnaPlaybackEngine(
        AirPlayPlaybackEngine(local2, transport: NoAirPlay()),
        NativePlaybackReservation(),
        resolveTarget: remote.resolve,
      );
      await other.open(
        LocalMedia(uri: File('${dir.path}/fixture').uri, name: 'fixture'),
        start: Duration.zero,
      );
      local2.frameController.add(
        const PlaybackFrame(duration: Duration(minutes: 2), playing: true),
      );
      await other.connect('test');
      final stopping = other.disconnect();
      final checked = expectLater(stopping, throwsA(isA<DlnaFailure>()));
      await local2.started.future;
      await checked;
      expect(other.mediaSelectionLocked, isTrue);
      var closed = false;
      final closing = other.dispose().then((_) {
        closed = true;
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(closed, isFalse);
      expect(local2.disposed, isFalse);
      local2.gate.complete();
      await closing;
      expect(local2.disposed, isTrue);
      await engine.dispose();
    },
  );
  test('local restore failure reports remote already stopped', () async {
    final local2 = FailedLocalSeekEngine();
    final other = DlnaPlaybackEngine(
      AirPlayPlaybackEngine(local2, transport: NoAirPlay()),
      NativePlaybackReservation(),
      resolveTarget: remote.resolve,
    );
    await other.open(
      LocalMedia(uri: File('${dir.path}/fixture').uri, name: 'fixture'),
      start: Duration.zero,
    );
    local2.frameController.add(
      const PlaybackFrame(duration: Duration(minutes: 2), playing: true),
    );
    await other.connect('test');
    await expectLater(other.disconnect(), throwsStateError);
    expect(other.phase.value, DlnaPhase.uncertain);
    expect(other.mediaSelectionIssue, contains('接收设备已停止'));
    expect(other.mediaSelectionLocked, isTrue);
    await expectLater(other.dispose(), throwsStateError);
    await engine.dispose();
  });
  test(
    'background during pending disconnect waits it without new Pause',
    () async {
      await engine.connect('test');
      remote.stopGate = Completer<void>();
      final gate = remote.stopGate!;
      final stopping = engine.disconnect();
      await remote.observedStop.future;
      final background = engine.pause();
      gate.complete();
      remote.stopGate = null;
      await stopping;
      await background;
      expect(remote.actions.where((action) => action == 'Pause'), isEmpty);
      expect(remote.actions.where((action) => action == 'Stop').length, 1);
      await engine.dispose();
    },
  );
  test(
    'closing with queued remote Play never races Stop or late Play',
    () async {
      local.frameController.add(
        const PlaybackFrame(duration: Duration(minutes: 2), playing: false),
      );
      await engine.connect('test');
      remote.seekGate = Completer<void>();
      final gate = remote.seekGate!;
      final first = engine.seek(const Duration(seconds: 10));
      await remote.observedSeek.future;
      final second = engine.togglePause();
      final secondCheck = expectLater(second, throwsA(isA<DlnaFailure>()));
      final closing = engine.dispose();
      expect(remote.actions, isNot(contains('Stop')));
      gate.complete();
      remote.seekGate = null;
      await first;
      await secondCheck;
      await expectLater(closing, throwsStateError);
      expect(remote.actions, isNot(contains('Play')));
      expect(remote.actions, isNot(contains('Stop')));
    },
  );
  test('two queued Plays remain guarded when background interrupts', () async {
    local.frameController.add(
      const PlaybackFrame(duration: Duration(minutes: 2), playing: false),
    );
    await engine.connect('test');
    remote.playGate = Completer<void>();
    final gate = remote.playGate!;
    final first = engine.togglePause();
    await remote.observedPlay.future;
    final second = engine.togglePause();
    final secondCheck = expectLater(second, throwsA(isA<DlnaFailure>()));
    final background = engine.pause();
    expect(engine.phase.value, DlnaPhase.uncertain);
    gate.complete();
    remote.playGate = null;
    await first;
    await secondCheck;
    await background;
    expect(remote.actions.where((x) => x == 'Play').length, 1);
    await expectLater(engine.dispose(), throwsStateError);
  });
  test(
    'disposed engine rejects stale controls while local disposal is pending',
    () async {
      final local2 = HangingDisposeEngine();
      final other = DlnaPlaybackEngine(
        AirPlayPlaybackEngine(local2, transport: NoAirPlay()),
        NativePlaybackReservation(),
        resolveTarget: remote.resolve,
      );
      await other.open(
        LocalMedia(uri: File('${dir.path}/fixture').uri, name: 'fixture'),
        start: Duration.zero,
      );
      final closing = other.dispose();
      await expectLater(other.togglePause(), throwsStateError);
      await expectLater(other.pause(), throwsStateError);
      await expectLater(
        other.seek(const Duration(seconds: 2)),
        throwsStateError,
      );
      await expectLater(other.setRate(2), throwsStateError);
      await expectLater(other.setVolume(30), throwsStateError);
      await expectLater(other.selectAudio('1'), throwsStateError);
      await expectLater(other.selectSubtitle('1'), throwsStateError);
      expect(local2.toggles, 0);
      expect(local2.seeks, isEmpty);
      local2.gate.complete();
      await closing;
      await engine.dispose();
    },
  );
  test(
    'routing adapters mutually exclude direct concurrent attempts',
    () async {
      remote.setGate = Completer<void>();
      final gate = remote.setGate!;
      final connecting = engine.connect('test');
      expect(await engine.airplay.prepareRoute(), isFalse);
      await remote.observedSet.future;
      expect(await engine.airplay.prepareRoute(), isFalse);
      gate.complete();
      remote.setGate = null;
      await connecting;
      await engine.disconnect();
      final airStart = engine.airplay.prepareRoute();
      await expectLater(engine.connect('test'), throwsA(isA<DlnaFailure>()));
      expect(await airStart, isTrue);
      await engine.airplay.cancelRoute();
      await engine.dispose();
    },
  );
  test(
    'AirPlay pause control remains available through DLNA wrapper',
    () async {
      expect(await engine.airplay.prepareRoute(), isTrue);
      native.c.add(
        AirPlayNativeEvent(token: native.token!, kind: 'state', external: true),
      );
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(engine.airplay.externalActive, isTrue);
      await engine.togglePause();
      expect(native.pauses, 1);
      await engine.airplay.cancelRoute();
      await engine.dispose();
    },
  );
  test('remote starts only after local pause, updates progress, and stops before local seek', () async {
    final frames = <PlaybackFrame>[];
    final sub = engine.frames.listen(frames.add);
    await engine.connect('test');
    expect(local.pauses, 1);
    expect(remote.actions, containsAllInOrder(['SetAVTransportURI', 'Play']));
    expect(engine.mediaSelectionLocked, isTrue);
    expect(engine.phase.value, DlnaPhase.active);
    expect(frames.last.playing, isTrue);
    expect(frames.last.buffering, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(frames.last.position, const Duration(seconds: 20));
    await engine.disconnect();
    expect(remote.actions, contains('Stop'));
    expect(
      remote.actions,
      containsAllInOrder(['Stop', 'GetTransportInfo', 'GetPositionInfo']),
    );
    expect(local.seeks, contains(const Duration(seconds: 20)));
    expect(engine.mediaSelectionLocked, isFalse);
    await sub.cancel();
    await engine.dispose();
  });
  test('a stale position poll cannot roll back a seek', () async {
    final frames = <PlaybackFrame>[];
    final sub = engine.frames.listen(frames.add);
    await engine.connect('test');
    remote.positionGate = Completer<void>();
    remote.observedPosition = Completer<void>();
    final oldGate = remote.positionGate!;
    await remote.observedPosition.future.timeout(const Duration(seconds: 3));
    await engine.seek(const Duration(seconds: 55));
    expect(frames.last.position, const Duration(seconds: 55));
    oldGate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(frames.last.position, const Duration(seconds: 55));
    await sub.cancel();
    await engine.disconnect();
    await engine.dispose();
  });
  test('disconnect restores the latest verified remote position', () async {
    final frames = <PlaybackFrame>[];
    final sub = engine.frames.listen(frames.add);
    await engine.connect('test');
    // A receiver-side seek after the last poll must be captured before Stop.
    remote.position = '00:01:15';
    await engine.disconnect();
    expect(local.seeks.last, const Duration(seconds: 75));
    expect(frames.last.position, const Duration(seconds: 75));
    await sub.cancel();
    await engine.dispose();
  });
  test(
    'disconnect retains the confirmed checkpoint for invalid remote time',
    () async {
      final frames = <PlaybackFrame>[];
      final sub = engine.frames.listen(frames.add);
      await engine.connect('test');
      remote.position = '00:00:40';
      await engine.frames.first.timeout(const Duration(seconds: 3));
      expect(frames.last.position, const Duration(seconds: 40));
      remote.position = 'NOT_IMPLEMENTED';
      await engine.disconnect();
      expect(local.seeks.last, const Duration(seconds: 40));
      expect(frames.last.position, const Duration(seconds: 40));
      await sub.cancel();
      await engine.dispose();
    },
  );
  test('foreign track does not overwrite progress or receive Stop', () async {
    final frames = <PlaybackFrame>[];
    final sub = engine.frames.listen(frames.add);
    await engine.connect('test');
    final confirmed = frames.last.position;
    remote.track = 'http://127.0.0.1/other-video';
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(engine.phase.value, DlnaPhase.uncertain);
    expect(frames.last.position, confirmed);
    expect(remote.actions, isNot(contains('Stop')));
    await sub.cancel();
    await expectLater(engine.dispose(), throwsStateError);
  });
  test('unconfirmed Seek never publishes target as trusted progress', () async {
    final frames = <PlaybackFrame>[];
    final sub = engine.frames.listen(frames.add);
    await engine.connect('test');
    final confirmed = frames.last.position;
    remote.ignoreSeek = true;
    await expectLater(
      engine.seek(const Duration(seconds: 55)),
      throwsA(isA<DlnaFailure>()),
    );
    expect(engine.phase.value, DlnaPhase.uncertain);
    expect(frames.last.position, confirmed);
    await sub.cancel();
    await expectLater(engine.dispose(), throwsStateError);
  });
  test('paused local video does not trigger remote Play', () async {
    local.frameController.add(
      const PlaybackFrame(
        position: Duration.zero,
        duration: Duration(minutes: 2),
        playing: false,
      ),
    );
    await engine.connect('test');
    expect(remote.actions, isNot(contains('Play')));
    expect(engine.phase.value, DlnaPhase.active);
    await engine.disconnect();
    await engine.dispose();
  });
  test('Stop reply waits for delayed STOPPED before returning local', () async {
    await engine.connect('test');
    remote.stopDelay = const Duration(milliseconds: 500);
    final stopping = engine.disconnect();
    await remote.observedStop.future;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(engine.mediaSelectionLocked, isTrue);
    expect(local.seeks, isEmpty);
    await stopping;
    expect(remote.status, 'STOPPED');
    expect(local.seeks, isNotEmpty);
    await engine.dispose();
  });
  test(
    'a track switched after Stop cannot confirm another item state',
    () async {
      await engine.connect('test');
      remote.position = '00:01:15';
      remote.switchOnStop = true;
      await expectLater(engine.disconnect(), throwsA(isA<DlnaFailure>()));
      expect(engine.phase.value, DlnaPhase.uncertain);
      expect(local.seeks, isEmpty);
      await expectLater(engine.dispose(), throwsStateError);
    },
  );
  test('fake successful Stop without STOPPED keeps quarantine', () async {
    await engine.connect('test');
    remote.ignoreStop = true;
    await expectLater(engine.disconnect(), throwsA(isA<DlnaFailure>()));
    expect(engine.phase.value, DlnaPhase.uncertain);
    expect(local.seeks, isEmpty);
    await expectLater(engine.dispose(), throwsStateError);
  });
  test(
    'fake successful background Pause without paused state keeps quarantine',
    () async {
      await engine.connect('test');
      remote.ignorePause = true;
      await expectLater(engine.pause(), throwsA(isA<DlnaFailure>()));
      expect(engine.phase.value, DlnaPhase.uncertain);
      expect(local.seeks, isEmpty);
      await expectLater(engine.dispose(), throwsStateError);
    },
  );
  test(
    'background while a resumed Play is in flight revokes remote source',
    () async {
      await engine.connect('test');
      await engine.pause();
      remote.observedPlay = Completer<void>();
      remote.playGate = Completer<void>();
      final gate = remote.playGate!;
      final resumed = engine.togglePause();
      await remote.observedPlay.future;
      final background = engine.pause();
      expect(engine.phase.value, DlnaPhase.uncertain);
      gate.complete();
      remote.playGate = null;
      await resumed;
      await background;
      expect(engine.phase.value, DlnaPhase.uncertain);
      expect(local.seeks, isEmpty);
      await expectLater(engine.dispose(), throwsStateError);
    },
  );
  test('failed asynchronous close remains visible and quarantined', () async {
    remote.playGate = Completer<void>();
    final gate = remote.playGate!;
    final connecting = engine.connect('test');
    await remote.observedPlay.future;
    failServerClose = true;
    final background = engine.pause();
    await Future<void>.delayed(Duration.zero);
    expect(engine.phase.value, DlnaPhase.uncertain);
    expect(engine.mediaSelectionIssue, contains('文件服务已关闭'));
    gate.complete();
    remote.playGate = null;
    await expectLater(connecting, throwsA(isA<DlnaFailure>()));
    await background;
    expect(engine.mediaSelectionLocked, isTrue);
    await expectLater(engine.dispose(), throwsStateError);
  });
  test('hanging close after remote command reports uncertainty without blocking forever', () async {
    final gate = Completer<void>();
    final local2 = FakeEngine();
    final other = DlnaPlaybackEngine(
      AirPlayPlaybackEngine(local2, transport: NoAirPlay()),
      NativePlaybackReservation(),
      resolveTarget: remote.resolve,
      closeServer: (_) => gate.future,
    );
    await other.open(
      LocalMedia(uri: File('${dir.path}/fixture').uri, name: 'fixture'),
      start: Duration.zero,
    );
    local2.frameController.add(
      const PlaybackFrame(duration: Duration(minutes: 2), playing: true),
    );
    remote.playGate = Completer<void>();
    final playGate = remote.playGate!;
    final connecting = other.connect('test');
    await remote.observedPlay.future;
    final paused = other.pause();
    final pauseCheck = expectLater(paused, throwsA(isA<DlnaFailure>()));
    playGate.complete();
    remote.playGate = null;
    await expectLater(connecting, throwsA(isA<DlnaFailure>()));
    await pauseCheck;
    expect(other.phase.value, DlnaPhase.uncertain);
    expect(other.mediaSelectionIssue, contains('文件服务已关闭'));
    gate.complete();
    await expectLater(other.dispose(), throwsStateError);
    await engine.dispose();
  });
  test('late Play reply after background cannot regain authority', () async {
    remote.playGate = Completer<void>();
    final playGate = remote.playGate!;
    final connecting = engine.connect('test');
    await remote.observedPlay.future;
    final background = engine.pause();
    expect(engine.phase.value, DlnaPhase.uncertain);
    playGate.complete();
    remote.playGate = null;
    await expectLater(connecting, throwsA(isA<DlnaFailure>()));
    await background;
    expect(engine.phase.value, DlnaPhase.uncertain);
    expect(local.seeks, isEmpty);
    await expectLater(engine.dispose(), throwsStateError);
  });
  test(
    'background during SetURI prevents later Play and keeps state quarantined',
    () async {
      remote.setGate = Completer<void>();
      final future = engine.connect('test');
      await remote.observedSet.future;
      final paused = engine.pause();
      remote.setGate!.complete();
      remote.setGate = null;
      await expectLater(future, throwsA(isA<DlnaFailure>()));
      await paused;
      expect(remote.actions, isNot(contains('Play')));
      expect(engine.phase.value, DlnaPhase.uncertain);
      expect(engine.mediaSelectionLocked, isTrue);
      await expectLater(engine.dispose(), throwsStateError);
    },
  );
  test('closing during pending SetURI does not allow queued Play', () async {
    remote.setGate = Completer<void>();
    final future = engine.connect('test');
    await remote.observedSet.future;
    final closing = engine.dispose();
    remote.setGate!.complete();
    remote.setGate = null;
    await expectLater(future, throwsA(isA<DlnaFailure>()));
    await expectLater(closing, throwsStateError);
    expect(remote.actions, isNot(contains('Play')));
  });
  test(
    'Stop timeout revokes old token and late reply cannot restore local',
    () async {
      await engine.connect('test');
      final uri = Uri.parse(remote.track);
      remote.stopGate = Completer<void>();
      final gate = remote.stopGate!;
      final stopping = engine.disconnect();
      await remote.observedStop.future;
      await expectLater(stopping, throwsA(isA<DlnaFailure>()));
      expect(engine.phase.value, DlnaPhase.uncertain);
      final client = HttpClient()..findProxy = ((_) => 'DIRECT');
      try {
        final req = await client.getUrl(uri);
        final response = await req.close();
        expect(response.statusCode, isNot(200));
      } on SocketException {
        /* Revoked listener cannot be reached. */
      } finally {
        client.close(force: true);
      }
      gate.complete();
      remote.stopGate = null;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(local.seeks, isEmpty);
      expect(engine.mediaSelectionLocked, isTrue);
      await expectLater(engine.dispose(), throwsStateError);
    },
  );
  test('Stop preflight arriving after timeout sends no stale Stop', () async {
    await engine.connect('test');
    remote.observedPosition = Completer<void>();
    remote.positionGate = Completer<void>();
    final gate = remote.positionGate!;
    final stopping = engine.disconnect();
    final checked = expectLater(stopping, throwsA(isA<DlnaFailure>()));
    await remote.observedPosition.future;
    await checked;
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(remote.actions, isNot(contains('Stop')));
    expect(engine.mediaSelectionLocked, isTrue);
    await expectLater(engine.dispose(), throwsStateError);
  });
  test('unconfirmed Stop keeps remote authority locked', () async {
    await engine.connect('test');
    remote.stopGate = Completer<void>();
    final stop = engine.disconnect();
    await remote.observedStop.future;
    await expectLater(stop, throwsA(isA<DlnaFailure>()));
    expect(engine.phase.value, DlnaPhase.uncertain);
    expect(engine.mediaSelectionLocked, isTrue);
    expect(local.seeks, isEmpty);
    await expectLater(engine.dispose(), throwsStateError);
  });
}
