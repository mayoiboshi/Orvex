import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/features/player/application/playback_session.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:orvex/features/player/presentation/subtitle_style_settings.dart';

import 'support/fakes.dart';

void main() {
  testWidgets(
    'settings apply styling and reset without enabling ASS override by default',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final engine = FakeEngine();
      final session = PlaybackSession(
        createEngine: () => engine,
        resumeStore: MemoryResumeStore(),
      );
      await session.open(
        LocalMedia(uri: Uri.file('/video.mp4'), name: 'video.mp4'),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: session,
              builder: (context, _) => SingleChildScrollView(
                child: SubtitleStyleSettings(session: session),
              ),
            ),
          ),
        ),
      );
      final semantics = tester.ensureSemantics();
      expect(find.bySemanticsLabel('延迟'), findsOneWidget);
      final slider = find.byType(Slider).first;
      final gesture = await tester.startGesture(tester.getCenter(slider));
      await gesture.moveBy(const Offset(100, 0));
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();
      expect(engine.subtitleStyles.last.delay, isNot(0));
      expect(session.subtitleStyle.delay, 0);
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(session.subtitleStyle.delay, isNot(0));
      semantics.dispose();
      expect(session.subtitleStyle.overrideAss, false);
      await tester.tap(find.text('粗体'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(session.subtitleStyle.bold, true);
      expect(engine.subtitleStyles.last.bold, true);
      await tester.tap(find.text('覆盖 ASS 原有样式'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(session.subtitleStyle.overrideAss, true);
      await tester.tap(find.text('恢复默认'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(session.subtitleStyle.bold, false);
      expect(session.subtitleStyle.overrideAss, false);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
      await tester.pump();
    },
  );
}
