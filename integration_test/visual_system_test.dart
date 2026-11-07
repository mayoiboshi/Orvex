import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:orvex/app/orvex_app.dart';
import 'package:orvex/design/appearance_controller.dart';
import 'package:orvex/features/anime_metadata/application/anime_metadata_controller.dart';
import 'package:orvex/features/anime_metadata/infrastructure/bangumi_client.dart';
import 'package:orvex/features/anime_metadata/infrastructure/metadata_store.dart';
import 'package:orvex/features/library/infrastructure/playback_history_store.dart';
import 'package:orvex/features/media_sources/imported_file_store.dart';
import 'package:orvex/features/media_sources/local_file_source.dart';
import 'package:orvex/features/player/application/playback_session.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:orvex/features/player/infrastructure/media_kit_engine.dart';
import 'package:orvex/features/player/infrastructure/preferences_resume_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  const network = bool.fromEnvironment(
    'ORVEX_VISUAL_NETWORK',
    defaultValue: true,
  );
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    network
        ? 'live light/dark UI, real posters, and theme changes during native playback'
        : 'offline light/dark UI and themes during native playback (network NOT TESTED)',
    (tester) async {
      if (Platform.isIOS) {
        expect(
          await const MethodChannel('dev.orvex/audio-session')
              .invokeMethod<bool>('isSimulator'),
          isTrue,
          reason: 'Generated visual fixtures must never be imported on a physical phone',
        );
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
        ]);
      }
      MediaKit.ensureInitialized();
      final root = await Directory.systemTemp.createTemp('orvex-visual-');
      // Retain the actual host preference backend for the appearance persistence
      // check; library/history fixtures use memory and a temporary media directory.
      final nativePlatform = SharedPreferencesAsyncPlatform.instance;
      final nativePreferences = SharedPreferencesAsync();
      final appearance = AppearanceController(preferences: nativePreferences);
      await appearance.initialize();
      final originalMode = appearance.mode;
      final originalTransparency = appearance.reduceTransparency;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      final imports = ImportedFileStore(
        directoryProvider: () async => Directory('${root.path}/documents'),
      );
      final data = await rootBundle.load('test/fixtures/generated.mp4');
      final videos = <LocalMedia>[];
      for (final filename in [
        '[ANi] 葬送的芙莉莲 - 01 [1080p].mp4',
        '[ANi] 葬送的芙莉莲 - 02 [1080p].mp4',
        '名侦探柯南 - 0615.mp4',
      ]) {
        // Existing pre-dedup imports may contain independent copies of one
        // video. Keep that migration fixture explicit; new imports now dedupe.
        final relative = 'Imports/legacy-visual-${videos.length}/$filename';
        final file = File('${root.path}/documents/$relative');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data.buffer.asUint8List());
        videos.add(
          LocalMedia(uri: file.uri, name: filename, importPath: relative),
        );
      }
      final http = HttpClient();
      const proxy = String.fromEnvironment('ORVEX_BANGUMI_TEST_PROXY');
      if (proxy.isNotEmpty) http.findProxy = (_) => 'PROXY $proxy';
      final metadata = AnimeMetadataController(
        client: BangumiClient(httpClient: http),
        store: MetadataStore(
          directoryProvider: () async => Directory('${root.path}/cache'),
        ),
      );
      if (!network) {
        await metadata.initialize();
        await metadata.setAutomatic(false);
      }
      final history = PlaybackHistoryStore();
      final session = PlaybackSession(
        createEngine: () =>
            MediaKitEngine(silentAudioForTesting: Platform.isIOS),
        resumeStore: PreferencesResumeStore(),
        onCheckpoint: history.record,
      );
      final screen = GlobalKey();
      final checks = <String>[
        network
            ? 'Generated videos; actual Bangumi API metadata and posters; no user media'
            : 'Generated videos; offline UI; Bangumi network NOT TESTED',
        if (Platform.isIOS)
          'NOT TESTED: simulator audio and physical brightness',
      ];

      Future<void> until(bool Function() ready, String label) async {
        final end = DateTime.now().add(const Duration(seconds: 50));
        while (!ready() && DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          ready(),
          isTrue,
          reason:
              '$label; session=${session.error}; metadata=${metadata.error}',
        );
        checks.add(label);
      }

      final timings = <ui.FrameTiming>[];
      void recordTiming(List<ui.FrameTiming> frames) => timings.addAll(frames);
      WidgetsBinding.instance.addTimingsCallback(recordTiming);
      Future<void> capture(String name) async {
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);
        final boundary =
            screen.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${root.path}/$name.png')
            .writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
      }

      Future<void> visit(int tab) async {
        await tester.tap(find.byKey(ValueKey('tab-$tab')));
        await tester.pumpAndSettle();
      }

      try {
        await tester.pumpWidget(
          RepaintBoundary(
            key: screen,
            child: ProviderScope(
              overrides: [
                appearanceProvider.overrideWithValue(appearance),
                sessionProvider.overrideWithValue(session),
                localFilesProvider.overrideWithValue(
                  LocalFileSource(imports: imports),
                ),
                animeMetadataProvider.overrideWithValue(metadata),
                historyStoreProvider.overrideWithValue(history),
              ],
              child: const OrvexApp(),
            ),
          ),
        );
        if (network) {
          await until(
            () => videos.every(
              (media) =>
                  metadata.subjectFor(media) != null &&
                  metadata.posterPath(metadata.subjectFor(media)!.id) != null,
            ),
            'three generated files have actual Bangumi metadata and cached covers',
          );
        } else {
          await tester.pumpAndSettle();
          checks.add('offline UI uses actual local files and fallback covers');
        }
        // Produce continue-watching records from real native playback/checkpoints.
        for (final media in [videos.last, videos.first]) {
          await session.open(media);
          await until(
            () => session.frame.duration.inSeconds >= 17,
            'native generated video opens',
          );
          await session.seek(const Duration(seconds: 6));
          await session.pauseForInterruption();
          await until(
            () =>
                !session.frame.playing && session.frame.position.inSeconds >= 5,
            'native paused checkpoint available',
          );
          await session.checkpoint();
        }
        await tester.tap(find.byTooltip('返回首页'));
        await tester.pumpAndSettle();
        for (final mode in [ThemeMode.light, ThemeMode.dark]) {
          await appearance.setMode(mode);
          expect(
            await nativePreferences.getString(AppearanceController.themeKey),
            mode.name,
          );
          await visit(0);
          await capture('home-${mode.name}');
          await visit(1);
          await capture('library-${mode.name}');
          await tester.tap(find.byTooltip('番剧资料').first);
          await tester.pumpAndSettle();
          await capture('details-${mode.name}');
          await tester.tap(find.byTooltip('关闭番剧资料'));
          await tester.pumpAndSettle();
          await visit(2);
          await capture('history-${mode.name}');
          await visit(3);
          await capture('settings-${mode.name}');
          checks.add(
            '${mode.name}: home, library, details, history and settings render without overflow; preference saved on host',
          );
        }
        await visit(0);
        await tester.tap(find.text('继续播放'));
        await until(
          () => session.frame.playing,
          'continue-watching resumes native playback',
        );
        final engine = session.engine;
        await appearance.setMode(ThemeMode.light);
        await tester.pump(const Duration(milliseconds: 300));
        await appearance.setMode(ThemeMode.dark);
        await tester.pump(const Duration(milliseconds: 300));
        expect(identical(session.engine, engine), isTrue);
        expect(session.frame.playing, isTrue);
        checks.add('theme switches preserve the same playing native engine');
        await session.pauseForInterruption();
        await tester.pumpAndSettle();
        await capture('player-inline');
        await tester.tap(find.byTooltip('全屏播放'));
        await tester.pumpAndSettle();
        await capture('player-fullscreen');
        await tester.tap(find.byTooltip('播放设置'));
        await tester.pumpAndSettle();
        await capture('player-settings');
        Navigator.of(
          tester.element(find.byKey(const ValueKey('settings-volume'))),
        ).pop();
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('退出全屏').first);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('返回首页'));
        await tester.pumpAndSettle();
        await visit(3);
        await tester.ensureVisible(
          find.byKey(const ValueKey('reduce-transparency')),
        );
        await tester.tap(find.byKey(const ValueKey('reduce-transparency')));
        await tester.pumpAndSettle();
        expect(appearance.reduceTransparency, isTrue);
        expect(find.byType(BackdropFilter), findsNothing);
        await capture('reduced-transparency');
        checks.add('reduce-transparency removes all active backdrop filters');
        await appearance.setReduceTransparency(originalTransparency);
        await appearance.setMode(ThemeMode.system);
        expect(
          await nativePreferences.getString(AppearanceController.themeKey),
          'system',
        );
        checks.add('system mode persists on host');
        if (timings.isNotEmpty) {
          final build =
              timings
                  .map((frame) => frame.buildDuration.inMicroseconds / 1000)
                  .toList()
                ..sort();
          final raster =
              timings
                  .map((frame) => frame.rasterDuration.inMicroseconds / 1000)
                  .toList()
                ..sort();
          double percentile(List<double> values, double ratio) =>
              values[((values.length - 1) * ratio).round()];
          await File('${root.path}/frame-timings.txt').writeAsString(
            'frames=${timings.length}\nbuild_p50_ms=${percentile(build, 0.5)}\nbuild_p95_ms=${percentile(build, 0.95)}\nraster_p50_ms=${percentile(raster, 0.5)}\nraster_p95_ms=${percentile(raster, 0.95)}\nIncludes theme changes, navigation, screenshots and native video initialization.\n',
          );
        }
        await File('${root.path}/results.txt').writeAsString(checks.join('\n'));
        debugPrint('ORVEX_VISUAL_EVIDENCE=${root.path}');
      } finally {
        WidgetsBinding.instance.removeTimingsCallback(recordTiming);
        await session.shutdown();
        await tester.pumpWidget(const SizedBox.shrink());
        session.dispose();
        metadata.dispose();
        await appearance.setMode(originalMode);
        await appearance.setReduceTransparency(originalTransparency);
        appearance.dispose();
        SharedPreferencesAsyncPlatform.instance = nativePlatform;
      }
    },
  );
}
