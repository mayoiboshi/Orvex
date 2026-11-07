import 'dart:convert';
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
import 'package:orvex/features/anime_metadata/infrastructure/metadata_store.dart';
import 'package:orvex/features/folder_library/folder_library.dart';
import 'package:orvex/features/library/infrastructure/playback_history_store.dart';
import 'package:orvex/features/media_sources/imported_file_store.dart';
import 'package:orvex/features/media_sources/local_file_source.dart';
import 'package:orvex/features/player/application/playback_session.dart';
import 'package:orvex/features/player/infrastructure/media_kit_engine.dart';
import 'package:orvex/features/player/infrastructure/preferences_resume_store.dart';
import 'package:orvex/features/player/presentation/playback_surface.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'native edge back cancels, commits, preserves context and respects fullscreen',
    (tester) async {
      expect(Platform.isIOS, isTrue);
      expect(
        await const MethodChannel('dev.orvex/audio-session')
            .invokeMethod<bool>('isSimulator'),
        isTrue,
        reason: 'Generated fixtures are restricted to iOS simulators',
      );
      MediaKit.ensureInitialized();
      final root = await Directory.systemTemp.createTemp('orvex-back-');
      final originalPrefs = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      final appearance = AppearanceController();
      await appearance.initialize();
      final library = FolderLibrary(
        directory: () async => Directory('${root.path}/library'),
      );
      await library.initialize();
      final imports = ImportedFileStore(
        directoryProvider: () async => Directory('${root.path}/documents'),
      );
      final bytes = await rootBundle.load('test/fixtures/generated.mp4');
      for (var i = 1; i <= 12; i++) {
        final file = File(
          '${root.path}/documents/Imports/layout-$i/本地演示 - ${i.toString().padLeft(2, '0')}.mp4',
        );
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes.buffer.asUint8List());
      }
      final metadata = AnimeMetadataController(
        store: MetadataStore(
          directoryProvider: () async => Directory('${root.path}/metadata'),
        ),
      );
      await metadata.initialize();
      await metadata.setAutomatic(false);
      final history = PlaybackHistoryStore();
      var created = 0;
      final session = PlaybackSession(
        createEngine: () {
          created++;
          return MediaKitEngine(silentAudioForTesting: true);
        },
        resumeStore: PreferencesResumeStore(),
        onCheckpoint: history.record,
      );
      final screen = GlobalKey();
      final observations = <String, Object?>{};
      Future<void> until(bool Function() ready, String label) async {
        final end = DateTime.now().add(const Duration(seconds: 25));
        while (!ready() && DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(ready(), isTrue, reason: '$label; ${session.error}');
      }

      Future<void> capture(String name) async {
        await tester.pump(const Duration(milliseconds: 500));
        expect(tester.takeException(), isNull);
        final boundary =
            screen.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${root.path}/$name.png')
            .writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
        final surface = find.byType(PlaybackSurface);
        final rect = surface.evaluate().isEmpty
            ? null
            : tester.getRect(surface);
        observations[name] = {
          'window': [
            tester.view.physicalSize.width / tester.view.devicePixelRatio,
            tester.view.physicalSize.height / tester.view.devicePixelRatio,
          ],
          'safeInsets': [
            tester.view.padding.left / tester.view.devicePixelRatio,
            tester.view.padding.top / tester.view.devicePixelRatio,
            tester.view.padding.right / tester.view.devicePixelRatio,
            tester.view.padding.bottom / tester.view.devicePixelRatio,
          ],
          'videoRect': rect == null
              ? null
              : [rect.left, rect.top, rect.width, rect.height],
          'engineCount': created,
          'positionMs': session.frame.position.inMilliseconds,
        };
      }

      try {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
        ]);
        await tester.pumpWidget(
          RepaintBoundary(
            key: screen,
            child: ProviderScope(
              overrides: [
                appearanceProvider.overrideWithValue(appearance),
                sessionProvider.overrideWithValue(session),
                folderLibraryProvider.overrideWithValue(library),
                animeMetadataProvider.overrideWithValue(metadata),
                historyStoreProvider.overrideWithValue(history),
                localFilesProvider.overrideWithValue(
                  LocalFileSource(imports: imports),
                ),
              ],
              child: const OrvexApp(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('tab-1')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('本地演示').first);
        await tester.pumpAndSettle();
        final video = (await imports.listVideos()).singleWhere(
          (m) => m.name.endsWith('01.mp4'),
        );
        final row = find.byKey(ValueKey(video.resumeKey));
        await tester.ensureVisible(row);
        await tester.pumpAndSettle();
        final originalListY = tester.getTopLeft(row).dy;
        await tester.tap(row);
        await until(
          () => session.ready && session.frame.duration.inSeconds > 10,
          'native playback ready',
        );
        await session.seek(const Duration(seconds: 4));
        await until(
          () =>
              session.frame.playing &&
              session.frame.position.inMilliseconds >= 3500,
          'native playback advances',
        );
        final engine = session.engine;
        await session.pauseForInterruption();
        await tester.pumpAndSettle();
        await tester.drag(
          find.byType(CustomScrollView).last,
          const Offset(0, 2000),
        );
        await tester.pumpAndSettle();
        await appearance.setMode(ThemeMode.light);
        await tester.pumpAndSettle();
        await capture('player-light');
        await appearance.setMode(ThemeMode.dark);
        await tester.pumpAndSettle();
        await capture('player-dark');
        final width =
            tester.view.physicalSize.width / tester.view.devicePixelRatio;
        final edgeY = tester.getCenter(find.byType(PlaybackSurface)).dy;
        final originalLeft = tester.getTopLeft(find.byType(PlaybackSurface)).dx;
        await session.togglePause();
        await until(
          () => session.frame.playing,
          'native video is playing before the gesture',
        );
        expect(
          ModalRoute.of(tester.element(find.byType(PlaybackSurface)))!
              .popGestureEnabled,
          isTrue,
          reason:
              'The active Cupertino player route must allow interactive back',
        );
        final gesture = await tester.startGesture(Offset(2, edgeY));
        await gesture.moveBy(const Offset(20, 0));
        await tester.pump(const Duration(milliseconds: 16));
        await gesture.moveBy(const Offset(60, 0));
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          tester.getTopLeft(find.byType(PlaybackSurface)).dx,
          greaterThan(originalLeft),
        );
        await capture('edge-drag-dark');
        await tester.pump(const Duration(milliseconds: 500));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(find.byType(PlaybackSurface), findsOneWidget);
        expect(session.engine, same(engine));
        expect(
          session.frame.playing,
          isTrue,
          reason: 'Canceling back must not pause the video',
        );
        await capture('edge-cancelled-dark');
        final back = await tester.startGesture(Offset(2, edgeY));
        await back.moveBy(const Offset(20, 0));
        await tester.pump(const Duration(milliseconds: 16));
        await back.moveBy(Offset(width * 0.85 - 20, 0));
        await tester.pump(const Duration(milliseconds: 200));
        await back.up();
        await tester.pumpAndSettle();
        await until(
          () => !session.frame.playing,
          'committing back pauses the native video',
        );
        expect(find.byType(PlaybackSurface), findsNothing);
        expect(tester.getTopLeft(row).dy, closeTo(originalListY, 1));
        await capture('returned-series-scroll-dark');
        await tester.drag(
          find.byType(CustomScrollView).last,
          const Offset(0, 2000),
        );
        await tester.pumpAndSettle();
        expect(find.byTooltip('返回剧集'), findsOneWidget);
        expect(session.engine, same(engine));
        expect(created, 1);
        expect(
          session.frame.position.inMilliseconds,
          greaterThanOrEqualTo(3500),
        );
        await capture('returned-series-dark');
        await tester.dragFrom(Offset(2, edgeY), Offset(width * 0.85, 0));
        await tester.pumpAndSettle();
        expect(find.byTooltip('返回剧集'), findsNothing);
        await appearance.setMode(ThemeMode.light);
        await tester.pumpAndSettle();
        await capture('returned-library-light');
        await tester.dragFrom(Offset(2, edgeY), Offset(width * 0.85, 0));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('tab-1')), findsOneWidget);
        await tester.tap(find.text('本地演示').first);
        await tester.pumpAndSettle();
        final play = find.text('播放第 1 集');
        await tester.ensureVisible(play);
        await tester.pumpAndSettle();
        await tester.tap(play);
        await tester.pumpAndSettle();
        await until(
          () => session.frame.playing,
          'same episode resumes after returning',
        );
        expect(session.engine, same(engine));
        expect(created, 1);
        await session.pauseForInterruption();
        await tester.pumpAndSettle();
        await tester.drag(
          find.byType(CustomScrollView).last,
          const Offset(0, 2000),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('全屏播放'));
        await tester.pumpAndSettle();
        final size = MediaQuery.sizeOf(
          tester.element(find.byType(PlaybackSurface)),
        );
        await tester.dragFrom(
          Offset(2, size.height * 0.55),
          Offset(size.width * 0.6, 0),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<PlaybackSurface>(find.byType(PlaybackSurface))
              .fullscreen,
          isTrue,
        );
        expect(session.engine, same(engine));
        await capture('fullscreen-edge-remains-player');
        await tester.tap(find.byTooltip('退出全屏').first);
        await tester.pumpAndSettle();
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
        ]);
        await tester.pumpAndSettle();
        expect(find.byType(PlaybackSurface), findsOneWidget);
        expect(session.engine, same(engine));
        expect(created, 1);
      } finally {
        await File('${root.path}/observations.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert(observations),
        );
        debugPrint('ORVEX_BACK_EVIDENCE=${root.path}');
        tester.view.resetPhysicalSize();
        await tester.pumpWidget(const SizedBox.shrink());
        session.dispose();
        metadata.dispose();
        library.dispose();
        appearance.dispose();
        SharedPreferencesAsyncPlatform.instance = originalPrefs;
        await SystemChrome.setPreferredOrientations([]);
      }
    },
  );
}
