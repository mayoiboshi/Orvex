import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:orvex/features/player/presentation/playback_surface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:orvex/app/orvex_app.dart';
import 'package:orvex/features/anime_metadata/application/anime_metadata_controller.dart';
import 'package:orvex/features/library/infrastructure/playback_history_store.dart';
import 'package:orvex/features/media_sources/imported_file_store.dart';
import 'package:orvex/features/player/application/playback_session.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:orvex/features/player/infrastructure/media_kit_engine.dart';
import 'package:orvex/features/player/infrastructure/preferences_resume_store.dart';

import '../test/support/fake_metadata.dart';

void main() {
  const silentSimulator = bool.fromEnvironment('ORVEX_SILENT_SIMULATOR_TEST');
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets(
    silentSimulator
        ? 'simulator visuals, imports and controls (audio NOT TESTED)'
        : 'native local playback, tracks, subtitles, resume and cleanup',
    (tester) async {
      if (Platform.isIOS) {
        final simulator = await const MethodChannel('dev.orvex/audio-session')
            .invokeMethod<bool>('isSimulator');
        expect(simulator, isTrue, reason: 'Generated media is simulator-only');
      }
      MediaKit.ensureInitialized();
      final directory = await Directory.systemTemp.createTemp(
        'orvex-playback-',
      );
      Future<File> fixture(String name, {String? outputName}) async {
        final data = await rootBundle.load('test/fixtures/$name');
        return File('${directory.path}/${outputName ?? name}')
            .writeAsBytes(data.buffer.asUint8List());
      }

      final video = await fixture(
        'generated.mp4',
        outputName: 'Orvex 样片 01.mp4',
      );
      final srt = await fixture('sample.srt', outputName: '中文字幕 01.srt');
      final ass = await fixture('sample.ass', outputName: '样式字幕 01.ass');
      final store = PreferencesResumeStore();
      final session = PlaybackSession(
        createEngine: () => MediaKitEngine(
          diagnostics: true,
          silentAudioForTesting: silentSimulator,
        ),
        resumeStore: store,
        onCheckpoint: PlaybackHistoryStore().record,
      );
      final screenKey = GlobalKey();
      final checks = <String>[
        if (silentSimulator)
          'NOT_TESTED: simulator audio; this build has no audio driver',
      ];

      Future<void> until(bool Function() condition, String label) async {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!condition() && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(condition(), isTrue, reason: '$label; error=${session.error}');
        expect(session.error, isNull, reason: label);
        checks.add(label);
      }

      Future<List<int>> capture(String name) async {
        final bytes = await (session.engine! as MediaKitEngine).captureFrame();
        expect(bytes, isNotNull);
        expect(bytes!.length, greaterThan(5000));
        await File('${directory.path}/$name.png').writeAsBytes(bytes);
        return bytes;
      }

      try {
        await tester.pumpWidget(
          RepaintBoundary(
            key: screenKey,
            child: ProviderScope(
              overrides: [
                sessionProvider.overrideWithValue(session),
                animeMetadataProvider.overrideWith((ref) {
                  final metadata = AnimeMetadataController(
                    client: FakeBangumiClient(),
                    store: MemoryMetadataStore(),
                  );
                  ref.onDispose(metadata.dispose);
                  return metadata;
                }),
              ],
              child: const OrvexApp(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final boundary =
            screenKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${directory.path}/orvex-window.png')
            .writeAsBytes(png!.buffer.asUint8List());
        image.dispose();

        final importer = ImportedFileStore();
        final importedVideo = await importer.import(XFile(video.path));
        final importedSrt = await importer.import(XFile(srt.path));
        final importedAss = await importer.import(XFile(ass.path));
        final importedAgain = await ImportedFileStore().listVideos();
        expect(
          importedAgain.any((media) => media.uri == importedVideo.uri),
          isTrue,
        );
        checks.add('video and subtitles imported to durable app documents');
        final source = LocalMedia(
          uri: importedVideo.uri,
          name: 'Orvex · native playback check',
        );
        await session.open(source);
        await until(
          () =>
              session.frame.position > const Duration(seconds: 1) &&
              session.frame.duration.inSeconds >= 17,
          'local MP4 playback advances',
        );
        final firstFrame = await capture('moving-frame-1');
        await tester.pump(const Duration(milliseconds: 700));
        final secondFrame = await capture('moving-frame-2');
        expect(
          listEquals(firstFrame, secondFrame),
          isFalse,
          reason: 'decoded frames must change',
        );
        checks.add('two distinct decoded video frames');

        await session.togglePause();
        await until(() => !session.frame.playing, 'pause is acknowledged');
        if (!Platform.isIOS && !Platform.isAndroid) {
          await tester.sendKeyEvent(LogicalKeyboardKey.space);
          await until(
            () => session.frame.playing,
            'desktop space starts playback',
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.space);
          await until(
            () => !session.frame.playing,
            'desktop space pauses playback',
          );
        }
        await tester.pump(const Duration(milliseconds: 400));
        final paused = session.frame.position;
        await tester.pump(const Duration(milliseconds: 700));
        expect(
          (session.frame.position - paused).abs().inMilliseconds,
          lessThan(200),
        );
        checks.add('position stays still while paused');

        for (final seconds in [8, 3, 6]) {
          await session.seek(Duration(seconds: seconds));
          await until(
            () =>
                (session.frame.position.inMilliseconds - seconds * 1000).abs() <
                700,
            'seek to $seconds seconds',
          );
        }
        await until(
          () => session.frame.audioTracks.length >= 2,
          'two audio tracks discovered',
        );
        final audio = session.frame.audioTracks.last.id;
        await session.selectAudio(audio);
        await until(
          () => session.frame.audioTrackId == audio,
          'second audio track selected',
        );

        await session.selectSubtitle('no');
        await tester.pump(const Duration(milliseconds: 400));
        final withoutSubtitles = await capture('without-subtitles');
        await session.loadSubtitle(
          LocalMedia(uri: importedSrt.uri, name: 'sample.srt'),
        );
        await until(
          () =>
              session.frame.subtitleTracks.isNotEmpty &&
              session.frame.subtitleTrackId != 'no' &&
              session.frame.subtitleTrackId != 'auto',
          'SRT track loaded',
        );
        await tester.pump(const Duration(milliseconds: 500));
        final withSrt = await capture('with-srt');
        expect(
          listEquals(withoutSubtitles, withSrt),
          isFalse,
          reason: 'SRT must alter the paused native frame',
        );
        checks.add('SRT pixels appear in decoded frame');

        await session.loadSubtitle(
          LocalMedia(uri: importedAss.uri, name: 'sample.ass'),
        );
        await until(
          () => session.frame.subtitleTracks.length >= 2,
          'ASS track loaded',
        );
        await tester.pump(const Duration(milliseconds: 500));
        final withAss = await capture('with-ass');
        expect(listEquals(withoutSubtitles, withAss), isFalse);
        expect(
          listEquals(withSrt, withAss),
          isFalse,
          reason: 'styled ASS should differ from SRT',
        );
        checks.add('ASS pixels appear in decoded frame');

        final trackCount = session.frame.subtitleTracks.length;
        final selectedSubtitle = session.frame.subtitleTrackId;
        await session.loadSubtitle(
          LocalMedia(uri: importedAss.uri, name: 'sample.ass'),
        );
        await tester.pump(const Duration(milliseconds: 200));
        expect(session.frame.subtitleTracks.length, trackCount);
        expect(session.frame.subtitleTrackId, selectedSubtitle);
        checks.add('reselecting the same subtitle does not duplicate tracks');

        await tester.tap(find.byTooltip('播放速度'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.ancestor(
            of: find.text('1.5 倍速'),
            matching: find.byType(CheckedPopupMenuItem<double>),
          ),
        );
        await until(() => session.frame.rate == 1.5, 'speed menu sets 1.5x');
        await session.setRate(1);

        await tester.tap(find.byTooltip('全屏播放'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('退出全屏'), findsWidgets);
        final fullscreenImage = await boundary.toImage(pixelRatio: 1);
        final fullscreenPng = await fullscreenImage.toByteData(
          format: ui.ImageByteFormat.png,
        );
        await File('${directory.path}/fullscreen-controls.png')
            .writeAsBytes(fullscreenPng!.buffer.asUint8List());
        fullscreenImage.dispose();
        checks.add('full-screen controls rendered');
        final surface = find.byType(PlaybackSurface);
        final rect = tester.getRect(surface);
        if (Platform.isIOS || Platform.isAndroid) {
          await session.togglePause();
          await until(
            () => session.frame.playing,
            'play before temporary speed',
          );
          final press = await tester.startGesture(
            Offset(rect.center.dx, rect.top + rect.height * 0.32),
          );
          await tester.pump(const Duration(milliseconds: 700));
          await until(() => session.frame.rate == 2, 'long press enters 2x');
          await press.up();
          await until(
            () => session.frame.rate == 1,
            'release restores normal speed',
          );
          await session.pauseForInterruption();
          await session.seek(const Duration(seconds: 6));
          await until(
            () =>
                !session.frame.playing &&
                (session.frame.position.inMilliseconds - 6000).abs() < 700,
            'pause and seek before resume checkpoint',
          );
        } else {
          final point = Offset(rect.left + 20, rect.top + rect.height * 0.4);
          await tester.tapAt(point);
          await tester.pump(const Duration(milliseconds: 100));
          await tester.tapAt(point);
          await until(
            () => find.byTooltip('全屏播放').evaluate().isNotEmpty,
            'desktop double click exits full screen',
          );
          await tester.tap(find.byTooltip('全屏播放'));
          await until(
            () => find.byTooltip('退出全屏').evaluate().isNotEmpty,
            'desktop full screen re-entry',
          );
        }
        await tester.tap(find.byTooltip('退出全屏').first);
        await tester.pumpAndSettle();
        expect(find.byTooltip('退出全屏'), findsNothing);
        expect(find.byTooltip('全屏播放'), findsOneWidget);
        checks.add('full-screen exit returns to the player');

        await session.checkpoint();
        final checkpoint = await store.read(source.resumeKey);
        expect(checkpoint.inSeconds, inInclusiveRange(5, 7));
        await session.close();
        expect(session.engine, isNull);
        await session.open(source);
        await until(
          () => session.frame.position.inSeconds >= 5 && session.frame.playing,
          'reopen restores persisted position and resumes',
        );
        await session.pauseForInterruption();
        await until(
          () => !session.frame.playing,
          'interruption explicitly pauses native playback',
        );
        await session.pauseForInterruption();
        await tester.pump(const Duration(milliseconds: 600));
        expect(
          session.frame.playing,
          isFalse,
          reason: 'repeated interruptions must not resume playback',
        );
        checks.add('repeated interruptions remain paused');
        await tester.tap(find.byTooltip('返回首页'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('tab-2')));
        await tester.pumpAndSettle();
        expect(find.text('最近播放'), findsOneWidget);
        expect(find.textContaining('未看完 · '), findsWidgets);
        checks.add('library shell shows persisted native playback history');
        for (final index in [0, 1, 2, 3]) {
          await tester.tap(find.byKey(ValueKey('tab-$index')));
          await tester.pumpAndSettle();
          final screenshot = await boundary.toImage(pixelRatio: 1);
          final data = await screenshot.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await File('${directory.path}/tab-$index.png')
              .writeAsBytes(data!.buffer.asUint8List());
          screenshot.dispose();
          expect(tester.takeException(), isNull);
        }
        checks.add('all four tabs render and remain navigable after playback');
        await session.close();
        checks.add('session closed and native player released');
        await File('${directory.path}/results.txt')
            .writeAsString(checks.join('\n'));
        // The path is intentionally printed so the host can retrieve real evidence.
        debugPrint('ORVEX_EVIDENCE=${directory.path}');
      } finally {
        await session.shutdown();
        await tester.pumpWidget(const SizedBox.shrink());
        session.dispose();
      }
    },
  );
}
