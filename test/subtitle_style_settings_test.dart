import 'dart:ui' as ui;

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

  testWidgets(
    'known ASS gates only style overrides and retains values across track changes',
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
      void select({String? codec, String id = '1'}) {
        engine.frameController.add(
          PlaybackFrame(
            subtitleTracks: [MediaTrack('1', '字幕', codec: codec)],
            subtitleTrackId: id,
          ),
        );
      }

      select(codec: 'ass');
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
      SwitchListTile setting(String text) => tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, text),
      );
      expect(session.currentSubtitleFormat, SubtitleTrackFormat.ass);
      expect(setting('粗体').onChanged, isNull);
      expect(setting('斜体').onChanged, isNull);
      expect(
        tester
            .widgetList<DropdownButton<String>>(
              find.byType(DropdownButton<String>),
            )
            .every((item) => item.onChanged == null),
        isTrue,
      );
      expect(
        tester
            .widgetList<Slider>(find.byType(Slider))
            .take(3)
            .every((slider) => slider.onChanged != null),
        isTrue,
      );
      expect(
        tester.widgetList<Slider>(find.byType(Slider)).last.onChanged,
        isNull,
      );
      expect(find.textContaining('开启覆盖 ASS 原有样式后'), findsOneWidget);
      final boldSemantics = tester.getSemantics(
        find.widgetWithText(SwitchListTile, '粗体'),
      );
      expect(boldSemantics.flagsCollection.isEnabled, ui.Tristate.isFalse);
      await tester.tap(find.text('覆盖 ASS 原有样式'));
      await tester.pump();
      expect(setting('粗体').onChanged, isNotNull);
      await tester.tap(find.text('粗体'));
      await tester.pump();
      expect(session.subtitleStyle.bold, isTrue);
      await tester.tap(find.text('覆盖 ASS 原有样式'));
      await tester.pump();
      expect(setting('粗体').onChanged, isNull);
      expect(setting('粗体').value, isTrue);
      select(codec: 'subrip');
      await tester.pump();
      expect(session.currentSubtitleFormat, SubtitleTrackFormat.text);
      expect(setting('粗体').onChanged, isNotNull);
      expect(setting('粗体').value, isTrue);
      select();
      await tester.pump();
      expect(session.currentSubtitleFormat, SubtitleTrackFormat.unknown);
      expect(setting('粗体').onChanged, isNotNull);
      expect(find.textContaining('当前字幕格式未知'), findsOneWidget);
      select(codec: 'ass', id: 'no');
      await tester.pump();
      expect(session.currentSubtitleFormat, SubtitleTrackFormat.unknown);
      expect(setting('粗体').onChanged, isNotNull);
      select(codec: 'hdmv_pgs_subtitle');
      await tester.pump();
      expect(session.currentSubtitleFormat, SubtitleTrackFormat.bitmap);
      expect(find.textContaining('当前为图片字幕'), findsOneWidget);
      expect(tester.takeException(), isNull);
      semantics.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
      await tester.pump();
    },
  );
}
