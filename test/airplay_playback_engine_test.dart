import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/features/player/application/playback_session.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:orvex/features/player/infrastructure/airplay_playback_engine.dart';

import 'support/fakes.dart';

class _Transport implements AirPlayTransport {
  final controller = StreamController<AirPlayNativeEvent>.broadcast(sync: true);
  final calls = <String>[];
  Completer<void>? prepareGate;
  bool failPrepare = false;
  bool failSeek = false;
  Completer<void>? seekGate;
  bool failClose = false;
  Completer<void>? closeGate;
  Completer<void>? snapshotGate;
  int snapshotCalls = 0;
  int snapshotGateAt = 1;
  int snapshotSequence = 0;
  final snapshotSequenceQueue = <int>[];
  bool external = true;
  int? base;
  int virtual(int token) => token - (base ?? 0);
  @override
  Stream<AirPlayNativeEvent> get events => controller.stream.map(
    (event) => AirPlayNativeEvent(
      token: event.token + (base ?? 0),
      kind: event.kind,
      external: event.external,
      frame: event.frame,
      positionValid: event.positionValid,
      durationValid: event.durationValid,
      sequence: event.sequence,
    ),
  );
  @override
  Future<void> prepare(LocalMedia media, Duration position, int token) async {
    base ??= token - 1;
    calls.add('prepare:${virtual(token)}:${position.inSeconds}');
    await prepareGate?.future;
    if (failPrepare) throw StateError('prepare failed');
  }

  @override
  Future<void> probe(int token) async => calls.add('probe:${virtual(token)}');
  @override
  Future<void> seek(Duration position, int token) async {
    calls.add('seek:${virtual(token)}:${position.inSeconds}');
    await seekGate?.future;
    if (failSeek) throw StateError('seek');
  }

  @override
  Future<void> play(int token, {bool userInitiated = false}) async =>
      calls.add('play:${virtual(token)}');
  @override
  Future<void> pause(int token) async => calls.add('pause:${virtual(token)}');
  @override
  Future<void> close(int token) async {
    calls.add('close:${virtual(token)}');
    await closeGate?.future;
    if (failClose) throw StateError('native close failed');
  }

  @override
  Future<AirPlayNativeEvent> snapshot(int token) async {
    snapshotCalls++;
    final capturedSequence = snapshotSequenceQueue.isEmpty
        ? snapshotSequence
        : snapshotSequenceQueue.removeAt(0);
    if (snapshotCalls == snapshotGateAt) await snapshotGate?.future;
    return AirPlayNativeEvent(
      token: token,
      sequence: capturedSequence,
      kind: 'state',
      external: external,
      frame: const PlaybackFrame(
        position: Duration(seconds: 10),
        duration: Duration(minutes: 2),
      ),
    );
  }

  @override
  Future<void> dispose() async => controller.close();
}

class _HangingSeekEngine extends FakeEngine {
  final seekGate = Completer<void>();
  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    await seekGate.future;
  }
}

class _HangingStore extends MemoryResumeStore {
  final gate = Completer<void>();
  @override
  Future<void> write(String key, Duration position) async {
    await gate.future;
    await super.write(key, position);
  }
}

class _HangingCancelEngine extends FakeEngine {
  final gate = Completer<void>();
  late final controller = StreamController<PlaybackFrame>(
    sync: true,
    onCancel: () => gate.future,
  );
  @override
  Stream<PlaybackFrame> get frames => controller.stream;
  @override
  Future<void> cleanUp() async {
    await controller.close();
    await super.cleanUp();
  }
}

void main() {
  late FakeEngine local;
  late _Transport native;
  late AirPlayPlaybackEngine engine;
  const initial = PlaybackFrame(
    position: Duration(seconds: 10),
    duration: Duration(minutes: 2),
    playing: true,
  );
  final media = LocalMedia(uri: Uri.file('/sample.mp4'), name: 'sample.mp4');

  test(
    'newer state before delayed snapshot is refreshed without false failure',
    () async {
      native.snapshotSequenceQueue.addAll([20, 21, 30]);
      native.snapshotGateAt = 2;
      final gate = native.snapshotGate = Completer<void>();
      expect(await engine.prepareRoute(), isTrue);
      native.controller.add(
        const AirPlayNativeEvent(
          token: 1,
          kind: 'state',
          external: true,
          sequence: 10,
        ),
      );
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(native.snapshotCalls, 2);
      native.controller.add(
        const AirPlayNativeEvent(
          token: 1,
          kind: 'state',
          external: true,
          sequence: 25,
        ),
      );
      gate.complete();
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(native.snapshotCalls, 3);
      expect(engine.externalActive, isTrue);
      expect(native.calls, isNot(contains('close:1')));
    },
  );

  test('late interruption is not dropped by newer snapshot', () async {
    native.snapshotSequence = 20;
    final frames = <PlaybackFrame>[];
    final framesSub = engine.frames.listen(frames.add);
    expect(await engine.prepareRoute(), isTrue);
    native.controller.add(
      const AirPlayNativeEvent(
        token: 1,
        kind: 'state',
        external: true,
        sequence: 10,
      ),
    );
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    native.controller.add(
      const AirPlayNativeEvent(
        token: 1,
        kind: 'state',
        external: true,
        sequence: 21,
        frame: PlaybackFrame(
          position: Duration(seconds: 25),
          duration: Duration(minutes: 2),
        ),
      ),
    );
    final interruptions = <PlaybackInterruption>[];
    final sub = engine.interruptions.listen(interruptions.add);
    native.controller.add(
      const AirPlayNativeEvent(
        token: 1,
        kind: 'interrupted',
        sequence: 19,
        frame: PlaybackFrame(position: Duration(seconds: 5)),
      ),
    );
    expect(interruptions, contains(PlaybackInterruption.audioFocusLost));
    expect(frames.last.position, const Duration(seconds: 25));
    await sub.cancel();
    await framesSub.cancel();
  });

  test('late older native event cannot override confirmed route', () async {
    native.snapshotSequence = 20;
    expect(await engine.prepareRoute(), isTrue);
    native.controller.add(
      const AirPlayNativeEvent(
        token: 1,
        kind: 'state',
        external: true,
        sequence: 10,
      ),
    );
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(engine.externalActive, isTrue);
    native.controller.add(
      const AirPlayNativeEvent(
        token: 1,
        kind: 'state',
        external: false,
        sequence: 19,
      ),
    );
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(engine.externalActive, isTrue);
    expect(native.calls, isNot(contains('close:1')));
  });

  test(
    'prepare failure with hung close returns locked until close confirms',
    () async {
      native.failPrepare = true;
      native.closeGate = Completer<void>();
      expect(await engine.prepareRoute(), isFalse);
      expect(engine.issue, contains('尚未确认'));
      expect(engine.mediaSelectionLocked, isTrue);
      await expectLater(engine.togglePause(), throwsStateError);
      native.closeGate!.complete();
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(engine.mediaSelectionLocked, isFalse);
      native.failPrepare = false;
      expect(await engine.prepareRoute(), isTrue);
      await engine.cancelRoute();
    },
  );

  test('invalid route-lost time keeps last trusted checkpoint', () async {
    expect(await engine.prepareRoute(), isTrue);
    native.controller.add(
      const AirPlayNativeEvent(token: 1, kind: 'state', external: true),
    );
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    native.controller.add(
      const AirPlayNativeEvent(
        token: 1,
        kind: 'state',
        external: true,
        frame: PlaybackFrame(
          position: Duration(seconds: 25),
          duration: Duration(minutes: 2),
        ),
      ),
    );
    native.controller.add(
      const AirPlayNativeEvent(
        token: 1,
        kind: 'routeLost',
        frame: PlaybackFrame(),
        positionValid: false,
        durationValid: false,
      ),
    );
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(local.seeks, contains(const Duration(seconds: 25)));
  });

  test('stale hung snapshot does not block a new attempt', () async {
    expect(await engine.prepareRoute(), isTrue);
    final gate = native.snapshotGate = Completer<void>();
    native.controller.add(
      const AirPlayNativeEvent(token: 1, kind: 'state', external: true),
    );
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    await engine.cancelRoute();
    native.snapshotGate = null;
    expect(await engine.prepareRoute(), isTrue);
    native.controller.add(
      const AirPlayNativeEvent(token: 3, kind: 'state', external: true),
    );
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(engine.externalActive, isTrue);
    gate.complete();
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(engine.externalActive, isTrue);
  });

  test('concurrent dispose shares in-flight cleanup', () async {
    final local = _HangingCancelEngine();
    final native = _Transport();
    final engine = AirPlayPlaybackEngine(local, transport: native);
    await engine.open(media, start: Duration.zero);
    final first = engine.dispose();
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    final second = engine.dispose();
    expect(identical(first, second), isTrue);
    local.gate.complete();
    await Future.wait([first, second]);
    expect(local.disposed, isTrue);
    await local.cleanUp();
  });

  test('hung stream cancellation does not delay native close', () async {
    final local = _HangingCancelEngine();
    final native = _Transport();
    final engine = AirPlayPlaybackEngine(local, transport: native);
    var releases = 0;
    final session = PlaybackSession(
      exclusivePlayback: true,
      createEngine: () => engine,
      resumeStore: MemoryResumeStore(),
      prepare: (source) async => PreparedPlayback(source, () async {
        releases++;
      }),
    );
    await session.open(media);
    local.controller.add(
      const PlaybackFrame(
        position: Duration(seconds: 10),
        duration: Duration(minutes: 2),
        playing: true,
      ),
    );
    expect(await engine.prepareRoute(), isTrue);
    native.controller.add(
      const AirPlayNativeEvent(token: 1, kind: 'state', external: true),
    );
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    final closing = session.close();
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(native.calls, contains('close:1'));
    await closing;
    expect(releases, 0);
    local.gate.complete();
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(releases, 1);
    session.dispose();
    await local.cleanUp();
  });

  test(
    'queued hung seek does not delay close and ownership is retained',
    () async {
      final local = FakeEngine();
      final native = _Transport();
      final engine = AirPlayPlaybackEngine(local, transport: native);
      var releases = 0;
      final session = PlaybackSession(
        exclusivePlayback: true,
        createEngine: () => engine,
        resumeStore: MemoryResumeStore(),
        prepare: (source) async => PreparedPlayback(source, () async {
          releases++;
        }),
      );
      await session.open(media);
      local.frameController.add(
        const PlaybackFrame(
          position: Duration(seconds: 10),
          duration: Duration(minutes: 2),
          playing: true,
        ),
      );
      expect(await engine.prepareRoute(), isTrue);
      native.controller.add(
        const AirPlayNativeEvent(token: 1, kind: 'state', external: true),
      );
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      native.seekGate = Completer<void>();
      final seeking = session.seek(const Duration(seconds: 30));
      await Future<void>.delayed(Duration.zero);
      final closing = session.close();
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(native.calls, contains('close:1'));
      await closing;
      expect(releases, 0);
      native.seekGate!.complete();
      await seeking;
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(releases, 1);
      session.dispose();
      await local.cleanUp();
    },
  );

  test(
    'late native event from an old engine cannot match a new candidate',
    () async {
      final oldLocal = FakeEngine();
      final oldNative = _Transport();
      final oldEngine = AirPlayPlaybackEngine(oldLocal, transport: oldNative);
      await oldEngine.open(media, start: Duration.zero);
      expect(await oldEngine.prepareRoute(), isTrue);
      final oldToken = oldNative.base! + 1;
      await oldEngine.cancelRoute();
      await oldEngine.dispose();
      final newLocal = FakeEngine();
      final newNative = _Transport();
      final newEngine = AirPlayPlaybackEngine(newLocal, transport: newNative);
      await newEngine.open(media, start: Duration.zero);
      expect(await newEngine.prepareRoute(), isTrue);
      expect(newNative.base! + 1, isNot(oldToken));
      newNative.controller.add(
        AirPlayNativeEvent(
          token: oldToken - newNative.base!,
          kind: 'state',
          external: true,
        ),
      );
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(newEngine.externalActive, isFalse);
      expect(newNative.calls, isNot(contains('play:1')));
      await newEngine.cancelRoute();
      await newEngine.dispose();
      await oldLocal.cleanUp();
      await newLocal.cleanUp();
    },
  );

  test(
    'hung checkpoint does not delay native close or release lease',
    () async {
      final local = FakeEngine();
      final native = _Transport();
      final engine = AirPlayPlaybackEngine(local, transport: native);
      final store = _HangingStore();
      var releases = 0;
      final session = PlaybackSession(
        exclusivePlayback: true,
        createEngine: () => engine,
        resumeStore: store,
        prepare: (source) async => PreparedPlayback(source, () async {
          releases++;
        }),
      );
      await session.open(media);
      local.frameController.add(
        const PlaybackFrame(
          position: Duration(seconds: 10),
          duration: Duration(minutes: 2),
          playing: true,
        ),
      );
      expect(await engine.prepareRoute(), isTrue);
      native.controller.add(
        const AirPlayNativeEvent(token: 1, kind: 'state', external: true),
      );
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(engine.externalActive, isTrue);
      final closing = session.close();
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(native.calls, contains('close:1'));
      expect(releases, 0);
      await closing;
      expect(releases, 0);
      store.gate.complete();
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(releases, 1);
      session.dispose();
      await local.cleanUp();
    },
  );

  test(
    'hung native close is bounded and locks playback until confirmed',
    () async {
      final local = FakeEngine();
      final native = _Transport();
      final engine = AirPlayPlaybackEngine(local, transport: native);
      await engine.open(media, start: Duration.zero);
      expect(await engine.prepareRoute(), isTrue);
      native.closeGate = Completer<void>();
      await engine.cancelRoute();
      expect(engine.mediaSelectionLocked, isTrue);
      expect(engine.issue, contains('尚未确认'));
      await expectLater(engine.togglePause(), throwsStateError);
      native.closeGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(engine.mediaSelectionLocked, isFalse);
      expect(native.calls.where((call) => call == 'close:1').length, 1);
      await engine.dispose();
      await local.cleanUp();
    },
  );

  test('disconnect close failure keeps checkpoint and can retry', () async {
    final local = FakeEngine();
    final native = _Transport();
    final engine = AirPlayPlaybackEngine(local, transport: native);
    final frames = <PlaybackFrame>[];
    final sub = engine.frames.listen(frames.add);
    await engine.open(media, start: Duration.zero);
    local.frameController.add(
      const PlaybackFrame(position: Duration(seconds: 10), playing: true),
    );
    expect(await engine.prepareRoute(), isTrue);
    native.controller.add(
      const AirPlayNativeEvent(token: 1, kind: 'state', external: true),
    );
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(engine.externalActive, isTrue);
    native.failClose = true;
    native.controller.add(
      const AirPlayNativeEvent(
        token: 1,
        kind: 'routeLost',
        frame: PlaybackFrame(position: Duration(seconds: 26)),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(frames.last.position, const Duration(seconds: 26));
    expect(frames.last.playing, isFalse);
    expect(engine.mediaSelectionLocked, isTrue);
    expect(engine.issue, contains('无法确认'));
    native.failClose = false;
    await engine.cancelRoute();
    expect(engine.externalActive, isFalse);
    expect(engine.mediaSelectionLocked, isFalse);
    expect(local.seeks, contains(const Duration(seconds: 26)));
    await sub.cancel();
    await engine.dispose();
    await local.cleanUp();
  });

  setUp(() async {
    local = FakeEngine();
    native = _Transport();
    engine = AirPlayPlaybackEngine(local, transport: native);
    await engine.open(media, start: Duration.zero);
    local.frameController.add(initial);
  });
  tearDown(() async {
    await engine.dispose();
    await local.cleanUp();
  });

  Future<void> flush() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test(
    'cancel preserves paused local and ignores late external events',
    () async {
      expect(await engine.prepareRoute(), isTrue);
      expect(local.pauses, 1);
      await engine.cancelRoute();
      native.controller.add(
        const AirPlayNativeEvent(token: 1, kind: 'state', external: true),
      );
      await flush();
      expect(engine.externalActive, isFalse);
      expect(native.calls, isNot(contains('play:1')));
      expect(local.toggles, 0);
    },
  );

  test(
    'external frame is sole authority and disconnect returns paused position',
    () async {
      final frames = <PlaybackFrame>[];
      final subscription = engine.frames.listen(frames.add);
      expect(await engine.prepareRoute(), isTrue);
      native.controller.add(
        const AirPlayNativeEvent(token: 1, kind: 'pickerOpened'),
      );
      native.controller.add(
        const AirPlayNativeEvent(token: 1, kind: 'state', external: true),
      );
      await flush();
      expect(engine.externalActive, isTrue);
      expect(
        native.calls,
        containsAllInOrder(['probe:1', 'seek:1:10', 'play:1']),
      );
      local.frameController.add(
        const PlaybackFrame(
          position: Duration(seconds: 11),
          duration: Duration(minutes: 2),
        ),
      );
      native.controller.add(
        const AirPlayNativeEvent(
          token: 1,
          kind: 'state',
          external: true,
          frame: PlaybackFrame(
            position: Duration(seconds: 25),
            duration: Duration(minutes: 2),
            playing: true,
          ),
        ),
      );
      expect(frames.last.position, const Duration(seconds: 25));
      native.controller.add(
        const AirPlayNativeEvent(
          token: 1,
          kind: 'routeLost',
          frame: PlaybackFrame(
            position: Duration(seconds: 26),
            duration: Duration(minutes: 2),
          ),
        ),
      );
      await flush();
      expect(engine.externalActive, isFalse);
      expect(local.seeks, contains(const Duration(seconds: 26)));
      expect(frames.last.position, const Duration(seconds: 26));
      expect(frames.last.playing, isFalse);
      expect(local.toggles, 0);
      await subscription.cancel();
    },
  );

  test(
    'failed seek never unmutes or resumes; interrupt cancels play intent',
    () async {
      native.failSeek = true;
      expect(await engine.prepareRoute(), isTrue);
      native.controller.add(
        const AirPlayNativeEvent(token: 1, kind: 'state', external: true),
      );
      await flush();
      expect(engine.externalActive, isFalse);
      expect(native.calls, isNot(contains('play:1')));
      await engine.cancelRoute();
      native.failSeek = false;
      expect(await engine.prepareRoute(), isTrue);
      await engine.pause();
      native.controller.add(
        const AirPlayNativeEvent(token: 4, kind: 'state', external: true),
      );
      await flush();
      expect(engine.externalActive, isFalse);
      expect(native.calls, isNot(contains('play:4')));
      expect(native.calls, contains('close:4'));
    },
  );

  test('stale prepare does not continue after cancellation', () async {
    native.prepareGate = Completer<void>();
    final preparing = engine.prepareRoute();
    await flush();
    await engine.cancelRoute();
    native.prepareGate!.complete();
    expect(await preparing, isFalse);
    expect(engine.phase, AirPlayPhase.idle);
  });

  test('session keeps lease and remote checkpoint authoritative through disconnect', () async {
    var releases = 0;
    final store = MemoryResumeStore();
    final history = <Duration>[];
    final session = PlaybackSession(
      exclusivePlayback: true,
      createEngine: () => engine,
      resumeStore: store,
      prepare: (source) async => PreparedPlayback(source, () async {
        releases++;
      }),
      onCheckpoint: (_, frame) async {
        history.add(frame.position);
      },
    );
    await session.open(media);
    local.frameController.add(initial);
    expect(await engine.prepareRoute(), isTrue);
    native.controller.add(
      const AirPlayNativeEvent(token: 1, kind: 'state', external: true),
    );
    await flush();
    native.controller.add(
      const AirPlayNativeEvent(
        token: 1,
        kind: 'state',
        external: true,
        frame: PlaybackFrame(
          position: Duration(seconds: 25),
          duration: Duration(minutes: 2),
          playing: true,
        ),
      ),
    );
    await session.checkpoint();
    expect(store.values[media.resumeKey], const Duration(seconds: 25));
    expect(releases, 0);
    native.controller.add(
      const AirPlayNativeEvent(
        token: 1,
        kind: 'routeLost',
        frame: PlaybackFrame(
          position: Duration(seconds: 26),
          duration: Duration(minutes: 2),
        ),
      ),
    );
    await flush();
    local.frameController.add(
      const PlaybackFrame(
        position: Duration(seconds: 10),
        duration: Duration(minutes: 2),
      ),
    );
    await session.checkpoint();
    expect(store.values[media.resumeKey], const Duration(seconds: 26));
    expect(history.last, const Duration(seconds: 26));
    expect(releases, 0);
    await session.close();
    expect(releases, 1);
    session.dispose();
  });

  test('casting blocks episode selection and auto-next', () async {
    final second = LocalMedia(uri: Uri.file('/second.mp4'), name: 'second.mp4');
    final session = PlaybackSession(
      exclusivePlayback: true,
      createEngine: () => engine,
      resumeStore: MemoryResumeStore(),
    );
    session.autoNext = true;
    await session.open(media, queue: [media, second]);
    local.frameController.add(initial);
    expect(await engine.prepareRoute(), isTrue);
    native.controller.add(
      const AirPlayNativeEvent(token: 1, kind: 'state', external: true),
    );
    await flush();
    expect(engine.externalActive, isTrue);
    expect(session.hasNext, isFalse);
    await session.open(second);
    expect(session.media?.resumeKey, media.resumeKey);
    expect(session.error, contains('结束视频投屏'));
    native.controller.add(
      const AirPlayNativeEvent(
        token: 1,
        kind: 'state',
        external: true,
        frame: PlaybackFrame(
          position: Duration(minutes: 2),
          duration: Duration(minutes: 2),
          completed: true,
        ),
      ),
    );
    await flush();
    expect(session.media?.resumeKey, media.resumeKey);
    await session.close();
    session.dispose();
  });

  test(
    'unconfirmed native close locks local and retries original token',
    () async {
      expect(await engine.prepareRoute(), isTrue);
      native.failClose = true;
      await engine.cancelRoute();
      expect(engine.issue, contains('无法确认'));
      expect(engine.mediaSelectionLocked, isTrue);
      await expectLater(engine.togglePause(), throwsStateError);
      expect(local.toggles, 0);
      native.failClose = false;
      await engine.cancelRoute();
      expect(engine.mediaSelectionLocked, isFalse);
      expect(native.calls.where((call) => call == 'close:1').length, 2);
    },
  );

  test(
    'hung route return retains scope until local seek actually finishes',
    () async {
      final hangingLocal = _HangingSeekEngine();
      final transport = _Transport();
      final routed = AirPlayPlaybackEngine(hangingLocal, transport: transport);
      var released = 0;
      var creations = 0;
      final session = PlaybackSession(
        exclusivePlayback: true,
        createEngine: () {
          creations++;
          return routed;
        },
        resumeStore: MemoryResumeStore(),
        prepare: (source) async => PreparedPlayback(source, () async {
          released++;
        }),
      );
      await session.open(media);
      hangingLocal.frameController.add(initial);
      expect(await routed.prepareRoute(), isTrue);
      transport.controller.add(
        const AirPlayNativeEvent(token: 1, kind: 'state', external: true),
      );
      await flush();
      expect(routed.externalActive, isTrue);
      transport.controller.add(
        const AirPlayNativeEvent(
          token: 1,
          kind: 'routeLost',
          frame: PlaybackFrame(position: Duration(seconds: 26)),
        ),
      );
      await flush();
      expect(hangingLocal.seeks, contains(const Duration(seconds: 26)));
      await session.close();
      expect(released, 0);
      await session.open(media);
      expect(creations, 1);
      hangingLocal.seekGate.complete();
      await flush();
      expect(hangingLocal.disposed, isTrue);
      expect(released, 1);
      session.dispose();
      await hangingLocal.cleanUp();
    },
  );

  test(
    'session sees route lock changes and one-tap retry after disconnect',
    () async {
      final second = LocalMedia(
        uri: Uri.file('/second.mp4'),
        name: 'second.mp4',
      );
      final session = PlaybackSession(
        exclusivePlayback: true,
        createEngine: () => engine,
        resumeStore: MemoryResumeStore(),
      );
      await session.open(media, queue: [media, second]);
      local.frameController.add(initial);
      final observed = <bool>[];
      session.addListener(() => observed.add(session.hasNext));
      expect(await engine.prepareRoute(), isTrue);
      expect(session.hasNext, isFalse);
      await engine.cancelRoute();
      expect(session.hasNext, isTrue);
      expect(observed, containsAllInOrder([false, true]));
      expect(await engine.prepareRoute(), isTrue);
      native.controller.add(
        const AirPlayNativeEvent(token: 3, kind: 'state', external: true),
      );
      await flush();
      native.controller.add(
        const AirPlayNativeEvent(
          token: 3,
          kind: 'routeLost',
          frame: PlaybackFrame(
            position: Duration(seconds: 26),
            duration: Duration(minutes: 2),
          ),
        ),
      );
      await flush();
      expect(session.error, contains('断开'));
      expect(session.hasNext, isTrue);
      expect(await engine.prepareRoute(), isTrue);
      expect(native.calls, contains('prepare:5:26'));
      expect(session.error, isNull);
      await engine.cancelRoute();
      await session.close();
      session.dispose();
    },
  );
}
