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
import 'package:orvex/design/glass.dart';
import 'package:orvex/features/anime_metadata/application/anime_metadata_controller.dart';
import 'package:orvex/features/anime_metadata/domain/anime_subject.dart';
import 'package:orvex/features/anime_metadata/infrastructure/metadata_store.dart';
import 'package:orvex/features/folder_library/folder_library.dart';
import 'package:orvex/features/library/infrastructure/playback_history_store.dart';
import 'package:orvex/features/library/presentation/library_views.dart';
import 'package:orvex/features/media_sources/imported_file_store.dart';
import 'package:orvex/features/media_sources/local_file_source.dart';
import 'package:orvex/features/player/application/playback_session.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:orvex/features/player/infrastructure/media_kit_engine.dart';
import 'package:orvex/features/player/infrastructure/preferences_resume_store.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _Files extends LocalFileSource {
  _Files(ImportedFileStore store) : super(imports: store);
  int pickerCalls = 0;
  @override
  Future<LocalMedia?> pickVideo() async {
    pickerCalls++;
    return null;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  const stage = String.fromEnvironment(
    'ORVEX_HOME_UI_STAGE',
    defaultValue: 'after',
  );
  testWidgets('home polish $stage: themes, sections, actions and resume', (
    tester,
  ) async {
    expect(Platform.isIOS, isTrue);
    expect(
      await const MethodChannel('dev.orvex/audio-session')
          .invokeMethod<bool>('isSimulator'),
      isTrue,
      reason: 'Generated Home fixtures must never run on physical devices',
    );
    MediaKit.ensureInitialized();
    final root = await Directory.systemTemp.createTemp('orvex-home-ui-$stage-');
    final originalPrefs = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    final appearance = AppearanceController();
    await appearance.initialize();
    final folders = FolderLibrary(
      directory: () async => Directory('${root.path}/folders'),
    );
    await folders.initialize();
    final store = ImportedFileStore(
      directoryProvider: () async => Directory('${root.path}/documents'),
    );
    final files = _Files(store);
    final source = await rootBundle.load('test/fixtures/generated.mp4');
    final videos = <LocalMedia>[];
    for (var i = 0; i < 8; i++) {
      final title = i < 4 ? '葬送的芙莉莲' : '名侦探柯南';
      final episode = i < 4 ? i + 1 : i + 611;
      final relative = 'Imports/home-$i/$title - $episode.mp4';
      final file = File('${root.path}/documents/$relative');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(source.buffer.asUint8List());
      videos.add(
        LocalMedia(
          uri: file.uri,
          name: '$title - $episode.mp4',
          importPath: relative,
        ),
      );
    }
    // Reuse only earlier simulator visual-test cache. No network or user media.
    Directory? cached;
    await for (final d in Directory.systemTemp.list()) {
      if (d is Directory &&
          d.uri.pathSegments.any((s) => s.startsWith('orvex-visual-'))) {
        final candidate = Directory('${d.path}/cache');
        if (await File('${candidate.path}/bangumi-cover-400602.img').exists() &&
            await File('${candidate.path}/bangumi-cover-899.img').exists()) {
          cached = candidate;
          break;
        }
      }
    }
    expect(
      cached,
      isNotNull,
      reason: 'Prerequisite: previous visual-system test cached Bangumi covers',
    );
    final old = await MetadataStore(directoryProvider: () async => cached!)
        .read();
    final subjects = <int, AnimeSubject>{
      for (final m in old.entries.values)
        if (m.subject != null) m.subject!.id: m.subject!,
    };
    final metadataStore = MetadataStore(
      directoryProvider: () async => Directory('${root.path}/metadata'),
    );
    final entries = <String, AnimeMatch>{};
    for (var i = 0; i < videos.length; i++) {
      final subject = subjects[i < 4 ? 400602 : 899]!;
      entries[animeMediaKey(videos[i])] = AnimeMatch(
        query: subject.title,
        status: AnimeMatchStatus.matched,
        updatedAt: DateTime.utc(2026, 11, 6),
        subject: subject,
        manual: true,
      );
    }
    await metadataStore.write(false, entries);
    for (final id in [400602, 899]) {
      await metadataStore.savePoster(
        id,
        await File('${cached!.path}/bangumi-cover-$id.img').readAsBytes(),
      );
    }
    final metadata = AnimeMetadataController(store: metadataStore);
    await metadata.initialize();
    final history = PlaybackHistoryStore();
    final resume = PreferencesResumeStore();
    for (final i in [4, 0, 5, 2]) {
      final position = Duration(seconds: 5 + i);
      await history.record(
        videos[i],
        PlaybackFrame(
          position: position,
          duration: const Duration(seconds: 18),
        ),
      );
      await resume.write(videos[i].resumeKey, position);
    }
    var created = 0;
    final session = PlaybackSession(
      createEngine: () {
        created++;
        return MediaKitEngine(silentAudioForTesting: true);
      },
      resumeStore: resume,
      onCheckpoint: history.record,
    );
    final screen = GlobalKey();
    final observations = <String, Object?>{
      'stage': stage,
      'fixtureVideos': videos.length,
      'cachedPosters': 2,
    };
    Future<void> until(bool Function() ready, String label) async {
      final end = DateTime.now().add(const Duration(seconds: 25));
      while (!ready() && DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(ready(), isTrue, reason: '$label; ${session.error}');
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
    }

    final home = find.byKey(const PageStorageKey('library-tab-0'));
    Future<void> scrollHome({bool bottom = false}) async {
      final scroll = tester.state<ScrollableState>(
        find.descendant(of: home, matching: find.byType(Scrollable)).first,
      );
      scroll.position.jumpTo(bottom ? scroll.position.maxScrollExtent : 0);
      await tester.pump(const Duration(milliseconds: 450));
    }

    final recentMedia = (await store.listVideos())
        .where((media) => media.resumeKey != videos[2].resumeKey)
        .take(8)
        .toList();
    Finder recentCard(LocalMedia media) =>
        find.byKey(ValueKey('home-recent-${media.resumeKey}'));
    final lastCard = recentCard(recentMedia.last);
    void expectLastRowVisible() {
      final last = tester.getRect(lastCard);
      final navTop = tester.getTopLeft(find.byType(LibraryTabBar)).dy;
      final scrollTop = tester.getTopLeft(home).dy;
      for (final media in recentMedia) {
        final card = tester.getRect(recentCard(media));
        if ((card.top - last.top).abs() < 1) {
          expect(card.top, greaterThanOrEqualTo(scrollTop));
          expect(card.bottom, lessThan(navTop));
        }
      }
    }

    var passed = false;
    try {
      await tester.pumpWidget(
        RepaintBoundary(
          key: screen,
          child: ProviderScope(
            overrides: [
              appearanceProvider.overrideWithValue(appearance),
              folderLibraryProvider.overrideWithValue(folders),
              localFilesProvider.overrideWithValue(files),
              animeMetadataProvider.overrideWithValue(metadata),
              historyStoreProvider.overrideWithValue(history),
              sessionProvider.overrideWithValue(session),
            ],
            child: const OrvexApp(),
          ),
        ),
      );
      await until(
        () => find.text('继续播放').evaluate().isNotEmpty,
        'home records loaded',
      );
      final nativeSize =
          tester.view.physicalSize / tester.view.devicePixelRatio;
      final systemLandscape = nativeSize.width > nativeSize.height;
      final landscape = systemLandscape
          ? nativeSize
          : Size(nativeSize.height, nativeSize.width);
      observations['systemLandscape'] = systemLandscape;
      observations['landscapeViewport'] = [landscape.width, landscape.height];
      for (final narrow in [false, true]) {
        final size = narrow ? Size(438, landscape.height) : landscape;
        tester.view.physicalSize = size * tester.view.devicePixelRatio;
        for (final mode in [ThemeMode.light, ThemeMode.dark]) {
          await appearance.setMode(mode);
          await scrollHome();
          final name = '${narrow ? 'narrow' : 'landscape'}-${mode.name}';
          await capture('$name-top');
          await scrollHome(bottom: true);
          if (stage != 'before') expectLastRowVisible();
          await capture('$name-bottom');
        }
      }
      tester.view.physicalSize = landscape * tester.view.devicePixelRatio;
      await appearance.setMode(ThemeMode.light);
      await scrollHome();
      final nav = tester.getSize(
        find
            .descendant(
              of: find.byType(LibraryTabBar),
              matching: find.byType(GlassSurface),
            )
            .first,
      );
      observations['navigationSize'] = [nav.width, nav.height];
      if (stage != 'before') {
        await tester.tap(find.byTooltip('打开本地视频'));
        await tester.pump(const Duration(milliseconds: 450));
        expect(files.pickerCalls, 1);
        await tester.tap(find.byTooltip('搜索媒体库'));
        await tester.pump(const Duration(milliseconds: 450));
        expect(find.byType(TextFormField), findsWidgets);
        await tester.tap(find.byKey(const ValueKey('tab-0')));
        await tester.pump(const Duration(milliseconds: 450));
        await scrollHome();
        await tester.tap(find.widgetWithText(TextButton, '播放记录'));
        await tester.pump(const Duration(milliseconds: 450));
        expect(find.text('最近播放'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('tab-0')));
        await tester.pump(const Duration(milliseconds: 450));
        await scrollHome();
        await Scrollable.ensureVisible(
          tester.element(find.byKey(const ValueKey('home-library'))),
          alignment: 0.35,
        );
        await capture('landscape-light-library');
        await tester.tap(find.byKey(const ValueKey('home-library')));
        await tester.pump(const Duration(milliseconds: 450));
        expect(find.byType(TextFormField), findsWidgets);
        expect(find.byKey(const ValueKey('home-library')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('tab-0')));
        await tester.pump(const Duration(milliseconds: 450));
        await scrollHome(bottom: true);
        expectLastRowVisible();
        await tester.tap(
          find.descendant(of: lastCard, matching: find.byTooltip('番剧资料')),
        );
        await tester.pump(const Duration(milliseconds: 450));
        expect(find.byTooltip('关闭番剧资料'), findsOneWidget);
        await tester.tap(find.byTooltip('关闭番剧资料'));
        await tester.pump(const Duration(milliseconds: 450));
        await tester.tap(find.byKey(const ValueKey('tab-3')));
        await tester.pump(const Duration(milliseconds: 450));
        expect(find.text('显示继续观看'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('tab-0')));
        await tester.pump(const Duration(milliseconds: 450));
        await scrollHome();
        await tester.tap(find.text('继续播放'));
        await until(
          () =>
              session.ready &&
              session.frame.duration.inSeconds > 10 &&
              session.frame.position.inSeconds >= 6,
          'native Home resume',
        );
        expect(session.media?.resumeKey, videos[2].resumeKey);
        expect(created, 1);
        await session.pauseForInterruption();
        await tester.tap(find.byTooltip('返回首页'));
        await tester.pump(const Duration(milliseconds: 450));
        await appearance.setReduceTransparency(true);
        await scrollHome();
        await capture('reduced-transparency');
        expect(find.byType(BackdropFilter), findsNothing);
        observations['actionsAndNativeResume'] = true;
      }
      passed = true;
    } finally {
      observations['passed'] = passed;
      await File(
        '${root.path}/observations.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(observations));
      debugPrint('ORVEX_HOME_EVIDENCE=${root.path}');
      tester.view.resetPhysicalSize();
      await tester.pumpWidget(const SizedBox.shrink());
      await session.shutdown();
      session.dispose();
      metadata.dispose();
      folders.dispose();
      appearance.dispose();
      SharedPreferencesAsyncPlatform.instance = originalPrefs;
    }
  });
}
