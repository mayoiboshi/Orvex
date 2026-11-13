import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/features/player/application/playback_session.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:orvex/features/player/infrastructure/airplay_playback_engine.dart';
import 'package:orvex/features/player/presentation/airplay_route_dialog.dart';

import 'support/fakes.dart';

class _Transport implements AirPlayTransport {
  @override
  Stream<AirPlayNativeEvent> get events => const Stream.empty();
  @override
  Future<void> prepare(LocalMedia media, Duration position, int token) async {}
  @override
  Future<void> probe(int token) async {}
  @override
  Future<void> seek(Duration position, int token) async {}
  @override
  Future<void> play(int token, {bool userInitiated = false}) async {}
  @override
  Future<void> pause(int token) async {}
  @override
  Future<void> close(int token) async {}
  @override
  Future<AirPlayNativeEvent> snapshot(int token) async =>
      AirPlayNativeEvent(token: token, kind: 'state');
  @override
  Future<void> dispose() async {}
}

class _RouteEngine extends AirPlayPlaybackEngine {
  _RouteEngine(super.local) : super(transport: _Transport());
  bool active = false;
  int prepares = 0;
  int cancels = 0;
  Completer<void>? gate;
  @override
  bool get externalActive => active;
  @override
  Future<bool> prepareRoute() async {
    prepares++;
    phaseNotifier.value = AirPlayPhase.preparing;
    if (gate != null) await gate!.future;
    phaseNotifier.value = AirPlayPhase.choosing;
    return true;
  }

  @override
  Future<void> cancelRoute() async {
    cancels++;
    active = false;
    phaseNotifier.value = AirPlayPhase.idle;
  }
}

void main() {
  late FakeEngine local;
  late _RouteEngine engine;
  late PlaybackSession session;
  setUp(() async {
    local = FakeEngine();
    engine = _RouteEngine(local);
    session = PlaybackSession(
      exclusivePlayback: true,
      createEngine: () => engine,
      resumeStore: MemoryResumeStore(),
      prepare: (source) async => PreparedPlayback(source),
    );
    await session.open(
      LocalMedia(uri: Uri.file('/sample.mp4'), name: 'sample.mp4'),
    );
    expect(session.ready, isTrue);
  });
  tearDown(() async {
    if (engine.gate case final gate? when !gate.isCompleted) gate.complete();
    await session.close().timeout(const Duration(seconds: 2));
    session.dispose();
    await local.cleanUp().timeout(const Duration(seconds: 2));
  });
  Widget host() => MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showAirPlayRouteDialog(context, session, engine),
          child: const Text('open'),
        ),
      ),
    ),
  );
  testWidgets('reopening active route preserves playback until explicit end', (
    tester,
  ) async {
    engine.active = true;
    engine.phaseNotifier.value = AirPlayPhase.active;
    await tester.pumpWidget(host());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('结束视频投屏'), findsOneWidget);
    expect(engine.prepares, 0);
    expect(engine.cancels, 0);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(engine.active, isTrue);
    expect(engine.cancels, 0);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('结束视频投屏'));
    await tester.pumpAndSettle();
    expect(engine.cancels, 1);
    expect(engine.active, isFalse);
  });
  testWidgets('repeat tap during route preparation does not cancel it', (
    tester,
  ) async {
    engine.gate = Completer<void>();
    await tester.pumpWidget(host());
    await tester.tap(find.text('open'));
    await tester.pump();
    expect(engine.prepares, 1);
    await tester.tap(find.text('open'));
    await tester.pump();
    expect(engine.prepares, 1);
    expect(engine.cancels, 0);
    await tester.pumpWidget(const SizedBox());
    engine.gate!.complete();
    await tester.pump();
    expect(engine.cancels, 1);
  });
}
