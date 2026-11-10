import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:orvex/features/player/application/playback_session.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:orvex/features/player/domain/subtitle_style.dart';
import 'package:orvex/features/player/infrastructure/media_kit_engine.dart';

class _Resume implements ResumeStore {
  @override
  Future<Duration> read(String key) async => Duration.zero;
  @override
  Future<void> write(String key, Duration position) async {}
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('iOS simulator mpv subtitle background capability', (
    tester,
  ) async {
    expect(Platform.isIOS, isTrue);
    expect(
      await const MethodChannel('dev.orvex/audio-session')
          .invokeMethod<bool>('isSimulator'),
      isTrue,
      reason: 'Generated media may only be used on the iOS simulator',
    );
    MediaKit.ensureInitialized();
    final directory = await Directory.systemTemp.createTemp('orvex-sub-style-');
    final data = await rootBundle.load('test/fixtures/generated.mp4');
    final video = await File('${directory.path}/fixture.mp4').writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    final subtitle = await File('${directory.path}/fixture.srt').writeAsString(
      '1\n00:00:00,000 --> 00:00:18,000\nBACKGROUND EXPERIMENT\n',
    );
    final assData = await rootBundle.load('test/fixtures/sample.ass');
    final ass = await File('${directory.path}/fixture.ass').writeAsBytes(
      assData.buffer.asUint8List(assData.offsetInBytes, assData.lengthInBytes),
    );
    final player = Player(
      configuration: const PlayerConfiguration(libass: true),
    );
    final controller = VideoController(player);
    final native = player.platform as NativePlayer;
    Future<void> until(bool Function() ready) async {
      final deadline = DateTime.now().add(const Duration(seconds: 25));
      while (!ready() && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(ready(), isTrue);
    }

    Future<List<int>> capture() async {
      await tester.pump(const Duration(milliseconds: 500));
      final png = await player.screenshot(
        format: 'image/png',
        includeLibassSubtitles: true,
      );
      expect(png, isNotNull);
      final codec = await ui.instantiateImageCodec(png!);
      final image = (await codec.getNextFrame()).image;
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final result = bytes!.buffer.asUint8List().toList();
      image.dispose();
      codec.dispose();
      return result;
    }

    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: Video(controller: controller)),
        ),
      );
      await native.setProperty('ao', 'null');
      await native.setProperty('sub-auto', 'no');
      await player.open(Media(video.path));
      await until(() => player.state.duration.inSeconds > 10);
      final optionErrors = <String>[];
      final errors = player.stream.error.listen(optionErrors.add);
      await native.setProperty('sub-pos', '100.0');
      await tester.pump(const Duration(milliseconds: 500));
      debugPrint(
        'ORVEX_INVALID_POSITION_EVIDENCE errors=$optionErrors readback=${await native.getProperty('sub-pos')}',
      );
      expect(
        optionErrors.any((value) => value.contains('sub-pos')),
        isTrue,
        reason: 'A decimal integer option must surface the rejected write',
      );
      await native.setProperty('sub-pos', '80');
      expect(await native.getProperty('sub-pos'), '80');
      await native.setProperty('sub-pos', '100');
      await errors.cancel();
      await player.seek(const Duration(seconds: 4));
      await player.pause();
      await player.setSubtitleTrack(SubtitleTrack.uri(subtitle.uri.toString()));
      await until(
        () =>
            player.state.track.subtitle.id != 'no' &&
            player.state.track.subtitle.id != 'auto',
      );
      final baseline = await capture();
      await native.setProperty('sub-back-color', '#FF00FF00');
      await native.setProperty('sub-shadow-offset', '6');
      final backColor = await native.getProperty('sub-back-color');
      final offset = await native.getProperty('sub-shadow-offset');
      expect(backColor, isNotEmpty);
      expect(offset, isNotEmpty);
      final background = await capture();
      expect(background.length, baseline.length);
      var newGreenPixels = 0;
      for (var i = 0; i + 3 < baseline.length; i += 4) {
        final r = background[i], g = background[i + 1], b = background[i + 2];
        if (g > 180 &&
            g > r * 1.5 &&
            g > b * 1.5 &&
            (baseline[i + 1] - g).abs() > 50) {
          newGreenPixels++;
        }
      }
      expect(
        newGreenPixels,
        greaterThan(50),
        reason:
            'Background must change actual pixels, not only accept a property',
      );
      debugPrint(
        'ORVEX_BACKGROUND_EVIDENCE color=$backColor offset=$offset changedGreenPixels=$newGreenPixels',
      );
      for (final setting in <String, String>{
        'sub-delay': '-1.25',
        'sub-scale': '1.5',
        'sub-pos': '85',
        'sub-bold': 'yes',
        'sub-italic': 'yes',
        'sub-color': '#804080C0',
        'sub-border-color': '#FF102030',
        'sub-border-size': '4',
        'sub-ass-override': 'force',
      }.entries) {
        await native.setProperty(setting.key, setting.value);
        final actual = await native.getProperty(setting.key);
        expect(actual, isNotEmpty, reason: setting.key);
        debugPrint('ORVEX_PROPERTY_EVIDENCE ${setting.key}=$actual');
      }
      await native.setProperty('sub-back-color', '#00000000');
      await native.setProperty('sub-shadow-offset', '0');
      await native.setProperty('sub-delay', '0');
      await native.setProperty('sub-scale', '1');
      await native.setProperty('sub-pos', '100');
      await native.setProperty('sub-bold', 'no');
      await native.setProperty('sub-italic', 'no');
      await native.setProperty('sub-color', '#FFFFFFFF');
      await native.setProperty('sub-border-color', '#FF000000');
      await native.setProperty('sub-border-size', '3');
      await native.setProperty('sub-ass-override', 'yes');
      await player.setSubtitleTrack(SubtitleTrack.uri(ass.uri.toString()));
      await until(() => player.state.tracks.subtitle.length >= 2);
      final oldDefaultAss = await capture();
      await native.setProperty('sub-ass-override', 'no');
      final newDefaultAss = await capture();
      var differentPixels = 0;
      for (var i = 0; i + 3 < oldDefaultAss.length; i += 4) {
        if ((oldDefaultAss[i] - newDefaultAss[i]).abs() +
                (oldDefaultAss[i + 1] - newDefaultAss[i + 1]).abs() +
                (oldDefaultAss[i + 2] - newDefaultAss[i + 2]).abs() >
            40) {
          differentPixels++;
        }
      }
      debugPrint('ORVEX_ASS_DEFAULT_EVIDENCE oldYesVsNewNo=$differentPixels');
    } finally {
      await player.dispose();
      await directory.delete(recursive: true);
    }
  });

  testWidgets('real engine applies text styling while preserving ASS by default', (
    tester,
  ) async {
    expect(Platform.isIOS, isTrue);
    expect(
      await const MethodChannel('dev.orvex/audio-session')
          .invokeMethod<bool>('isSimulator'),
      isTrue,
      reason: 'Generated media may only be used on the iOS simulator',
    );
    MediaKit.ensureInitialized();
    final directory = await Directory.systemTemp.createTemp('orvex-style-api-');
    Future<File> fixture(String name) async {
      final data = await rootBundle.load('test/fixtures/$name');
      return File('${directory.path}/$name').writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    }

    final video = await fixture('generated.mp4');
    final srt = await fixture('sample.srt');
    final ass = await fixture('sample.ass');
    final session = PlaybackSession(
      createEngine: () => MediaKitEngine(silentAudioForTesting: true),
      resumeStore: _Resume(),
    );
    Future<void> until(bool Function() ready, String label) async {
      final deadline = DateTime.now().add(const Duration(seconds: 25));
      while (!ready() && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(ready(), isTrue, reason: '$label: ${session.error}');
    }

    Future<List<int>> capture() async {
      await tester.pump(const Duration(milliseconds: 500));
      final png = await (session.engine! as MediaKitEngine).captureFrame();
      expect(png, isNotNull);
      final codec = await ui.instantiateImageCodec(png!);
      final image = (await codec.getNextFrame()).image;
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final result = bytes!.buffer.asUint8List().toList();
      image.dispose();
      codec.dispose();
      return result;
    }

    int changed(List<int> before, List<int> after) {
      expect(after.length, before.length);
      var count = 0;
      for (var i = 0; i + 3 < before.length; i += 4) {
        if ((before[i] - after[i]).abs() +
                (before[i + 1] - after[i + 1]).abs() +
                (before[i + 2] - after[i + 2]).abs() >
            40) {
          count++;
        }
      }
      return count;
    }

    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: session,
              builder: (context, _) =>
                  session.engine?.buildVideo() ?? const SizedBox(),
            ),
          ),
        ),
      );
      final opening = session.open(
        LocalMedia(uri: video.uri, name: video.path),
      );
      await until(
        () => session.ready && session.frame.duration.inSeconds > 10,
        'open',
      );
      await opening;
      // mpv emits option parsing failures asynchronously through its error
      // stream even when reading the unchanged default value appears valid.
      await tester.pump(const Duration(milliseconds: 500));
      expect(session.error, isNull, reason: 'default subtitle settings');
      expect(session.subtitleStyleIssue, isEmpty);
      await session.seek(const Duration(seconds: 4));
      await session.pauseForInterruption();
      await until(() => !session.frame.playing, 'paused');
      await session.loadSubtitle(LocalMedia(uri: srt.uri, name: 'sample.srt'));
      await until(
        () =>
            session.frame.subtitleTrackId != 'no' &&
            session.frame.subtitleTrackId != 'auto',
        'SRT selected',
      );
      final srtDefault = await capture();
      await session.setSubtitleStyle(
        const SubtitleStyle(color: '#FF00FF00', scale: 1.5),
      );
      expect(session.subtitleStyleIssue, isEmpty);
      final srtStyled = await capture();
      final srtChanged = changed(srtDefault, srtStyled);
      expect(
        srtChanged,
        greaterThan(50),
        reason: 'SRT color and scale must change rendered pixels',
      );
      await session.setSubtitleStyle(const SubtitleStyle(position: 80));
      final srtMoved = await capture();
      expect(session.error, isNull, reason: 'non-default subtitle position');
      expect(session.subtitleStyleIssue, isEmpty);
      final srtPositionChanged = changed(srtDefault, srtMoved);
      expect(
        srtPositionChanged,
        greaterThan(50),
        reason: 'SRT position must move on screen',
      );
      await session.setSubtitleStyle(const SubtitleStyle(delay: 10));
      final srtDelayed = await capture();
      await session.selectSubtitle('no');
      final srtHidden = await capture();
      final delayedVsHidden = changed(srtDelayed, srtHidden);
      expect(
        delayedVsHidden,
        lessThan(20),
        reason: 'A ten-second delay must hide the cue at four seconds',
      );

      await session.setSubtitleStyle(const SubtitleStyle());
      expect(session.subtitleStyleIssue, isEmpty);
      await session.loadSubtitle(LocalMedia(uri: ass.uri, name: 'sample.ass'));
      await until(
        () => session.frame.subtitleTracks.length >= 2,
        'ASS selected',
      );
      final assDefault = await capture();
      await session.setSubtitleStyle(const SubtitleStyle(color: '#FF00FF00'));
      expect(session.subtitleStyleIssue, isEmpty);
      final assPreserved = await capture();
      final preservedChanged = changed(assDefault, assPreserved);
      expect(
        preservedChanged,
        lessThan(20),
        reason: 'ASS authored styles should remain intact without override',
      );
      await session.setSubtitleStyle(const SubtitleStyle(scale: 1.5));
      final assScaled = await capture();
      final scaleChanged = changed(assDefault, assScaled);
      expect(
        scaleChanged,
        greaterThan(50),
        reason: 'The fixture ASS must respond to scale in this native renderer',
      );
      await session.setSubtitleStyle(const SubtitleStyle(position: 80));
      final assMoved = await capture();
      final positionChanged = changed(assDefault, assMoved);
      debugPrint(
        'ORVEX_ASS_ADJUST_EVIDENCE scale=$scaleChanged position=$positionChanged',
      );
      await session.setSubtitleStyle(
        const SubtitleStyle(color: '#FF00FF00', overrideAss: true),
      );
      expect(session.subtitleStyleIssue, isEmpty);
      final assForced = await capture();
      final forcedChanged = changed(assDefault, assForced);
      expect(
        forcedChanged,
        greaterThan(50),
        reason: 'Explicit ASS override should alter rendered pixels',
      );
      debugPrint(
        'ORVEX_STYLE_EVIDENCE srtChanged=$srtChanged srtPositionChanged=$srtPositionChanged delayedVsHidden=$delayedVsHidden assPreservedChanged=$preservedChanged assForcedChanged=$forcedChanged',
      );
    } finally {
      session.dispose();
      await tester.pump(const Duration(milliseconds: 300));
      await directory.delete(recursive: true);
    }
  });
}
