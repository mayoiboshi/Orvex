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
import 'package:orvex/features/anime_metadata/presentation/anime_metadata_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orvex/features/folder_library/folder_library.dart';
import 'package:orvex/features/library/infrastructure/playback_history_store.dart';
import 'package:orvex/features/media_sources/imported_file_store.dart';
import 'package:orvex/features/media_sources/local_file_source.dart';
import 'package:orvex/features/player/application/playback_session.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:orvex/features/player/infrastructure/media_kit_engine.dart';
import 'package:orvex/features/player/infrastructure/preferences_resume_store.dart';
import 'package:orvex/features/player/presentation/playback_surface.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('wide and side playlist layouts preserve native playback', (
    tester,
  ) async {
    expect(Platform.isIOS, isTrue);
    expect(
      await const MethodChannel('dev.orvex/audio-session')
          .invokeMethod<bool>('isSimulator'),
      isTrue,
      reason: 'Generated media experiments are restricted to iOS simulators',
    );
    MediaKit.ensureInitialized();
    final root = await Directory.systemTemp.createTemp('orvex-wide-');
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
        '${root.path}/documents/Imports/episode-$i/宽屏验证 - ${i.toString().padLeft(2, '0')}.mp4',
      );
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes.buffer.asUint8List());
    }
    final videos = await imports.listVideos();
    videos.sort((a, b) => a.name.compareTo(b.name));
    final first = videos.singleWhere((m) => m.name.endsWith('01.mp4'));
    final second = videos.singleWhere((m) => m.name.endsWith('02.mp4'));
    final subtitle = await File('${root.path}/宽屏验证.ass')
        .writeAsString(await rootBundle.loadString('test/fixtures/sample.ass'));
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
    final tablet =
        tester.view.display.size.shortestSide /
            tester.view.display.devicePixelRatio >=
        600;
    observations['tabletDisplay'] = tablet;
    Future<void> until(bool Function() condition, String label) async {
      final end = DateTime.now().add(const Duration(seconds: 25));
      while (!condition() && DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(condition(), isTrue, reason: '$label; ${session.error}');
    }

    Future<void> capture(String name) async {
      await tester.pump(const Duration(milliseconds: 450));
      expect(tester.takeException(), isNull);
      final boundary =
          screen.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('${root.path}/$name.png')
          .writeAsBytes(png!.buffer.asUint8List());
      image.dispose();
      final rect = tester.getRect(find.byType(PlaybackSurface));
      observations[name] = {
        'videoRect': [rect.left, rect.top, rect.width, rect.height],
        'engineCount': created,
        'positionMs': session.frame.position.inMilliseconds,
        'subtitleId': session.frame.subtitleTrackId,
        'playing': session.frame.playing,
        'sideList': find
            .byKey(const ValueKey('watch-episodes-panel'))
            .evaluate()
            .isNotEmpty,
      };
    }

    var passed = false;
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
      await tester.pump(const Duration(milliseconds: 450));
      final opening = session.open(first, queue: videos);
      await until(
        () => session.ready && session.frame.duration.inSeconds > 10,
        'native playback ready',
      );
      await opening;
      await session.seek(const Duration(seconds: 4));
      await session.pauseForInterruption();
      await until(
        () =>
            !session.frame.playing &&
            session.frame.position.inMilliseconds >= 3500,
        'paused native frame',
      );
      await session.loadSubtitle(
        LocalMedia(uri: subtitle.uri, name: '宽屏验证.ass'),
      );
      await until(
        () => !['auto', 'no'].contains(session.frame.subtitleTrackId),
        'native external subtitle selected',
      );
      final engine = session.engine;
      final subtitleId = session.frame.subtitleTrackId;
      final controls = tester.state(find.byType(PlaybackSurface));
      final panel = find.byKey(const ValueKey('watch-episodes-panel'));
      final toggle = find.byKey(const ValueKey('playback-wide-mode'));
      if (tablet) {
        await capture('tablet-portrait');
        // Flutter viewport resizing, not a claim of OS-level Split View testing.
        tester.view.physicalSize =
            const Size(1210, 834) * tester.view.devicePixelRatio;
        await tester.pump(const Duration(milliseconds: 450));
        await tester.tap(find.byKey(const ValueKey('watch-metadata')));
        await tester.pump(const Duration(milliseconds: 450));
        expect(find.byType(AnimeMetadataSheet), findsOneWidget);
        Navigator.of(
          tester.element(find.byType(AnimeMetadataSheet)),
          rootNavigator: true,
        ).pop();
        await tester.pump(const Duration(milliseconds: 450));
        final automatic = find.byKey(const ValueKey('watch-auto-next'));
        await tester.tap(automatic);
        await tester.pump(const Duration(milliseconds: 450));
        expect(session.autoNext, isTrue);
        expect(
          await SharedPreferencesAsync().getBool('orvex.player.autoNext.v1'),
          isTrue,
        );
        await tester.tap(automatic);
        await tester.pump(const Duration(milliseconds: 450));
        expect(session.autoNext, isFalse);
        observations['metadataAndAutomaticControls'] = true;
        for (final mode in [ThemeMode.light, ThemeMode.dark]) {
          await appearance.setMode(mode);
          await capture('side-${mode.name}');
          final rect = tester.getRect(find.byType(PlaybackSurface));
          expect(rect.left, 0, reason: 'iPad video reaches the safe left edge');
          expect(tester.getRect(panel).left, greaterThan(rect.right));
          await tester.drag(
            find.descendant(of: panel, matching: find.byType(CustomScrollView)),
            const Offset(0, -350),
          );
          await tester.pump(const Duration(milliseconds: 450));
          expect(tester.getRect(find.byType(PlaybackSurface)), rect);
          await tester.tap(find.byTooltip('搜索和筛选列表'));
          await tester.pump(const Duration(milliseconds: 450));
          expect(
            find
                .descendant(of: panel, matching: find.byType(TextFormField))
                .hitTestable(),
            findsOneWidget,
          );
          await tester.tap(find.byTooltip('搜索和筛选列表'));
          await tester.pump(const Duration(milliseconds: 450));
          await tester.tap(toggle);
          await capture('wide-${mode.name}');
          expect(tester.getRect(find.byType(PlaybackSurface)).left, 0);
          expect(panel, findsNothing);
          expect(
            tester.getSize(find.byType(PlaybackSurface)).width,
            greaterThan(rect.width),
          );
          expect(tester.state(find.byType(PlaybackSurface)), same(controls));
          await tester.tap(toggle);
          await tester.pump(const Duration(milliseconds: 450));
          expect(panel, findsOneWidget);
          expect(session.engine, same(engine));
          expect(session.frame.subtitleTrackId, subtitleId);
        }
        tester.view.physicalSize =
            const Size(600, 480) * tester.view.devicePixelRatio;
        await capture('small-window-fallback');
        expect(toggle, findsNothing);
        expect(panel, findsNothing);
        tester.view.physicalSize =
            const Size(1210, 834) * tester.view.devicePixelRatio;
        await capture('side-restored');
        expect(panel, findsOneWidget);
        expect(tester.state(find.byType(PlaybackSurface)), same(controls));
      } else {
        for (final mode in [ThemeMode.light, ThemeMode.dark]) {
          await appearance.setMode(mode);
          await capture('phone-${mode.name}');
          expect(toggle, findsNothing);
          expect(panel, findsNothing);
        }
        tester.view.physicalSize =
            const Size(932, 430) * tester.view.devicePixelRatio;
        await capture('phone-landscape');
        expect(toggle, findsNothing);
        expect(panel, findsNothing);
      }
      await tester.tap(find.byTooltip('全屏播放'));
      await tester.pump(const Duration(milliseconds: 450));
      await until(
        () => tester
            .widget<PlaybackSurface>(find.byType(PlaybackSurface))
            .fullscreen,
        'fullscreen entered',
      );
      expect(toggle, findsNothing);
      expect(panel, findsNothing);
      await capture('fullscreen');
      await tester.tap(find.byTooltip('退出全屏').first);
      await tester.pump(const Duration(milliseconds: 450));
      await until(
        () => !tester
            .widget<PlaybackSurface>(find.byType(PlaybackSurface))
            .fullscreen,
        'fullscreen exited',
      );
      expect(session.engine, same(engine));
      expect(created, 1);
      expect(session.frame.subtitleTrackId, subtitleId);
      await session.togglePause();
      await until(() => session.frame.playing, 'play resumed');
      final position = session.frame.position;
      if (tablet) await tester.tap(toggle);
      await until(
        () =>
            session.frame.playing &&
            session.frame.position >
                position + const Duration(milliseconds: 300),
        'playback advances through layout change',
      );
      expect(session.engine, same(engine));
      expect(created, 1);
      expect(session.frame.subtitleTrackId, subtitleId);
      observations['sameEngineAndSubtitleWhilePlaying'] = true;
      await session.pauseForInterruption();
      await tester.pump(const Duration(milliseconds: 450));
      if (tablet) {
        await tester.tap(toggle);
        await tester.pump(const Duration(milliseconds: 450));
        final row = find.descendant(
          of: panel,
          matching: find.byKey(ValueKey(second.resumeKey)),
        );
        await tester.ensureVisible(row);
        await tester.pump(const Duration(milliseconds: 450));
        await tester.tap(row);
        await until(
          () =>
              session.ready &&
              session.media?.resumeKey == second.resumeKey &&
              session.frame.duration.inSeconds > 10,
          'side list episode opened',
        );
        expect(created, 2);
        await session.pauseForInterruption();
        await capture('side-selected-next');
        observations['sideEpisodeOpened'] = true;
        await tester.tap(find.byTooltip('上一集'));
        await until(
          () =>
              session.ready &&
              session.media?.resumeKey == first.resumeKey &&
              session.frame.duration.inSeconds > 10,
          'previous button opens first episode',
        );
        await session.pauseForInterruption();
        await tester.pump(const Duration(milliseconds: 450));
        await tester.tap(find.byTooltip('下一集'));
        await until(
          () =>
              session.ready &&
              session.media?.resumeKey == second.resumeKey &&
              session.frame.duration.inSeconds > 10,
          'next button opens second episode',
        );
        await session.pauseForInterruption();
        observations['previousNextControls'] = true;
        expect(created, 4);
        await tester.pump(const Duration(milliseconds: 450));
        await tester.tap(find.byTooltip('定位当前视频'));
        await tester.pump(const Duration(milliseconds: 450));
        expect(find.byTooltip('搜索和筛选列表').hitTestable(), findsOneWidget);
        await capture('side-highlight-final');
        await appearance.setMode(ThemeMode.light);
        await capture('side-highlight-light');
        await appearance.setReduceTransparency(true);
        await capture('reduced-transparency-light');
        expect(find.byType(BackdropFilter), findsNothing);
        await appearance.setReduceTransparency(false);
        observations['reducedTransparency'] = true;
      }
      // Exercise the real PlayerPage full-screen queue and back handling.
      await tester.pump(const Duration(milliseconds: 450));
      await tester.tap(find.byTooltip('全屏播放'));
      await until(
        () => tester
            .widget<PlaybackSurface>(find.byType(PlaybackSurface))
            .fullscreen,
        'episode picker fullscreen entered',
      );
      await tester.tap(find.byTooltip('选择集数'));
      await tester.pump(const Duration(milliseconds: 450));
      expect(find.byTooltip('关闭选集'), findsOneWidget);
      await binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 450));
      expect(find.byTooltip('关闭选集'), findsNothing);
      expect(
        tester.widget<PlaybackSurface>(find.byType(PlaybackSurface)).fullscreen,
        isTrue,
      );
      await tester.tap(find.byTooltip('选择集数'));
      await tester.pump(const Duration(milliseconds: 450));
      final target = session.media?.resumeKey == first.resumeKey
          ? second
          : first;
      final queueBefore = session.playlist
          .map((item) => item.resumeKey)
          .toList();
      final targetCard = find.byKey(ValueKey('episode-${target.resumeKey}'));
      await tester.drag(find.byType(ListView).last, const Offset(600, 0));
      await tester.pump(const Duration(milliseconds: 450));
      await tester.ensureVisible(targetCard);
      await tester.tap(targetCard);
      await until(
        () => session.ready && session.media?.resumeKey == target.resumeKey,
        'fullscreen episode selected',
      );
      expect(
        session.playlist.map((item) => item.resumeKey).toList(),
        queueBefore,
      );
      expect(find.byTooltip('关闭选集'), findsNothing);
      expect(
        tester.widget<PlaybackSurface>(find.byType(PlaybackSurface)).fullscreen,
        isTrue,
      );
      observations['fullscreenEpisodePickerAndBack'] = true;
      expect(session.error, isNull);
      passed = true;
    } finally {
      observations['passed'] = passed;
      await File(
        '${root.path}/observations.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(observations));
      debugPrint('ORVEX_WIDE_EVIDENCE=${root.path}');
      tester.view.resetPhysicalSize();
      await tester.pumpWidget(const SizedBox.shrink());
      await session.shutdown();
      session.dispose();
      metadata.dispose();
      library.dispose();
      appearance.dispose();
      SharedPreferencesAsyncPlatform.instance = originalPrefs;
      await SystemChrome.setPreferredOrientations([]);
    }
  });
}
