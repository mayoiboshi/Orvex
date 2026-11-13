import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/features/player/application/playback_session.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:orvex/features/player/infrastructure/airplay_playback_engine.dart';
import 'package:orvex/features/player/infrastructure/dlna/dlna_playback_engine.dart';
import 'package:orvex/features/player/presentation/airplay_route_dialog.dart';
import 'package:orvex/features/player/presentation/playback_surface.dart';

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
  Completer<void>? cancelGate;
  bool cancelFails = false;
  bool disposed = false;
  @override
  bool get externalActive => active;
  @override
  Future<bool> prepareRoute() async {
    prepares++;
    phaseNotifier.value = AirPlayPhase.preparing;
    if (gate != null) await gate!.future;
    if (!disposed) phaseNotifier.value = AirPlayPhase.choosing;
    return true;
  }

  @override
  Future<void> cancelRoute() async {
    cancels++;
    if (cancelGate != null) await cancelGate!.future;
    active = false;
    if (!disposed) {
      phaseNotifier.value = cancelFails
          ? AirPlayPhase.failed
          : AirPlayPhase.idle;
    }
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await super.dispose();
  }
}

void main() {
  group('route dialog', () {
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
      if (engine.cancelGate case final gate? when !gate.isCompleted) {
        gate.complete();
      }
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
    testWidgets(
      'reopening active route preserves playback until explicit end',
      (tester) async {
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
      },
    );
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
    testWidgets('late cancel after session close cannot pop the page', (
      tester,
    ) async {
      engine.active = true;
      engine.phaseNotifier.value = AirPlayPhase.active;
      engine.cancelGate = Completer<void>();
      await tester.pumpWidget(host());
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('结束视频投屏'));
      await tester.pump();
      expect(engine.cancels, 1);
      expect(
        tester
            .widget<TextButton>(
              find.ancestor(
                of: find.text('完成'),
                matching: find.byType(TextButton),
              ),
            )
            .onPressed,
        isNull,
      );

      late Future<void> closing;
      await tester.runAsync(() async {
        closing = session.close();
      });
      await tester.pump();
      engine.cancelGate!.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('open'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() => closing.timeout(const Duration(seconds: 2)));
    });
    testWidgets('cancel failure is not retried when the dialog closes', (
      tester,
    ) async {
      engine.cancelFails = true;
      await tester.pumpWidget(host());
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(engine.cancels, 1);
      expect(engine.phaseNotifier.value, AirPlayPhase.failed);
      expect(find.text('open'), findsOneWidget);
    });
    testWidgets('late cancel removes only its own covered dialog', (
      tester,
    ) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      engine.active = true;
      engine.phaseNotifier.value = AirPlayPhase.active;
      engine.cancelGate = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showAirPlayRouteDialog(context, session, engine),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('结束视频投屏'));
      await tester.pump();
      navigatorKey.currentState!.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('other route')),
        ),
      );
      await tester.pumpAndSettle();
      engine.cancelGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('other route'), findsOneWidget);
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('open'), findsOneWidget);
      expect(find.text('结束视频投屏'), findsNothing);
      expect(engine.cancels, 1);
    });
    testWidgets('late prepare after session close cannot show stale dialog', (
      tester,
    ) async {
      engine.gate = Completer<void>();
      await tester.pumpWidget(host());
      await tester.tap(find.text('open'));
      await tester.pump();
      late Future<void> closing;
      await tester.runAsync(() async {
        closing = session.close();
      });
      await tester.pump();
      engine.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('AirPlay 视频投屏'), findsNothing);
      expect(find.text('open'), findsOneWidget);
      expect(engine.cancels, 0);
      await tester.runAsync(() => closing.timeout(const Duration(seconds: 2)));
    });
  });
  for (final wrapped in [false, true]) {
    group('surface DLNA: $wrapped', () {
      late _RouteEngine player;
      late PlaybackSession playback;
      setUp(() async {
        player = _RouteEngine(FakeEngine());
        final PlaybackEngine outer = wrapped
            ? DlnaPlaybackEngine(player, NativePlaybackReservation())
            : player;
        playback = PlaybackSession(
          exclusivePlayback: true,
          createEngine: () => outer,
          resumeStore: MemoryResumeStore(),
          prepare: (source) async => PreparedPlayback(source),
        );
        await playback.open(
          LocalMedia(uri: Uri.file('/sample.mp4'), name: 'sample.mp4'),
        );
        expect(playback.ready, isTrue);
      });
      tearDown(() async {
        await playback.close().timeout(const Duration(seconds: 2));
        playback.dispose();
        await player.local.dispose().timeout(const Duration(seconds: 2));
      });
      testWidgets(
        'player AirPlay button opens active controls (DLNA: $wrapped)',
        (tester) async {
          player.active = true;
          player.phaseNotifier.value = AirPlayPhase.active;
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: PlaybackSurface(
                  session: playback,
                  fullscreen: false,
                  onFullscreen: () {},
                  onSubtitle: () {},
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.tap(find.byTooltip('AirPlay 视频投屏'));
          await tester.pumpAndSettle();
          expect(find.text('结束视频投屏'), findsOneWidget);
          expect(player.cancels, 0);
          await tester.tap(find.text('完成'));
          await tester.pumpAndSettle();
          expect(player.active, isTrue);
          expect(player.cancels, 0);
          await tester.tap(find.byTooltip('AirPlay 视频投屏'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('结束视频投屏'));
          await tester.pumpAndSettle();
          expect(player.cancels, 1);
          expect(player.active, isFalse);

          // A route lost while the panel is open is shown as a failure, and
          // dismissing the panel must not leave a stale active view behind.
          player.active = true;
          player.phaseNotifier.value = AirPlayPhase.active;
          await tester.pump();
          await tester.tap(find.byTooltip('AirPlay 视频投屏'));
          await tester.pumpAndSettle();
          player.active = false;
          player.phaseNotifier.value = AirPlayPhase.failed;
          await tester.pump();
          expect(find.text('连接失败，播放已暂停。'), findsOneWidget);
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          expect(player.cancels, 2);

          // Destroying a route's UI does not implicitly stop an active route.
          player.active = true;
          player.phaseNotifier.value = AirPlayPhase.active;
          await tester.pump();
          await tester.tap(find.byTooltip('AirPlay 视频投屏'));
          await tester.pumpAndSettle();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          expect(player.cancels, 2);
        },
      );
    });
  }
}
