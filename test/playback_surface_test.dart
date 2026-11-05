import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/features/player/application/playback_session.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:orvex/features/player/presentation/playback_surface.dart';

import 'support/fakes.dart';

// UI command recording is deliberately synchronous; real session ordering and
// resource cleanup are exercised by playback_session_test and native tests.
class SurfaceSession extends PlaybackSession {
  SurfaceSession(this.player)
    : super(createEngine: () => player, resumeStore: MemoryResumeStore());
  final FakeEngine player;
  final seeks = <Duration>[];
  final rates = <double>[];
  @override
  PlaybackEngine get engine => player;
  @override
  bool get ready => true;
  @override
  Future<void> seek(Duration target) async {
    seeks.add(target);
  }

  @override
  Future<void> setRate(double rate) async {
    rates.add(rate);
  }
}

void main() {
  testWidgets('phone controls fit and gestures reach playback commands', (
    tester,
  ) async {
    final engine = FakeEngine();
    final session = SurfaceSession(engine);
    session.frame = const PlaybackFrame(
      position: Duration(seconds: 30),
      duration: Duration(minutes: 2),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              height: 180,
              child: PlaybackSurface(
                session: session,
                fullscreen: false,
                onFullscreen: () {},
                onSubtitle: () {},
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final origin = tester.getTopLeft(find.byType(PlaybackSurface));
    final point = origin + const Offset(305, 45);
    await tester.tapAt(point);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(point);
    await tester.pump();
    expect(session.seeks, [const Duration(seconds: 40)]);
    final press = await tester.startGesture(origin + const Offset(10, 45));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await press.up();
    await tester.pump();
    expect(session.rates, [2, 1]);
    await tester.tap(find.byTooltip('播放速度'));
    await tester.pumpAndSettle();
    expect(find.text('1.5 倍速'), findsOneWidget);
    await tester.tap(
      find.ancestor(
        of: find.text('1.5 倍速'),
        matching: find.byType(CheckedPopupMenuItem<double>),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tapAt(origin + const Offset(10, 45));
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.byTooltip('播放速度'),
      findsNothing,
      reason: 'paused subtitles can be viewed without controls',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
    await tester.pump();
  });
}
