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
import 'package:orvex/features/folder_library/folder_library.dart';
import 'package:orvex/features/folder_library/folder_models.dart';
import 'package:orvex/features/folder_library/thumbnail_cache.dart';
import 'package:orvex/features/library/infrastructure/playback_history_store.dart';
import 'package:orvex/features/media_sources/imported_file_store.dart';
import 'package:orvex/features/media_sources/local_file_source.dart';
import 'package:orvex/features/player/application/playback_session.dart';
import 'package:orvex/features/player/infrastructure/media_kit_engine.dart';
import 'package:orvex/features/player/infrastructure/preferences_resume_store.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'native folder bookmarks, scan, thumbnails and continuous portrait playlist',
    (tester) async {
      if (Platform.isIOS) {
        expect(
          await const MethodChannel('dev.orvex/audio-session')
              .invokeMethod<bool>('isSimulator'),
          isTrue,
          reason:
              'Never run generated folder fixtures on a physical iPhone/iPad',
        );
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
        ]);
      }
      expect(
        Platform.isIOS || Platform.isMacOS,
        isTrue,
        reason: 'Apple native adapter integration check only',
      );
      MediaKit.ensureInitialized();
      final documents = await getApplicationDocumentsDirectory();
      final fixture = File('${documents.path}/orvex-folder-native-test.json');
      expect(
        await fixture.exists(),
        isTrue,
        reason: 'First run MediaFolderAccessTests on this simulator/host; no fake permission grants are injected',
      );
      final root = FolderRoot.fromJson(
        jsonDecode(await fixture.readAsString()) as Map<String, dynamic>,
      );
      final evidence = await Directory('${documents.path}/OrvexFolderEvidence')
          .create();
      final index = Directory('${evidence.path}/index');
      final preferencesBackend = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      final library = FolderLibrary(directory: () async => index);
      await library.initialize();
      library.roots.clear();
      library.entries.clear();
      library.roots.add(root);
      await library.scan(root);
      expect(library.discovered, 7);
      expect(root.issue, isNull);
      final restored = FolderLibrary(directory: () async => index);
      await restored.initialize();
      expect(restored.entries.length, library.entries.length);
      final restoredLease = await restored.access.acquire(
        restored.roots.single,
      );
      await restoredLease.release();
      restored.dispose();
      final thumbnails = ThumbnailCache(library);
      final appearance = AppearanceController();
      await appearance.initialize();
      final metadata = AnimeMetadataController();
      await metadata.initialize();
      await metadata.setAutomatic(false);
      final history = PlaybackHistoryStore();
      var created = 0;
      final session = PlaybackSession(
        createEngine: () {
          created++;
          return MediaKitEngine(silentAudioForTesting: Platform.isIOS);
        },
        resumeStore: PreferencesResumeStore(),
        onCheckpoint: history.record,
        prepare: (media) async {
          final value = await library.prepare(media);
          return PreparedPlayback(value.media, value.release);
        },
      );
      final screen = GlobalKey();
      final checks = <String>[
        'Actual generated MP4 fixture files in a real nested folder; .mkv names still contain MP4, NOT genuine MKV coverage.',
        'Native Apple bookmarks restored across adapter and Flutter app launches. App-owned root: external Files/iCloud/provider grant UI NOT TESTED.',
        if (Platform.isIOS)
          'Simulator silent mode: audio and physical brightness NOT TESTED.',
      ];
      Future<void> until(bool Function() ready, String label) async {
        final end = DateTime.now().add(const Duration(seconds: 45));
        while (!ready() && DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          ready(),
          isTrue,
          reason: '$label; ${session.error}; ${library.error}',
        );
        checks.add(label);
      }

      Future<void> capture(String name) async {
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);
        final boundary =
            screen.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${evidence.path}/$name.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      }

      try {
        await tester.pumpWidget(
          RepaintBoundary(
            key: screen,
            child: ProviderScope(
              overrides: [
                folderLibraryProvider.overrideWithValue(library),
                thumbnailCacheProvider.overrideWithValue(thumbnails),
                sessionProvider.overrideWithValue(session),
                appearanceProvider.overrideWithValue(appearance),
                animeMetadataProvider.overrideWithValue(metadata),
                historyStoreProvider.overrideWithValue(history),
                localFilesProvider.overrideWithValue(
                  LocalFileSource(
                    imports: ImportedFileStore(
                      directoryProvider: () async =>
                          Directory('${evidence.path}/imports'),
                    ),
                  ),
                ),
              ],
              child: const OrvexApp(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('tab-1')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('名侦探柯南'));
        await tester.pumpAndSettle();
        await appearance.setMode(ThemeMode.light);
        await capture('directory-light');
        await tester.tap(find.widgetWithText(ChoiceChip, 'TV'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ChoiceChip, '0124-0173'));
        await tester.pumpAndSettle();
        final selected = library
            .children(root.id, 'TV/0124-0173', directories: false)
            .first;
        expect(selected.name, '第124集.mkv');
        final mp4 = library
            .children(root.id, 'TV/0001-0123', directories: false)
            .first;
        final preview = await thumbnails.request(mp4).result;
        expect(
          preview,
          isNotNull,
          reason: 'Real MP4 thumbnail extraction must succeed',
        );
        expect(await preview!.length(), greaterThan(1000));
        final mkvPreview = await thumbnails.request(selected).result;
        checks.add(
          mkvPreview == null
              ? 'Apple preview rejects .mkv fixture names; themed placeholder used independently of playback'
              : 'Apple preview also accepted the renamed fixture; genuine MKV remains NOT TESTED',
        );
        checks.add(
          'Real Apple AVAssetImageGenerator preview and duration persisted to bounded disk cache',
        );
        await capture('group-light');
        await tester.tap(find.text('第124集'));
        await until(
          () => session.ready && session.frame.duration.inSeconds > 10,
          'directory item starts actual media_kit playback',
        );
        await session.seek(const Duration(seconds: 4));
        await until(
          () => session.frame.position.inSeconds >= 3,
          'seek updates native frame',
        );
        final engine = session.engine;
        await until(() => session.frame.playing, 'native playback running');
        final frame = await (engine! as MediaKitEngine).captureFrame();
        expect(frame, isNotNull);
        expect(frame!.length, greaterThan(1000));
        await File('${evidence.path}/decoded-frame.png').writeAsBytes(frame);
        await session.pauseForInterruption();
        await tester.pumpAndSettle();
        await capture('portrait-light');
        await appearance.setMode(ThemeMode.dark);
        await tester.pumpAndSettle();
        await capture('portrait-dark');
        expect(session.engine, same(engine));
        expect(created, 1);
        await tester.tap(find.widgetWithText(ChoiceChip, '0001-0123'));
        await tester.pumpAndSettle();
        expect(session.engine, same(engine));
        expect(session.media?.folderFile, selected.id);
        await capture('browse-other-group-dark');
        await tester.tap(find.byTooltip('定位当前视频'));
        await tester.pumpAndSettle();
        expect(find.text('第125集'), findsOneWidget);
        final scroll = find.byType(CustomScrollView).last;
        await tester.drag(scroll, const Offset(0, -500));
        await tester.pumpAndSettle();
        expect(session.engine, same(engine));
        expect(created, 1);
        await tester.drag(scroll, const Offset(0, 1000));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('全屏播放'));
        await tester.pumpAndSettle();
        expect(session.engine, same(engine));
        await capture('fullscreen');
        await tester.tap(find.byTooltip('退出全屏').first);
        await tester.pumpAndSettle();
        expect(session.engine, same(engine));
        expect(session.frame.position.inSeconds, greaterThanOrEqualTo(3));
        checks.add(
          'Scrolling, directory browsing, theme changes and fullscreen preserve one native engine and progress',
        );
        if (Platform.isIOS) {
          await SystemChrome.setPreferredOrientations([
            DeviceOrientation.portraitUp,
          ]);
          await until(
            () =>
                tester.view.physicalSize.height >
                tester.view.physicalSize.width,
            'return to portrait after fullscreen without replacing engine',
          );
        }
        await tester.ensureVisible(find.byTooltip('下一集'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('下一集'));
        await until(
          () =>
              session.ready &&
              session.media?.name == '第125集.mkv' &&
              session.frame.duration.inSeconds > 10,
          'next episode opens same real folder queue',
        );
        expect(created, 2);
        expect(session.hasNext, isFalse);
        expect(session.hasPrevious, isTrue);
        await session.pauseForInterruption();
        await tester.pumpAndSettle();
        await capture('next-episode-dark');
        await session.checkpoint();
        final record = (await history.list()).first;
        expect(record.media.folderFile, session.media?.folderFile);
        expect(library.playlist(record.media).length, 2);
        checks.add(
          'History retains stable folder/file IDs and reconstructs the containing two-item playlist',
        );
        await File('${evidence.path}/results.txt')
            .writeAsString(checks.join('\n'));
        debugPrint('ORVEX_FOLDER_EVIDENCE=${evidence.path}');
      } finally {
        await session.shutdown();
        await tester.pumpWidget(const SizedBox.shrink());
        thumbnails.dispose();
        session.dispose();
        metadata.dispose();
        appearance.dispose();
        library.dispose();
        SharedPreferencesAsyncPlatform.instance = preferencesBackend;
      }
    },
  );
}
