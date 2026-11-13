import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/features/player/application/playback_session.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';

import 'support/fakes.dart';

class HangingEngine extends FakeEngine
    implements PlaybackSafetyCriticalDisposal {
  final gate = Completer<void>();
  @override
  Future<void> dispose() async {
    await gate.future;
    await super.dispose();
  }
}

class HangingReservation implements PlaybackReservation {
  final acquireGate = Completer<void>();
  int releases = 0;
  @override
  Future<void> acquire() => acquireGate.future;
  @override
  Future<void> release() async {
    releases++;
  }
}

void main() {
  test(
    'timed out native claim blocks playback until late claim is released',
    () async {
      final reservation = HangingReservation();
      var creates = 0;
      var prepares = 0;
      final session = PlaybackSession(
        exclusivePlayback: true,
        playbackReservation: reservation,
        createEngine: () {
          creates++;
          return FakeEngine();
        },
        resumeStore: MemoryResumeStore(),
        prepare: (source) async {
          prepares++;
          return PreparedPlayback(source);
        },
      );
      final media = LocalMedia(uri: Uri.file('/one.mp4'), name: 'one.mp4');
      await session.open(media);
      expect(creates, 0);
      expect(prepares, 0);
      expect(session.error, contains('清理'));
      await session.open(media);
      expect(creates, 0);
      reservation.acquireGate.complete();
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(reservation.releases, 1);
      session.dispose();
    },
  );
  test('close then open keeps ownership across queued replacement', () async {
    final gate = Completer<void>();
    final firstEngine = FakeEngine();
    final nextEngine = FakeEngine();
    var creates = 0;
    var rivalCreates = 0;
    final session = PlaybackSession(
      exclusivePlayback: true,
      createEngine: () => creates++ == 0 ? firstEngine : nextEngine,
      resumeStore: MemoryResumeStore(),
      prepare: (source) async {
        if (source.name == 'next.mp4') await gate.future;
        return PreparedPlayback(source);
      },
    );
    final rival = PlaybackSession(
      exclusivePlayback: true,
      createEngine: () {
        rivalCreates++;
        return FakeEngine();
      },
      resumeStore: MemoryResumeStore(),
    );
    final first = LocalMedia(uri: Uri.file('/first.mp4'), name: 'first.mp4');
    final next = LocalMedia(uri: Uri.file('/next.mp4'), name: 'next.mp4');
    await session.open(first);
    final closing = session.close();
    final opening = session.open(next);
    await closing;
    await Future<void>.delayed(Duration.zero);
    await rival.open(first);
    expect(rivalCreates, 0);
    gate.complete();
    await opening;
    expect(creates, 2);
    await session.close();
    session.dispose();
    rival.dispose();
    await firstEngine.cleanUp();
    await nextEngine.cleanUp();
  });
  test(
    'provider rebuild during prepare cannot acquire playback resources',
    () async {
      final prepareGate = Completer<void>();
      final releaseGate = Completer<void>();
      var releases = 0;
      var newCreates = 0;
      final first = PlaybackSession(
        exclusivePlayback: true,
        createEngine: () => FakeEngine(),
        resumeStore: MemoryResumeStore(),
        prepare: (source) async {
          await prepareGate.future;
          return PreparedPlayback(source, () async {
            await releaseGate.future;
            releases++;
          });
        },
      );
      final nextEngine = FakeEngine();
      final second = PlaybackSession(
        exclusivePlayback: true,
        createEngine: () {
          newCreates++;
          return nextEngine;
        },
        resumeStore: MemoryResumeStore(),
      );
      final media = LocalMedia(uri: Uri.file('/race.mp4'), name: 'race.mp4');
      final opening = first.open(media);
      await Future<void>.delayed(Duration.zero);
      first.dispose();
      await second.open(media);
      expect(newCreates, 0);
      prepareGate.complete();
      await Future<void>.delayed(Duration.zero);
      await second.open(media);
      expect(newCreates, 0);
      await opening;
      expect(releases, 0);
      await second.open(media);
      expect(newCreates, 0);
      releaseGate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(releases, 1);
      await second.open(media);
      expect(newCreates, 1);
      await second.close();
      second.dispose();
      await nextEngine.cleanUp();
    },
  );
  test(
    'pending cleanup holds lease and blocks new engine until actual stop',
    () async {
      final engine = HangingEngine();
      var creates = 0;
      var releases = 0;
      final session = PlaybackSession(
        exclusivePlayback: true,
        createEngine: () {
          creates++;
          return engine;
        },
        resumeStore: MemoryResumeStore(),
        prepare: (source) async => PreparedPlayback(source, () async {
          releases++;
        }),
      );
      final media = LocalMedia(uri: Uri.file('/one.mp4'), name: 'one.mp4');
      await session.open(media);
      await session.close();
      expect(releases, 0);
      expect(session.error, contains('清理'));
      await session.open(media);
      expect(creates, 1);
      expect(releases, 0);
      final nextEngine = FakeEngine();
      var nextCreates = 0;
      final rebuiltSession = PlaybackSession(
        exclusivePlayback: true,
        createEngine: () {
          nextCreates++;
          return nextEngine;
        },
        resumeStore: MemoryResumeStore(),
      );
      await rebuiltSession.open(media);
      expect(nextCreates, 0);
      engine.gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(releases, 1);
      expect(engine.disposed, true);
      await rebuiltSession.open(media);
      expect(nextCreates, 1);
      await rebuiltSession.close();
      rebuiltSession.dispose();
      await nextEngine.cleanUp();
      session.dispose();
      await engine.cleanUp();
    },
  );

  test('failed native disposal keeps lease and blocks reentry', () async {
    final engine = HangingEngine();
    var releases = 0;
    var creates = 0;
    final session = PlaybackSession(
      exclusivePlayback: true,
      createEngine: () {
        creates++;
        return engine;
      },
      resumeStore: MemoryResumeStore(),
      prepare: (source) async => PreparedPlayback(source, () async {
        releases++;
      }),
    );
    final media = LocalMedia(uri: Uri.file('/two.mp4'), name: 'two.mp4');
    await session.open(media);
    final closing = session.close();
    await Future<void>.delayed(Duration.zero);
    engine.gate.completeError(StateError('native close failed'));
    await closing;
    expect(releases, 0);
    expect(session.error, contains('关闭'));
    await session.open(media);
    expect(creates, 1);
    expect(releases, 0);
    session.dispose();
    await engine.cleanUp();
  });
}
