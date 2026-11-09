import 'dart:convert';
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

  testWidgets('edge controls preserve native video and bilingual subtitles', (
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
    final srt = await File('${root.path}/single-line.srt').writeAsString('''
1
00:00:00,000 --> 00:00:17,000
这是一行普通字幕。
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
Dialogue: 0,0:00:00.00,0:00:17.00,Main,,0,0,0,,{\an8\pos(320,48)\fs19}上方定位字幕。
''');
    final session = PlaybackSession(
      createEngine: () => MediaKitEngine(silentAudioForTesting: true),
      resumeStore: PreferencesResumeStore(),
    );
    final screen = GlobalKey();
    final layout = ValueNotifier((fullscreen: true, narrow: false));
    final controls = find.byKey(const ValueKey('playback-controls'));
    final dock = find.byKey(const ValueKey('playback-bottom-controls'));
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
                valueListenable: layout,
                builder: (context, mode, _) => SizedBox(
                  width: mode.narrow
                      ? 390
                      : mode.fullscreen
                      ? double.infinity
                      : 760,
                  height: mode.narrow
                      ? 680
                      : mode.fullscreen
                      ? double.infinity
                      : 428,
                  child: RepaintBoundary(
                    key: screen,
                    child: PlaybackSurface(
                      session: session,
                      fullscreen: mode.fullscreen,
                      title: media.name,
                      onFullscreen: () => layout.value = (
                        fullscreen: !mode.fullscreen,
                        narrow: false,
                      ),
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
      final engine = session.engine! as MediaKitEngine;
      final bounds = tester.getRect(videoArea);
      final left = Offset(bounds.left + 48, bounds.center.dy);
      final right = Offset(bounds.right - 80, bounds.center.dy);
      Future<void> doubleTap(Offset position) async {
        await tester.tapAt(position);
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tapAt(position);
      }

      await doubleTap(left);
      await waitFor(() => !session.frame.playing);
      await doubleTap(right);
      await waitFor(() => session.frame.playing);
      final hold = await tester.startGesture(right);
      await tester.pump(const Duration(milliseconds: 700));
      await waitFor(() => session.frame.rate == 2);
      await hold.up();
      await waitFor(() => session.frame.rate == 1);
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
      expect(tester.getRect(dock).top, greaterThan(original.center.dy));
      expect(tester.getRect(dock).bottom, original.bottom);
      await capture('ass-shown-paused');

      layout.value = (fullscreen: true, narrow: true);
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.getSize(videoArea).width, 390);
      await capture('narrow-paused');
      layout.value = (fullscreen: true, narrow: false);
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.getRect(videoArea), original);
      final shownFrame = await engine.captureFrame();
      expect(shownFrame, isNotNull);
      final blank = original.center;
      await tester.tapAt(blank);
      await tester.pump(const Duration(milliseconds: 450));
      expect(tester.widget<AnimatedOpacity>(controls).opacity, 0);
      expect(tester.getRect(videoArea), original);
      expect(listEquals(shownFrame, await engine.captureFrame()), isTrue);
      await capture('ass-hidden');
      expect(session.frame.playing, isFalse);

      await tester.tapAt(blank);
      await tester.pump(const Duration(milliseconds: 450));
      await tester.tap(find.byTooltip('退出全屏').first);
      await tester.pump(const Duration(milliseconds: 450));
      final embedded = tester.getRect(videoArea);
      expect(embedded.size, const Size(760, 428));
      expect(tester.getRect(dock).height, lessThan(70));
      expect(find.byTooltip('退出全屏'), findsNothing);
      await capture('inline-shown');
      await tester.tapAt(embedded.center);
      await tester.pump(const Duration(milliseconds: 450));
      expect(tester.widget<AnimatedOpacity>(controls).opacity, 0);
      await capture('inline-hidden');
      expect(tester.getRect(videoArea), embedded);
      expect(session.frame.playing, isFalse);
      expect(listEquals(shownFrame, await engine.captureFrame()), isTrue);
      await tester.tapAt(embedded.center);
      await tester.pump(const Duration(milliseconds: 450));
      await tester.tap(find.byTooltip('全屏播放'));
      await tester.pump(const Duration(milliseconds: 450));
      expect(tester.getRect(videoArea), original);

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
      for (final (label, width, height) in [
        ('4-by-3', 160, 120),
        ('wide', 240, 102),
      ]) {
        final fixture = await File('${root.path}/$label.mp4')
            .writeAsBytes(zlib.decode(base64Decode(_ratioFixtures[label]!)));
        await session.open(LocalMedia(uri: fixture.uri, name: label));
        await waitFor(
          () => session.ready && session.frame.position.inMilliseconds >= 500,
        );
        await session.togglePause();
        await waitFor(() => !session.frame.playing && !session.frame.buffering);
        final ratioEngine = session.engine! as MediaKitEngine;
        final png = (await ratioEngine.captureFrame())!;
        final header = ByteData.sublistView(png);
        expect(header.getUint32(16), width);
        expect(header.getUint32(20), height);
        final rect = tester.getRect(videoArea);
        expect(tester.widget<AnimatedOpacity>(controls).opacity, 1);
        await capture('ratio-$label');
        await tester.tapAt(rect.center);
        await tester.pump(const Duration(milliseconds: 450));
        expect(tester.widget<AnimatedOpacity>(controls).opacity, 0);
        expect(tester.getRect(videoArea), rect);
        expect(listEquals(png, await ratioEngine.captureFrame()), isTrue);
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await session.close();
      session.dispose();
      layout.dispose();
      tester.view.resetPhysicalSize();
      await SystemChrome.setPreferredOrientations([]);
    }
  });
}

// Simulator-only H.264 fixtures. Generate at each listed size with FFmpeg:
// -f lavfi -i 'color=0x1e1e1e:s=160x120:r=2:d=4'
// -vf 'drawbox=x=iw/2:y=0:w=iw/2:h=ih:color=0xdcdcdc:t=fill'
// -c:v libx264 -preset veryslow -tune stillimage -pix_fmt yuv420p -bf 0
// -bsf:v filter_units=remove_types=6 -map_metadata -1 sample.mp4
// Encode the resulting file as zlib-compressed base64. These files are never
// included in the shipping app's asset bundle.
const _ratioFixtures = {
  '4-by-3':
      'eNpjYGBQSCupLMgszs9lYGBiANFAbJRYlmyYW2BiyMDAwJFWlJoKpG/npiSWAGnz1I4m'
      'pp/n/32/sv3MplfJx7Zxr/i+aJ5azLNFX5+YrRee77rcavsKP0/Pa5c67tZtqFjMwMTH'
      '9ihtpiJQK6/jLNkO/Tn//91aFsHEBhQQdJyl/cFxsmaL+Ll6sCA7UFDIcZaljUCl0QyB'
      'eEuEUqCoZ41Anc8yRtbP8+FqhR1nRe4RqJ+s2QBXDBXO/CNQ/+RUAopqEcdZFf0s8v98'
      'ljGwiAJtvLY0ACTO7JObn18GlM/JLctIYUABzC8YGPgXMDAygBACMKKqQuc7MOAFTEBU'
      'XlKUmA1kx5Rkg+1kxjQNaC8Dfnuw2gvSVQHmqqSmlBQDaZnUnOIShA6ouWC9jO9zUzIT'
      'gQyF3BR0vzuA1YQeAXN0M1JyimAyZZkpqcgqw4D8fI/EvJScVJAaxlm5mXlpoAAvywUb'
      'iuxMlRSInExKUWoakjd4SotyFCBsxqjikqQcIPtQcUlxCpKaTaB0iSMoQB6vYPAA0h4w'
      'FSI+QPVmxnqGeoYGRgo5mUkVRmYmyDok/v8HkhZAVc6MKQw8/x8ySKUD6TU+SiLKnx4o'
      'gWKFCURwyGmEKDMysGe8cOYXVjT4++MHSLdAQWJxAdQlICySVFIEDWbGZTAbikvAUQBz'
      'MQcwpEFsEaDPkMVBWAYolowmxgGlTYByVUguB4lbg3IQEIsCsRgUi0OxBMSO5Hwk8wyA'
      'OLE0pQQU3ZG5qWAaBBSRoxaYHIoSCwpykINJJxOSflRWluTng6MuEawZHAXAME6DhTEA'
      'BjTJdA==',
  'wide':
      'eNpjYGBQSCupLMgszs9lYGBiANFAbJRYlmyYW2BiyMDAwJFWlJoKpB/mpiSWAGnb1I4m'
      'pp/n/32/sv3MplfJx7Zxr/i+aJ5avHNpHIP9tl07+acpRU4yruH4d6yt1L1/1re5b6JO'
      'FBUwMLxnaFxwcTHQAF7HWbId+nP+/7u1LIJRGCgg6DhL+4PjZM0W8XP1cEEhx1mWNgKV'
      'RjME4i3/I4t61gjU+SxjZP08Hy4q7Dgrco9A/WTNBhTFQOHMPwL1T04loKgWcZxV0c8i'
      '/89nGQOLKNDGa0sDQOLMPrn5+WVA+ZzcsowUBhTA/IKBgX8BAyMDCCEAI6oqdL4DA17A'
      'BETlJUWJ2UB2TEk22E5mTNOA9jLgtwervR+AOA3MVUlNKSkG0jKpOcUlCB1Qc8F6Gd/n'
      'pmQmAhkKuSnofncAqwk9AuboZqTkFMFkyjJTUpFVhgH5+R6JeSk5qSA1jLNyM/NAThAp'
      'ywUbiuxMlRSInExKUWoakjd4SotyFCBsxqjikqQcIPtQcUlxCpKaTaDUiSMoQB5PY/AA'
      '0h4wFSI+QPVmxnqGeoYGRgo5mUkVRmYmyDok/v8HkhZAVc6MKQw8/x8ySKUD6TU+SnL1'
      'Zxs6QLHCASIUKhYG9DAysGe8cOYXVjT4++MHSLdAQWJxAdQlICySVFIEDWbGTTAbikvA'
      'UQBzMdA4kCcZRIA+QxYHYRmgWDKaGAeUNgHKVSG5HCTuCMpBQCwKxGJQLA7FEhA7kvOR'
      'zDMA4sTSlBJQdEfmpoJpEFBEjlpgcihKLCjIQQ4mnUxI+lFZWZKfD466RLBmcBQAwzgN'
      'FsYAHdvOTw==',
};
