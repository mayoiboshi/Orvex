import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:orvex/features/player/application/playback_session.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:orvex/features/player/infrastructure/media_kit_engine.dart';
import 'package:orvex/features/player/infrastructure/preferences_resume_store.dart';
import 'package:orvex/features/player/presentation/playback_surface.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('upper controls preserve native video and bilingual subtitles', (
    tester,
  ) async {
    expect(Platform.isIOS, isTrue);
    expect(
      await const MethodChannel('dev.orvex/audio-session')
          .invokeMethod<bool>('isSimulator'),
      isTrue,
    );
    MediaKit.ensureInitialized();
    final root = await Directory.systemTemp.createTemp('orvex-control-refine-');
    final data = await rootBundle.load('test/fixtures/generated.mp4');
    final video = await File('${root.path}/sample.mp4').writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    final srt = await File('${root.path}/bilingual.srt').writeAsString('''
1
00:00:00,000 --> 00:00:17,000
这是第一行字幕。
二行目の字幕です。
''');
    final ass = await File('${root.path}/positioned.ass').writeAsString(r'''
[Script Info]
ScriptType: v4.00+
PlayResX: 640
PlayResY: 360
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Main,Noto Sans CJK SC,25,&H00FFFFFF,&H000000FF,&H00723C18,&H80000000,-1,0,0,0,100,100,0,0,1,2,0,2,20,20,12,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:17.00,Main,,0,0,0,,{\an2\pos(320,352)}这是定位的第一行字幕。\N{\fs19}二行目の字幕です。
''');
    final engine = MediaKitEngine(silentAudioForTesting: true);
    final session = PlaybackSession(
      createEngine: () => engine,
      resumeStore: PreferencesResumeStore(),
    );
    final screen = GlobalKey();
    final narrow = ValueNotifier(false);
    final controls = find.byKey(const ValueKey('playback-controls'));
    final dock = find.byKey(const ValueKey('playback-upper-dock'));
    final videoArea = find.byKey(const ValueKey('video-gestures'));
    final progress = find.byKey(const ValueKey('playback-progress'));
    final media = LocalMedia(uri: video.uri, name: 'Orvex 字幕验证 · 第 1 集');

    Future<void> waitFor(bool Function() condition) async {
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (!condition() && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(condition(), isTrue, reason: '${session.error}');
    }

    Future<void> capture(String name) async {
      await tester.pump(const Duration(milliseconds: 260));
      expect(tester.takeException(), isNull);
      final boundary =
          screen.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await File('${root.path}/orvex-controls-$name.png').writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
      image.dispose();
    }

    Future<void> load(File file) async {
      await session.loadSubtitle(
        LocalMedia(uri: file.uri, name: file.uri.pathSegments.last),
      );
      await waitFor(
        () => !['no', 'auto'].contains(session.frame.subtitleTrackId),
      );
      await tester.pump(const Duration(milliseconds: 400));
    }

    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
    ]);
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: const Color(0xff000000),
            body: Center(
              child: ValueListenableBuilder(
                valueListenable: narrow,
                builder: (context, compact, _) => SizedBox(
                  width: compact ? 390 : double.infinity,
                  height: compact ? 680 : double.infinity,
                  child: RepaintBoundary(
                    key: screen,
                    child: PlaybackSurface(
                      session: session,
                      fullscreen: true,
                      title: media.name,
                      onFullscreen: () {},
                      onSubtitle: () {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      tester.view.physicalSize =
          const Size(1194, 834) * tester.view.devicePixelRatio;
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getSize(videoArea), const Size(1194, 834));
      await session.open(media);
      await waitFor(
        () => session.ready && session.frame.position.inSeconds >= 2,
      );
      await session.togglePause();
      await waitFor(() => !session.frame.playing && !session.frame.buffering);
      await session.selectSubtitle('no');
      await tester.pump(const Duration(milliseconds: 400));
      final withoutSubtitle = await engine.captureFrame();
      expect(withoutSubtitle, isNotNull);

      await load(srt);
      final withSrt = await engine.captureFrame();
      expect(withSrt, isNotNull);
      expect(listEquals(withoutSubtitle, withSrt), isFalse);
      await capture('srt-shown');

      await session.selectSubtitle('no');
      await load(ass);
      final withAss = await engine.captureFrame();
      expect(withAss, isNotNull);
      expect(listEquals(withSrt, withAss), isFalse);
      expect(listEquals(withoutSubtitle, withAss), isFalse);
      final track = session.frame.subtitleTrackId;
      final original = tester.getRect(videoArea);
      final audio = session.frame.audioTracks.last.id;
      await session.selectAudio(audio);
      await waitFor(() => session.frame.audioTrackId == audio);
      expect(tester.getRect(dock).bottom, lessThan(original.center.dy));
      await capture('ass-shown-paused');

      narrow.value = true;
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.getSize(videoArea).width, 390);
      await capture('narrow-paused');
      narrow.value = false;
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.getRect(videoArea), original);
      final shownFrame = await engine.captureFrame();
      expect(shownFrame, isNotNull);
      final blank = Offset(original.left + 32, original.bottom - 64);
      await tester.tapAt(blank);
      await tester.pump(const Duration(milliseconds: 450));
      expect(tester.widget<AnimatedOpacity>(controls).opacity, 0);
      expect(tester.getRect(videoArea), original);
      expect(listEquals(shownFrame, await engine.captureFrame()), isTrue);
      await capture('ass-hidden');

      await tester.tapAt(blank);
      await tester.pump(const Duration(milliseconds: 450));
      final bar = tester.getRect(progress);
      final gesture = await tester.startGesture(
        bar.centerLeft + Offset(bar.width * 0.26, 0),
      );
      await gesture.moveBy(Offset(bar.width * 0.2, 0));
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.byKey(const ValueKey('gesture-feedback')), findsOneWidget);
      await capture('ass-scrubbing');
      await gesture.up();
      await waitFor(() => session.frame.position.inSeconds >= 6);
      expect(session.frame.playing, isFalse);

      await tester.tap(find.byTooltip('播放'));
      await waitFor(() => session.frame.playing);
      await capture('ass-playing');
      await waitFor(
        () => tester.widget<AnimatedOpacity>(controls).opacity == 0,
      );
      await tester.tapAt(blank);
      await tester.pump(const Duration(milliseconds: 450));
      await tester.tap(find.byTooltip('暂停'));
      await waitFor(() => !session.frame.playing);
      expect(session.engine, same(engine));
      expect(session.frame.subtitleTrackId, track);
      expect(session.frame.audioTrackId, audio);
      expect(session.media?.uri, media.uri);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await session.close();
      session.dispose();
      narrow.dispose();
      tester.view.resetPhysicalSize();
      await SystemChrome.setPreferredOrientations([]);
    }
  });
}
