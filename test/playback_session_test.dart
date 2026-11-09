import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/features/player/application/playback_session.dart';
import 'package:orvex/features/player/domain/playback_defaults.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';

import 'support/fakes.dart';

void main() {
  final first = LocalMedia(
    uri: Uri.file('/videos/first.mp4'),
    name: 'first.mp4',
  );
  final second = LocalMedia(
    uri: Uri.file('/videos/second.mp4'),
    name: 'second.mp4',
  );
  late MemoryResumeStore store;
  late List<FakeEngine> engines;
  late PlaybackSession session;

  setUp(() {
    store = MemoryResumeStore();
    engines = [];
    session = PlaybackSession(
      createEngine: () {
        final engine = FakeEngine();
        engines.add(engine);
        return engine;
      },
      resumeStore: store,
    );
  });

  tearDown(() async {
    await session.shutdown();
    session.dispose();
    for (final engine in engines) {
      await engine.cleanUp();
    }
  });

  test(
    'selecting a queue item keeps its auto-next boundary and resume point',
    () async {
      final third = LocalMedia(
        uri: Uri.file('/videos/third.mp4'),
        name: 'third.mp4',
      );
      await store.write(second.resumeKey, const Duration(seconds: 18));
      session.autoNext = true;
      await session.open(
        first,
        queue: [first, second, third],
        canAutoAdvance: (_, _) => false,
      );
      await session.selectFromPlaylist(second);
      expect(session.playlist.map((item) => item.resumeKey), [
        first.resumeKey,
        second.resumeKey,
        third.resumeKey,
      ]);
      expect(engines.last.openedAt, const Duration(seconds: 18));
      engines.last.frameController.add(
        const PlaybackFrame(duration: Duration(minutes: 1), completed: true),
      );
      await Future<void>.delayed(Duration.zero);
      expect(session.media?.resumeKey, second.resumeKey);
      expect(engines.length, 2);
    },
  );

  test(
    'startup defaults are snapshotted and starting over still checkpoints',
    () async {
      await store.write(first.resumeKey, const Duration(seconds: 25));
      session.defaults = const PlaybackDefaults(
        rate: 1.25,
        fit: PlaybackFit.cover,
        skipSeconds: 30,
        touchGestures: false,
      );
      await session.open(first, startAt: Duration.zero);
      expect(engines.first.openedAt, Duration.zero);
      expect(engines.first.rates, [1.25]);
      expect(session.pictureFit, PlaybackFit.cover);
      expect(session.currentDefaults.skipSeconds, 30);
      expect(session.currentDefaults.touchGestures, isFalse);
      await session.setRate(2);
      session.setPictureFit(PlaybackFit.contain);
      engines.first.frameController.add(
        const PlaybackFrame(
          position: Duration(seconds: 13),
          duration: Duration(minutes: 1),
        ),
      );
      await session.checkpoint();
      expect(store.values[first.resumeKey], const Duration(seconds: 13));
      await session.open(first);
      expect(engines.last.openedAt, const Duration(seconds: 13));
      expect(engines.last.rates, [1.25]);
      expect(session.pictureFit, PlaybackFit.cover);
    },
  );

  test(
    'audio language selects actual tags once and preserves manual selection',
    () async {
      session.defaults = const PlaybackDefaults(
        audioLanguage: TrackLanguage.japanese,
      );
      const tracks = [
        MediaTrack('1', 'English', language: 'eng'),
        MediaTrack('2', 'Original', language: 'ja-JP'),
      ];
      await session.open(first);
      engines.first.frameController.add(
        const PlaybackFrame(audioTracks: tracks, audioTrackId: '1'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(engines.first.audioSelections, ['2']);
      await session.selectAudio('1');
      engines.first.frameController.add(
        const PlaybackFrame(audioTracks: tracks, audioTrackId: '1'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(engines.first.audioSelections, ['2', '1']);

      await session.open(second);
      engines.last.frameController.add(
        const PlaybackFrame(
          audioTracks: [MediaTrack('1', '日本語')],
          audioTrackId: '1',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(engines.last.audioSelections, isEmpty);
    },
  );

  test(
    'manual audio selected before track discovery is not overridden',
    () async {
      session.defaults = const PlaybackDefaults(
        audioLanguage: TrackLanguage.japanese,
      );
      await session.open(first);
      await session.selectAudio('no');
      engines.first.frameController.add(
        const PlaybackFrame(
          audioTracks: [MediaTrack('2', 'Original', language: 'jpn')],
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(engines.first.audioSelections, ['no']);
    },
  );

  test(
    'audio interruptions only pause and preserve the current checkpoint',
    () async {
      await session.open(first);
      final engine = engines.single;
      engine.frameController.add(
        const PlaybackFrame(
          playing: true,
          position: Duration(seconds: 22),
          duration: Duration(minutes: 2),
        ),
      );
      engine.interruptionController.add(PlaybackInterruption.audioFocusLost);
      engine.interruptionController.add(
        PlaybackInterruption.headphonesDisconnected,
      );
      await session.checkpoint();
      await session.pauseForInterruption();
      expect(engine.pauses, 3);
      expect(
        engine.toggles,
        0,
        reason: 'an already-paused player must not resume',
      );
      expect(store.values[first.resumeKey], const Duration(seconds: 22));
    },
  );

  test(
    'late interruption from old video cannot pause the replacement',
    () async {
      await session.open(first);
      final old = engines.single;
      await session.open(second);
      old.interruptionController.add(PlaybackInterruption.audioFocusLost);
      await Future<void>.delayed(Duration.zero);
      expect(engines.last.pauses, 0);
    },
  );

  test('interruption during loading pauses once opening completes', () async {
    final gate = Completer<void>();
    session.dispose();
    session = PlaybackSession(
      createEngine: () {
        final engine = FakeEngine()..openGate = gate;
        engines.add(engine);
        return engine;
      },
      resumeStore: store,
    );
    final opening = session.open(first);
    await Future<void>.delayed(Duration.zero);
    engines.single.interruptionController.add(
      PlaybackInterruption.audioFocusLost,
    );
    expect(engines.single.pauses, 0);
    gate.complete();
    await opening;
    await session.pauseForInterruption();
    expect(engines.single.pauses, 2);
    expect(engines.single.toggles, 0);
  });

  test(
    'switch saves previous video and rejects its late frames and errors',
    () async {
      await session.open(first);
      engines[0].frameController.add(
        const PlaybackFrame(
          position: Duration(seconds: 21),
          duration: Duration(minutes: 2),
          playing: true,
        ),
      );
      await session.open(second);
      engines[0].frameController.add(
        const PlaybackFrame(position: Duration(seconds: 80)),
      );
      engines[0].errorController.add('old error');
      expect(store.values[first.resumeKey], const Duration(seconds: 21));
      expect(engines[0].disposed, isTrue);
      expect(session.media, second);
      expect(session.frame.position, Duration.zero);
      expect(session.error, isNull);
    },
  );

  test(
    'reopening restores checkpoint; completed video restarts at zero',
    () async {
      store.values[first.resumeKey] = const Duration(seconds: 42);
      await session.open(first);
      expect(engines.single.openedAt, const Duration(seconds: 42));
      engines.single.frameController.add(
        const PlaybackFrame(
          position: Duration(minutes: 2),
          duration: Duration(minutes: 2),
          completed: true,
        ),
      );
      await session.close();
      await session.open(first);
      expect(engines.last.openedAt, Duration.zero);
    },
  );

  test(
    'rapid switching serializes native opens without reviving stale media',
    () async {
      final gate = Completer<void>();
      session.dispose();
      session = PlaybackSession(
        createEngine: () {
          final engine = FakeEngine();
          if (engines.isEmpty) engine.openGate = gate;
          engines.add(engine);
          return engine;
        },
        resumeStore: store,
      );
      final opening = session.open(first);
      await Future<void>.delayed(Duration.zero);
      final next = session.open(second);
      final latest = session.open(first);
      expect(engines.length, 1);
      expect(engines.first.disposed, isFalse);
      gate.complete();
      await Future.wait([opening, next, latest]);
      expect(session.media, first);
      expect(engines.length, 2);
      expect(engines.first.disposed, isTrue);
    },
  );

  test(
    'closing during an asynchronous open cannot resurrect the session',
    () async {
      final gate = Completer<void>();
      session.dispose();
      session = PlaybackSession(
        createEngine: () {
          final engine = FakeEngine()..openGate = gate;
          engines.add(engine);
          return engine;
        },
        resumeStore: store,
      );
      final opening = session.open(first);
      await Future<void>.delayed(Duration.zero);
      final closing = session.close();
      gate.complete();
      await Future.wait([opening, closing]);
      expect(session.media, isNull);
      expect(session.engine, isNull);
      expect(engines.single.disposed, isTrue);
      expect(session.loading, isFalse);
    },
  );

  test(
    'seeks clamp to video bounds and pause remains available while buffering',
    () async {
      await session.open(first);
      engines.single.frameController.add(
        const PlaybackFrame(duration: Duration(seconds: 60), buffering: true),
      );
      await session.seek(const Duration(seconds: -10));
      await session.seek(const Duration(seconds: 90));
      await session.togglePause();
      expect(engines.single.seeks, [
        Duration.zero,
        const Duration(seconds: 60),
      ]);
      expect(engines.single.toggles, 1);
      expect(session.frame.playing, isFalse);
    },
  );

  test(
    'subtitle failure reports error without inventing a selected track',
    () async {
      await session.open(first);
      engines.single.failSubtitle = true;
      await session.loadSubtitle(
        LocalMedia(uri: Uri.file('/missing.ass'), name: 'missing.ass'),
      );
      expect(session.error, contains('unreadable subtitle'));
      expect(session.frame.subtitleTrackId, 'auto');
      expect(session.frame.subtitleTracks, isEmpty);
    },
  );

  test('storage read failure falls back to playback, write failure remains visible', () async {
    store.failRead = true;
    await session.open(first);
    expect(engines.single.openedAt, Duration.zero);
    expect(session.error, contains('无法读取'));
    store.failWrite = true;
    engines.single.frameController.add(
      const PlaybackFrame(
        position: Duration(seconds: 10),
        duration: Duration(minutes: 2),
      ),
    );
    await session.checkpoint();
    expect(session.error, contains('保存失败'));
    expect(session.ready, isTrue);
  });

  test(
    'failure while releasing old media clears loading and permits retry',
    () async {
      await session.open(first);
      engines.single.failDispose = true;
      await session.open(second);
      expect(session.loading, isFalse);
      expect(session.error, contains('release failed'));
      expect(session.engine, isNull);
      await session.open(second);
      expect(session.ready, isTrue);
      expect(session.error, isNull);
    },
  );

  test(
    'initial zero-duration events never erase a stored resume position',
    () async {
      store.values[first.resumeKey] = const Duration(seconds: 42);
      await session.open(first);
      engines.single.frameController.add(const PlaybackFrame());
      await session.close();
      expect(store.values[first.resumeKey], const Duration(seconds: 42));
    },
  );
}
