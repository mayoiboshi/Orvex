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
      if (i == 7) continue; // Unmatched local file.
      final subject = switch (i) {
        6 => const AnimeSubject(
          id: 101,
          name: '电影测试样片',
          nameCn: '电影测试样片',
          platform: 'WEB',
          episodes: 1,
        ),
        3 => const AnimeSubject(
          id: 102,
          name: '封面损坏测试样片',
          nameCn: '封面损坏测试样片',
          platform: '剧场版',
          episodes: 1,
        ),
        _ => subjects[i < 4 ? 400602 : 899]!,
      };
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
    // Reuse a cached image to exercise the movie-poster slot without fetching
    // new art. The damaged cover must fall back to the same video-frame path.
    await metadataStore.savePoster(
      101,
      await File('${cached!.path}/bangumi-cover-899.img').readAsBytes(),
    );
    await metadataStore.savePoster(102, [1, 2, 3]);
    final metadata = AnimeMetadataController(store: metadataStore);
    await metadata.initialize();
    final history = PlaybackHistoryStore();
    final resume = PreferencesResumeStore();
    final resumeIndex = stage == 'before' ? 2 : 6;
    for (final i in [4, 0, 5, resumeIndex]) {
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
        .where(
          (media) =>
              stage != 'before' || media.resumeKey != videos[2].resumeKey,
        )
        .toList();
    String recentKey(LocalMedia media) {
      final subject = entries[animeMediaKey(media)]?.subject;
      return stage != 'before' && [400602, 899].contains(subject?.id)
          ? 'bangumi:${subject!.id}'
          : media.resumeKey;
    }

    Finder recentCard(LocalMedia media) =>
        find.byKey(ValueKey('home-recent-${recentKey(media)}'));
    final lastKey = recentMedia.map(recentKey).toSet().last;
    final lastCard = find.byKey(ValueKey('home-recent-$lastKey'));
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
      final hero = find.byKey(const ValueKey('home-resume-card'));
      final rail = find.byKey(const ValueKey('home-continue-rail'));
      final covers = find.descendant(of: rail, matching: find.byType(Image));
      String? imageFilePath(Image image) {
        final source = image.image;
        return source is ResizeImage && source.imageProvider is FileImage
            ? (source.imageProvider as FileImage).file.path
            : null;
      }

      bool hasLocalThumbnail() => tester
          .widgetList<Image>(covers)
          .any(
            (image) =>
                imageFilePath(image)?.contains('/thumbnails-v1/') ?? false,
          );
      String? recentImage(LocalMedia media, String part) => tester
          .widgetList<Image>(
            find.descendant(
              of: recentCard(media),
              matching: find.byType(Image),
            ),
          )
          .map(imageFilePath)
          .whereType<String>()
          .where((path) => path.contains(part))
          .firstOrNull;
      for (final narrow in [false, true]) {
        final size = narrow ? Size(438, landscape.height) : landscape;
        tester.view.physicalSize = size * tester.view.devicePixelRatio;
        for (final mode in [ThemeMode.light, ThemeMode.dark]) {
          await appearance.setMode(mode);
          await scrollHome();
          if (stage != 'before') {
            final card = tester.getRect(hero);
            final track = tester.getRect(rail);
            if (narrow) {
              expect(track.top, greaterThan(card.bottom));
            } else {
              expect(track.left, greaterThan(card.right));
            }
            expect(
              tester.getTopLeft(find.text('最近添加')).dy,
              lessThan(tester.getTopLeft(find.text('我的媒体库')).dy),
            );
            await until(
              hasLocalThumbnail,
              'continue-watching uses a local thumbnail',
            );
          }
          final name = '${narrow ? 'narrow' : 'landscape'}-${mode.name}';
          await capture('$name-top');
          await scrollHome(bottom: true);
          if (stage != 'before') expectLastRowVisible();
          await capture('$name-bottom');
          if (stage != 'before') {
            for (final (index, ratio) in [
              (4, 2 / 3),
              (6, 2 / 3),
              (7, 16 / 9),
            ]) {
              final artwork = find.descendant(
                of: recentCard(videos[index]),
                matching: find.byType(AspectRatio),
              );
              final size = tester.getSize(artwork);
              expect(size.width / size.height, closeTo(ratio, 0.001));
            }
            await until(
              () =>
                  recentImage(videos[4], 'bangumi-cover-899.img') != null &&
                  recentImage(videos[7], '/thumbnails-v1/') != null,
              'recent posters and video frames are ready',
            );
            await Scrollable.ensureVisible(
              tester.element(find.text('最近添加')),
              alignment: 0.07,
            );
            await capture('$name-recent');
          }
        }
      }
      tester.view.physicalSize = landscape * tester.view.devicePixelRatio;
      await appearance.setMode(ThemeMode.light);
      await scrollHome();
      final navSurface = find
          .descendant(
            of: find.byType(LibraryTabBar),
            matching: find.byType(GlassSurface),
          )
          .first;
      final homeNavRect = tester.getRect(navSurface);
      final nav = homeNavRect.size;
      observations['navigationSize'] = [nav.width, nav.height];
      if (stage != 'before') {
        await until(
          () => [
            3,
            7,
          ].every((i) => recentImage(videos[i], '/thumbnails-v1/') != null),
          'local file and broken movie cover use video frames',
        );
        expect(recentImage(videos[6], 'bangumi-cover-101.img'), isNotNull);
        expect(recentImage(videos[6], '/thumbnails-v1/'), isNull);
        expect(
          tester
              .widgetList<Image>(
                find.descendant(of: hero, matching: find.byType(Image)),
              )
              .map(imageFilePath),
          contains(recentImage(videos[6], 'bangumi-cover-101.img')),
        );
        expect(recentImage(videos[4], 'bangumi-cover-899.img'), isNotNull);
        expect(recentImage(videos[4], '/thumbnails-v1/'), isNull);
        expect(recentCard(videos[4]), findsOneWidget);
        expect(recentCard(videos[5]), findsOneWidget);
        expect(recentKey(videos[4]), recentKey(videos[5]));
        expect(find.textContaining('已收录 3 个视频'), findsOneWidget);
        expect(find.textContaining('已收录 2 个视频'), findsOneWidget);
        final poster = find.descendant(
          of: recentCard(videos[4]),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Image &&
                imageFilePath(widget)?.contains('bangumi-cover-899.img') ==
                    true,
          ),
        );
        expect(tester.widget<Image>(poster).fit, BoxFit.cover);
        observations['recentMixedArtwork'] = true;
        final card = tester.getSize(hero);
        expect(covers, findsWidgets);
        expect(
          tester
              .widgetList<Image>(covers)
              .every((image) => image.fit == BoxFit.contain),
          isTrue,
        );
        expect(card.height, inInclusiveRange(210, 240));
        expect(nav.height, lessThan(52));
        expect(find.byType(BackdropFilter), findsNothing);
        observations['resumeCardSize'] = [card.width, card.height];
        observations['localResumeThumbnail'] = hasLocalThumbnail();
        await tester.tap(find.byTooltip('打开本地视频'));
        await tester.pump(const Duration(milliseconds: 450));
        expect(files.pickerCalls, 1);
        await tester.tap(find.byTooltip('搜索媒体库'));
        await tester.pump(const Duration(milliseconds: 450));
        expect(find.byType(TextFormField), findsWidgets);
        expect(tester.getRect(navSurface), homeNavRect);
        await tester.tap(find.byKey(const ValueKey('tab-0')));
        await tester.pump(const Duration(milliseconds: 450));
        await scrollHome();
        await tester.tap(find.widgetWithText(TextButton, '播放记录'));
        await tester.pump(const Duration(milliseconds: 450));
        expect(find.text('最近播放'), findsOneWidget);
        expect(tester.getRect(navSurface), homeNavRect);
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
        expect(tester.getRect(navSurface), homeNavRect);
        observations['navigationStableAcrossTabs'] = true;
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
        expect(session.media?.resumeKey, videos[resumeIndex].resumeKey);
        expect(created, 1);
        await session.pauseForInterruption();
        await tester.tap(find.byTooltip('返回首页'));
        await tester.pump(const Duration(milliseconds: 450));
        await scrollHome();
        final workCard = recentCard(videos[4]);
        await Scrollable.ensureVisible(
          tester.element(workCard),
          alignment: 0.25,
        );
        await tester.pump(const Duration(milliseconds: 450));
        await tester.tap(workCard);
        await tester.pump(const Duration(milliseconds: 450));
        final episode = find.byKey(ValueKey(videos[4].resumeKey));
        final secondEpisode = find.byKey(ValueKey(videos[5].resumeKey));
        expect(episode, findsOneWidget);
        expect(secondEpisode, findsOneWidget);
        await until(
          () => [episode, secondEpisode].every(
            (row) => tester
                .widgetList<Image>(
                  find.descendant(of: row, matching: find.byType(Image)),
                )
                .any(
                  (image) =>
                      imageFilePath(image)?.contains('/thumbnails-v1/') ??
                      false,
                ),
          ),
          'work detail shows local frames for both episodes',
        );
        await capture('work-detail');
        await tester.ensureVisible(episode);
        await tester.tap(episode);
        await until(
          () =>
              session.ready &&
              session.media?.resumeKey == videos[4].resumeKey &&
              session.frame.duration.inSeconds > 10,
          'first episode plays from the work',
        );
        expect(session.playlist.map((media) => media.resumeKey), [
          videos[4].resumeKey,
          videos[5].resumeKey,
        ]);
        final openingNext = session.next();
        await until(
          () =>
              session.ready && session.media?.resumeKey == videos[5].resumeKey,
          'next episode plays from the work queue',
        );
        await openingNext;
        await tester.tap(find.byTooltip('返回首页'));
        await tester.pump(const Duration(milliseconds: 450));
        await tester.tap(find.byType(BackButton));
        await tester.pump(const Duration(milliseconds: 450));
        await scrollHome();
        observations['recentWorkDetail'] = true;
        expect(created, 3);
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
