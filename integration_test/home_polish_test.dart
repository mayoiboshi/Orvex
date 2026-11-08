import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:orvex/app/orvex_app.dart';
import 'package:orvex/design/appearance_controller.dart';
import 'package:orvex/design/glass.dart';
import 'package:orvex/features/anime_metadata/application/anime_metadata_controller.dart';
import 'package:orvex/features/anime_metadata/domain/anime_subject.dart';
import 'package:orvex/features/anime_metadata/infrastructure/metadata_store.dart';
import 'package:orvex/features/folder_library/folder_library.dart';
import 'package:orvex/features/library/domain/library_overview.dart';
import 'package:orvex/features/library/infrastructure/playback_history_store.dart';
import 'package:orvex/features/library/presentation/library_views.dart';
import 'package:orvex/features/media_sources/imported_file_store.dart';
import 'package:orvex/features/media_sources/local_file_source.dart';
import 'package:orvex/features/player/application/playback_session.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:orvex/features/player/infrastructure/media_kit_engine.dart';
import 'package:orvex/features/player/infrastructure/preferences_resume_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _Files extends LocalFileSource {
  _Files(ImportedFileStore store) : super(imports: store);
  int pickerCalls = 0;
  Completer<XFile?>? pendingSelection;
  @override
  Future<LocalMedia?> pickVideo({
    void Function(VideoImportProgress)? onProgress,
  }) async {
    pickerCalls++;
    final source = await pendingSelection?.future;
    if (source == null) return null;
    onProgress?.call((
      phase: VideoImportPhase.preparing,
      name: source.name,
      fraction: null,
    ));
    return imports.import(source, onProgress: onProgress);
  }
}

class _PausedCopy extends XFile {
  _PausedCopy(super.path, this.bytes, this.finish) : super(name: '模拟器导入样片.mp4');
  final Uint8List bytes;
  final Future<void> finish;

  @override
  Stream<Uint8List> openRead([int? start, int? end]) async* {
    final middle = bytes.length ~/ 2;
    yield Uint8List.sublistView(bytes, 0, middle);
    await finish;
    yield Uint8List.sublistView(bytes, middle);
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
    final alternate = File(
      '${Directory.systemTemp.path}/orvex-visual-library/history-episode.mp4',
    );
    final videos = <LocalMedia>[];
    for (var i = 0; i < 8; i++) {
      final title = i < 4 ? '葬送的芙莉莲' : '名侦探柯南';
      final episode = i < 4 ? i + 1 : i + 611;
      final filename = stage == 'before'
          ? '$title - $episode.mp4'
          : switch (i) {
              3 => '封面损坏测试样片.mp4',
              6 => '电影测试样片.mp4',
              7 => '普通本地样片.mp4',
              _ => '$title - $episode.mp4',
            };
      final relative = 'Imports/home-$i/$filename';
      final file = File('${root.path}/documents/$relative');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(
        i == 5 && await alternate.exists()
            ? await alternate.readAsBytes()
            : source.buffer.asUint8List(),
      );
      videos.add(
        LocalMedia(uri: file.uri, name: filename, importPath: relative),
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
    const longTitle = '封面损坏测试样片：需要跨两行显示的超长作品名称';
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
          date: '2026-01-22',
          score: 8.0,
        ),
        3 => const AnimeSubject(
          id: 102,
          name: '封面损坏测试样片',
          nameCn: longTitle,
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
    final navSurface = find
        .descendant(
          of: find.byType(LibraryTabBar),
          matching: find.byType(GlassSurface),
        )
        .first;
    ScrollPosition homePosition() => tester
        .state<ScrollableState>(
          find.descendant(of: home, matching: find.byType(Scrollable)).first,
        )
        .position;
    Future<void> scrollHome({bool bottom = false}) async {
      final position = homePosition();
      position.jumpTo(bottom ? position.maxScrollExtent : 0);
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
          expect(recentCard(media).hitTestable(), findsOneWidget);
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
            final panel =
                tester
                        .widget<DecoratedBox>(
                          find
                              .descendant(
                                of: navSurface,
                                matching: find.byType(DecoratedBox),
                              )
                              .first,
                        )
                        .decoration
                    as BoxDecoration;
            expect(panel.color?.a, 1);
            if (narrow) {
              final poster = find.descendant(
                of: recentCard(videos[4]),
                matching: find.byType(AspectRatio),
              );
              final position = homePosition();
              final overlapOffset =
                  position.pixels +
                  tester.getCenter(poster).dy -
                  tester.getCenter(navSurface).dy;
              position.jumpTo(
                overlapOffset.clamp(0.0, position.maxScrollExtent),
              );
              await tester.pump(const Duration(milliseconds: 450));
              expect(
                tester.getRect(poster).overlaps(tester.getRect(navSurface)),
                isTrue,
              );
              await capture('$name-nav-over-poster');
            }
          }
        }
      }
      tester.view.physicalSize = landscape * tester.view.devicePixelRatio;
      await appearance.setMode(ThemeMode.light);
      await scrollHome();
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
          find.descendant(
            of: recentCard(videos[6]),
            matching: find.text('2026 · ★ 8.0'),
          ),
          findsOneWidget,
        );
        for (final index in [0, 4, 6]) {
          expect(
            find.descendant(
              of: recentCard(videos[index]),
              matching: find.textContaining('Bangumi'),
            ),
            findsNothing,
          );
        }
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
        Future<void> tapLibrary(Finder target) async {
          await tester.tap(target);
          await tester.pump(const Duration(milliseconds: 450));
        }

        expect(find.text('类型未分类'), findsOneWidget);
        expect(find.text('资料未匹配'), findsOneWidget);
        expect(find.text('已收录 1 个视频'), findsNWidgets(3));
        expect(find.text('海报网格'), findsOneWidget);
        Finder libraryCard(int index) => find.byKey(
          ValueKey('series-${folders.identityFor(videos[index]).key}'),
        );
        final longCard = libraryCard(3);
        final singleFile = libraryCard(6);
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: longCard, matching: find.text(longTitle)),
        );
        final lines = paragraph
            .getBoxesForSelection(
              const TextSelection(
                baseOffset: 0,
                extentOffset: longTitle.length,
              ),
            )
            .map((box) => box.top)
            .toSet();
        expect(lines, hasLength(2));
        double countBaseline(Finder card) => tester
            .getTopLeft(
              find.descendant(of: card, matching: find.text('已收录 1 个视频')),
            )
            .dy;
        expect(countBaseline(longCard), countBaseline(singleFile));
        final info = find.descendant(
          of: find.byKey(const PageStorageKey('series-overview')),
          matching: find.byType(PosterInfoButton),
        );
        expect(info, findsNWidgets(5));
        for (final button in info.evaluate()) {
          final size = (button.findRenderObject()! as RenderBox).size;
          expect(size.width, greaterThanOrEqualTo(44));
          expect(size.height, greaterThanOrEqualTo(44));
        }
        await capture('library-default-light');
        for (final index in [4, 6]) {
          final mediaBefore = session.media;
          await tapLibrary(
            find.descendant(
              of: libraryCard(index),
              matching: find.byType(PosterInfoButton),
            ),
          );
          expect(find.byTooltip('关闭番剧资料'), findsOneWidget);
          expect(find.byTooltip('返回剧集'), findsNothing);
          expect(session.media, same(mediaBefore));
          await tapLibrary(find.byTooltip('关闭番剧资料'));
        }
        final sort = find.byKey(const ValueKey('library-sort'));
        await tapLibrary(sort);
        final selectedSort = find.widgetWithText(
          PopupMenuItem<LibrarySortField>,
          '最近添加',
        );
        expect(
          tester.getTopLeft(selectedSort).dy,
          greaterThan(tester.getBottomLeft(sort).dy),
        );
        expect(
          find.descendant(
            of: selectedSort,
            matching: find.byIcon(Icons.check_rounded),
          ),
          findsOneWidget,
        );
        await capture('library-sort-menu');
        await tester.tapAt(tester.getCenter(libraryCard(0)));
        await tester.pumpAndSettle();
        expect(selectedSort, findsNothing);
        expect(find.byTooltip('返回剧集'), findsNothing);
        expect(session.media, isNull);
        await tapLibrary(sort);
        await tapLibrary(
          find.widgetWithText(PopupMenuItem<LibrarySortField>, '发行年份'),
        );
        await tapLibrary(find.byTooltip('当前降序，切换升序'));
        expect(
          await SharedPreferencesAsync().getString('orvex.library.sort.v1'),
          'year:asc',
        );
        await tapLibrary(find.byKey(const ValueKey('library-filter')));
        await capture('library-filter-menu');
        await tapLibrary(find.widgetWithText(PopupMenuItem<LibraryKind>, '剧集'));
        expect(find.byTooltip('重置筛选'), findsOneWidget);
        expect(find.text('电影测试样片'), findsNothing);
        expect(find.text('当前结果 · 2 部作品 · 5 个视频'), findsOneWidget);
        await capture('library-filtered');
        await tester.enterText(find.byType(TextFormField).first, '615');
        await tester.pump(const Duration(milliseconds: 450));
        expect(find.text('名侦探柯南'), findsOneWidget);
        expect(find.text('葬送的芙莉莲'), findsNothing);
        await tester.enterText(find.byType(TextFormField).first, '');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump(const Duration(milliseconds: 500));
        await tapLibrary(find.byTooltip('重置筛选'));
        await tapLibrary(find.byTooltip('切换紧凑列表'));
        expect(find.text('紧凑列表'), findsOneWidget);
        expect(
          find.descendant(of: singleFile, matching: find.text('类型未分类')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: singleFile, matching: find.text('已收录 1 个视频')),
          findsOneWidget,
        );
        await capture('library-list');
        final work = find.text('葬送的芙莉莲').hitTestable();
        expect(work, findsOneWidget);
        await tapLibrary(work);
        expect(find.byTooltip('番剧资料'), findsWidgets);
        await tapLibrary(find.byTooltip('返回剧集'));
        await until(
          () => find.byTooltip('切换海报网格').hitTestable().evaluate().isNotEmpty,
          'returned to the library',
        );
        await tapLibrary(find.byTooltip('切换海报网格'));
        expect(find.byTooltip('切换紧凑列表'), findsOneWidget);
        await tapLibrary(find.byKey(const ValueKey('folders-view')));
        expect(find.text('搜索已导入的视频'), findsOneWidget);
        expect(find.text('独立导入'), findsOneWidget);
        expect(find.text('8 个视频'), findsOneWidget);
        await capture('library-folders-light');
        await tapLibrary(find.byKey(const ValueKey('series-view')));

        final copy = Completer<void>();
        files.pendingSelection = Completer<XFile?>();
        await tapLibrary(find.byTooltip('导入单个视频'));
        expect(find.text('正在准备'), findsNothing);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        final sample = File('${root.path}/import-sample.mp4');
        final bytes = source.buffer.asUint8List();
        await sample.writeAsBytes(bytes);
        files.pendingSelection!.complete(
          _PausedCopy(sample.path, bytes, copy.future),
        );
        files.pendingSelection = null;
        await until(
          () => find.textContaining('正在复制 ·').evaluate().isNotEmpty,
          'measured copy progress',
        );
        try {
          await capture('library-import');
        } finally {
          copy.complete();
        }
        await until(
          () => find.text('已在媒体库中').evaluate().isNotEmpty,
          'duplicate import reused',
        );
        await tapLibrary(find.widgetWithText(TextButton, '关闭'));

        await appearance.setMode(ThemeMode.dark);
        await capture('library-dark');
        await tapLibrary(find.byKey(const ValueKey('folders-view')));
        await capture('library-folders-dark');
        await tapLibrary(find.byKey(const ValueKey('series-view')));
        tester.view.physicalSize =
            Size(landscape.height, landscape.width) *
            tester.view.devicePixelRatio;
        await capture('library-portrait');
        tester.view.physicalSize =
            Size(438, landscape.height) * tester.view.devicePixelRatio;
        await capture('library-narrow');
        await tapLibrary(find.byKey(const ValueKey('library-filter')));
        final menuOption = find.widgetWithText(
          PopupMenuItem<LibraryKind>,
          '类型未分类',
        );
        final menuBounds = tester.getRect(menuOption);
        expect(menuBounds.left, greaterThanOrEqualTo(0));
        expect(menuBounds.right, lessThanOrEqualTo(438));
        expect(menuBounds.bottom, lessThanOrEqualTo(landscape.height));
        await capture('library-narrow-filter-menu');
        await tapLibrary(
          find.widgetWithText(PopupMenuItem<LibraryKind>, '类型未分类'),
        );
        expect(find.text('当前结果 · 2 项媒体 · 2 个视频'), findsOneWidget);
        expect(singleFile, findsOneWidget);
        expect(find.text('类型未分类'), findsNWidgets(2));
        await capture('library-narrow-filtered');
        await tapLibrary(find.byTooltip('重置筛选'));
        final libraryScroll = tester
            .state<ScrollableState>(
              find
                  .descendant(
                    of: find.byKey(const PageStorageKey('series-overview')),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            )
            .position;
        libraryScroll.jumpTo(libraryScroll.maxScrollExtent);
        await tester.pump(const Duration(milliseconds: 450));
        expect(
          tester
              .getBottomLeft(
                find
                    .byKey(
                      ValueKey('series-${folders.identityFor(videos[7]).key}'),
                    )
                    .hitTestable(),
              )
              .dy,
          lessThan(tester.getTopLeft(navSurface).dy),
        );
        await capture('library-bottom');
        tester.view.physicalSize = landscape * tester.view.devicePixelRatio;
        await appearance.setMode(ThemeMode.light);
        await tester.pump(const Duration(milliseconds: 450));
        observations['libraryControlsAndImport'] = true;
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
        final librarySearchBounds = tester.getRect(
          find.descendant(
            of: find.byKey(const PageStorageKey('series-overview')),
            matching: find.byType(TextFormField),
          ),
        );
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
        final settingsPage = find.byKey(const PageStorageKey('library-tab-3'));
        final themePicker = find.byKey(const ValueKey('theme-picker'));
        final settingsBrand = find.descendant(
          of: settingsPage,
          matching: find.byType(OrvexBrand),
        );
        Future<void> checkSettingsLicenses({
          required Finder bottomOverlay,
          required String screenshot,
        }) async {
          ScrollPosition position() => tester
              .state<ScrollableState>(
                find
                    .descendant(
                      of: settingsPage,
                      matching: find.byType(Scrollable),
                    )
                    .first,
              )
              .position;
          final scroll = position();
          scroll.jumpTo(scroll.maxScrollExtent);
          await tester.pump(const Duration(milliseconds: 450));
          final licenseRow = find.widgetWithText(ListTile, '开源许可');
          final bounds = tester.getRect(licenseRow);
          expect(bounds.top, greaterThan(tester.getRect(settingsPage).top));
          expect(bounds.bottom, lessThan(tester.getRect(bottomOverlay).top));
          await capture(screenshot);
          await tester.tap(licenseRow.hitTestable());
          await tester.pump(const Duration(milliseconds: 450));
          final licensePage = find.byType(LicensePage);
          expect(licensePage, findsOneWidget);
          Navigator.of(tester.element(licensePage)).pop();
          await tester.pump(const Duration(milliseconds: 450));
          position().jumpTo(0);
          await tester.pump(const Duration(milliseconds: 450));
        }

        expect(
          tester.getTopLeft(settingsBrand).dx,
          closeTo(librarySearchBounds.left, .01),
        );
        final settingsFormBounds = tester.getRect(themePicker);
        expect(settingsFormBounds.left, closeTo(librarySearchBounds.left, .01));
        expect(
          settingsFormBounds.right,
          closeTo(librarySearchBounds.right, .01),
        );
        final settingsCards = find.descendant(
          of: settingsPage,
          matching: find.byType(GlassSurface),
        );
        expect(settingsCards, findsNWidgets(4));
        for (var i = 0; i < 4; i++) {
          final card = tester.getRect(settingsCards.at(i));
          expect(card.left, closeTo(settingsFormBounds.left, .01));
          expect(card.width, closeTo(settingsFormBounds.width, .01));
        }
        expect(find.text('导入本地视频'), findsNothing);
        final version = (await PackageInfo.fromPlatform()).version;
        await until(
          () => find.text('版本 $version').evaluate().isNotEmpty,
          'installed version',
        );
        await capture('library-settings-light');
        await tester.tap(themePicker);
        await tester.pump(const Duration(milliseconds: 450));
        expect(
          tester
              .widget<CheckedPopupMenuItem<ThemeMode>>(
                find.byKey(const ValueKey('theme-light')),
              )
              .checked,
          isTrue,
        );
        await capture('library-settings-theme');
        await tester.tap(find.byKey(const ValueKey('theme-dark')));
        await capture('library-settings-dark');
        expect(appearance.mode, ThemeMode.dark);
        expect(find.byTooltip('展开播放器'), findsNothing);
        await checkSettingsLicenses(
          bottomOverlay: navSurface,
          screenshot: 'library-settings-landscape-bottom',
        );
        await appearance.setMode(ThemeMode.light);
        await tester.pump(const Duration(milliseconds: 450));
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
        await tester.tap(find.byKey(const ValueKey('tab-1')));
        await tester.pump(const Duration(milliseconds: 500));
        final mini = find.byKey(const ValueKey('mini-playback-card'));
        expect(mini, findsOneWidget);
        expect(tester.getRect(navSurface), homeNavRect);
        expect(
          find.descendant(of: mini, matching: find.text('名侦探柯南 · 第 616 集')),
          findsOneWidget,
        );
        await until(
          () => tester
              .widgetList<Image>(
                find.descendant(of: mini, matching: find.byType(Image)),
              )
              .any(
                (image) =>
                    imageFilePath(image)?.contains('/thumbnails-v1/') ?? false,
              ),
          'mini player reuses the cached local thumbnail',
        );
        await tester.tap(find.byKey(const ValueKey('folders-view')));
        await tester.pump(const Duration(milliseconds: 500));
        await capture('library-mini-folders-light');
        final miniEngine = session.engine;
        final pausedAt = session.frame.position;
        await tester.tap(find.byTooltip('播放视频'));
        await until(
          () => session.frame.playing && session.frame.position > pausedAt,
          'mini player resumes the same native session',
        );
        expect(mini, findsOneWidget);
        await tester.tap(find.byTooltip('暂停视频'));
        await until(() => !session.frame.playing, 'mini player pauses');
        await appearance.setMode(ThemeMode.dark);
        tester.view.physicalSize =
            Size(438, landscape.height) * tester.view.devicePixelRatio;
        await capture('library-mini-folders-narrow-dark');
        // Sample after pause-related native frame events have settled.
        final resumedAt = session.frame.position;
        await tester.tap(find.byTooltip('展开播放器'));
        await tester.pump(const Duration(milliseconds: 500));
        expect(session.engine, same(miniEngine));
        expect(session.media?.resumeKey, videos[5].resumeKey);
        expect(session.frame.position, resumedAt);
        expect(session.frame.playing, isFalse);
        expect(find.byTooltip('返回首页'), findsOneWidget);
        expect(mini, findsNothing);
        await tester.tap(find.byTooltip('返回首页'));
        await tester.pump(const Duration(milliseconds: 500));
        final folderScroll = find
            .descendant(
              of: find.byKey(const PageStorageKey('folder-library')),
              matching: find.byType(Scrollable),
            )
            .first;
        final position = tester.state<ScrollableState>(folderScroll).position;
        position.jumpTo(position.maxScrollExtent);
        await tester.pump(const Duration(milliseconds: 450));
        final lastMedia = (await store.listVideos()).last;
        final lastRow = find.byKey(ValueKey(lastMedia.resumeKey)).hitTestable();
        expect(lastRow, findsOneWidget);
        expect(
          tester.getBottomLeft(lastRow).dy,
          lessThan(tester.getTopLeft(mini).dy),
        );
        await tester.tap(
          find
              .descendant(of: lastRow, matching: find.byTooltip('番剧资料'))
              .hitTestable(),
        );
        await tester.pump(const Duration(milliseconds: 450));
        expect(find.byTooltip('关闭番剧资料'), findsOneWidget);
        await tester.tap(find.byTooltip('关闭番剧资料'));
        await tester.pump(const Duration(milliseconds: 450));
        await capture('library-mini-last-row');
        await tester.tap(lastRow);
        await until(
          () =>
              session.ready &&
              session.media?.resumeKey == lastMedia.resumeKey &&
              session.frame.duration.inSeconds > 10,
          'last folder row starts native playback above the mini player',
        );
        observations['miniPlaybackUsesNativeSession'] = true;
        await session.pauseForInterruption();
        await tester.tap(find.byTooltip('返回首页'));
        await tester.pump(const Duration(milliseconds: 500));
        for (final (i, frame) in [
          (
            6,
            const PlaybackFrame(
              position: Duration(hours: 1, minutes: 14),
              duration: Duration(hours: 2, minutes: 22),
            ),
          ),
          (
            1,
            const PlaybackFrame(
              position: Duration(seconds: 18),
              duration: Duration(seconds: 18),
              completed: true,
            ),
          ),
          (
            4,
            const PlaybackFrame(
              position: Duration(seconds: 6),
              duration: Duration(seconds: 18),
            ),
          ),
          (
            5,
            const PlaybackFrame(
              position: Duration(seconds: 8),
              duration: Duration(seconds: 18),
            ),
          ),
        ]) {
          await history.record(videos[i], frame);
        }
        await resume.write(videos[5].resumeKey, const Duration(seconds: 8));
        tester.view.physicalSize = landscape * tester.view.devicePixelRatio;
        await tester.tap(find.byKey(const ValueKey('tab-2')));
        await tester.pump(const Duration(milliseconds: 500));
        final refreshed = tester
            .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
            .show();
        await tester.pump(const Duration(milliseconds: 500));
        await refreshed;
        await tester.pump(const Duration(milliseconds: 450));
        final historyScroll = find
            .descendant(
              of: find.byKey(const PageStorageKey('library-tab-2')),
              matching: find.byType(Scrollable),
            )
            .first;
        ScrollPosition historyPosition() =>
            tester.state<ScrollableState>(historyScroll).position;
        historyPosition().jumpTo(0);
        await tester.pump(const Duration(milliseconds: 450));
        final firstRow = find.byKey(ValueKey(videos[5].resumeKey));
        final secondRow = find.byKey(ValueKey(videos[4].resumeKey));
        String? thumbnail(Finder row) => tester
            .widgetList<Image>(
              find.descendant(of: row, matching: find.byType(Image)),
            )
            .map(imageFilePath)
            .whereType<String>()
            .where((path) => path.contains('/thumbnails-v1/'))
            .firstOrNull;
        await until(
          () => [firstRow, secondRow].every((row) {
            final path = thumbnail(row);
            return path != null && path.isNotEmpty;
          }),
          'history rows show independent cached video frames',
        );
        expect(thumbnail(firstRow), isNot(thumbnail(secondRow)));
        expect(
          tester.getTopLeft(firstRow).dy,
          lessThan(tester.getTopLeft(secondRow).dy),
        );
        expect(find.text('已看完 · 00:18 / 00:18'), findsOneWidget);
        expect(find.text('未看完 · 1:14:00 / 2:22:00'), findsOneWidget);
        expect(find.byTooltip('打开本地视频'), findsNothing);
        final progress = find.descendant(
          of: firstRow,
          matching: find.byType(LinearProgressIndicator),
        );
        final art = find.descendant(
          of: firstRow,
          matching: find.byType(LocalVideoArtwork),
        );
        expect(tester.getSize(progress).width, tester.getSize(art).width);
        expect(
          tester.widget<LinearProgressIndicator>(progress).value,
          closeTo(8 / 18, .001),
        );
        final historyBefore = await history.list();

        Future<void> compareBrowseEdges(Size size, {String? screenshot}) async {
          tester.view.physicalSize = size * tester.view.devicePixelRatio;
          await tester.pump(const Duration(milliseconds: 450));
          historyPosition().jumpTo(0);
          await tester.pump(const Duration(milliseconds: 450));
          final historyPage = find.byKey(const PageStorageKey('library-tab-2'));
          final row = tester.getRect(firstRow);
          final historyBrand = tester.getTopLeft(
            find.descendant(of: historyPage, matching: find.byType(OrvexBrand)),
          );
          final historyTitle = tester.getTopLeft(
            find.descendant(of: historyPage, matching: find.text('播放记录')),
          );
          expect(
            tester.getTopLeft(find.text('最近播放')).dx,
            closeTo(row.left, .01),
          );
          expect(
            tester.getTopRight(find.text('${historyBefore.length} 条记录')).dx,
            closeTo(row.right, .01),
          );
          final historyNav = tester.getRect(navSurface);
          final historyMini = tester.getRect(mini);
          if (screenshot != null) {
            await capture('library-inset-history-$screenshot');
          }

          await tester.tap(find.byKey(const ValueKey('tab-1')));
          await tester.pump(const Duration(milliseconds: 500));
          final overview = find.byKey(const PageStorageKey('series-overview'));
          final overviewScroll = find
              .descendant(of: overview, matching: find.byType(Scrollable))
              .first;
          tester.state<ScrollableState>(overviewScroll).position.jumpTo(0);
          await tester.pump(const Duration(milliseconds: 450));
          final field = tester.getRect(
            find.descendant(of: overview, matching: find.byType(TextFormField)),
          );
          final libraryBrand = tester.getTopLeft(
            find.descendant(of: overview, matching: find.byType(OrvexBrand)),
          );
          final libraryTitle = tester.getTopLeft(
            find.descendant(of: overview, matching: find.text('媒体库')),
          );
          expect(historyBrand.dx, closeTo(libraryBrand.dx, .01));
          expect(historyTitle.dx, closeTo(libraryTitle.dx, .01));
          expect(row.left, closeTo(field.left, .01));
          expect(row.right, closeTo(field.right, .01));
          expect(tester.getRect(navSurface), historyNav);
          expect(tester.getRect(mini), historyMini);
          if (screenshot != null) {
            await capture('library-inset-library-$screenshot');
          }
          await tester.tap(find.byKey(const ValueKey('tab-2')));
          await tester.pump(const Duration(milliseconds: 500));
        }

        await compareBrowseEdges(landscape, screenshot: 'landscape');
        await compareBrowseEdges(Size(landscape.height, landscape.width));
        await compareBrowseEdges(
          Size(438, landscape.height),
          screenshot: 'narrow',
        );
        tester.view.physicalSize = landscape * tester.view.devicePixelRatio;
        await tester.pump(const Duration(milliseconds: 450));
        observations['historyBrowseInsetsAligned'] = true;
        await capture('library-history-dark');
        await appearance.setMode(ThemeMode.light);
        await capture('library-history-light');
        expect(
          (await history.list()).first.updatedAt,
          historyBefore.first.updatedAt,
        );
        tester.view.physicalSize =
            Size(438, landscape.height) * tester.view.devicePixelRatio;
        await tester.pump(const Duration(milliseconds: 450));
        final narrowPosition = historyPosition();
        narrowPosition.jumpTo(narrowPosition.maxScrollExtent);
        await tester.pump(const Duration(milliseconds: 450));
        final bottomRecord = find.byKey(
          ValueKey(historyBefore.last.media.resumeKey),
        );
        expect(
          tester.getBottomLeft(bottomRecord).dy,
          lessThan(tester.getTopLeft(mini).dy),
        );
        expect(
          find
              .descendant(of: bottomRecord, matching: find.byType(IconButton))
              .hitTestable(),
          findsOneWidget,
        );
        await capture('library-history-narrow-bottom');
        historyPosition().jumpTo(0);
        await tester.pump(const Duration(milliseconds: 450));
        final createdBefore = created;
        await tester.tap(
          find.descendant(of: firstRow, matching: find.byTooltip('继续播放')),
        );
        await until(
          () =>
              session.ready &&
              session.media?.resumeKey == videos[5].resumeKey &&
              session.frame.duration.inSeconds > 10 &&
              session.frame.position.inSeconds >= 8,
          'history resumes the exact file at its stored position',
        );
        expect(created, createdBefore + 1);
        await tester.tap(find.byTooltip('返回首页'));
        await tester.pump(const Duration(milliseconds: 550));
        expect(
          find.descendant(of: mini, matching: find.text('名侦探柯南 · 第 616 集')),
          findsOneWidget,
        );
        observations['historyNativeResume'] = true;
        final settingsEngine = session.engine;
        final settingsPosition = session.frame.position;
        final checkpoint = (await history.list()).firstWhere(
          (record) => record.media.resumeKey == videos[5].resumeKey,
        );
        await tester.tap(find.byKey(const ValueKey('tab-3')));
        await tester.pump(const Duration(milliseconds: 450));
        final miniBounds = tester.getRect(mini);
        final narrowThemeBounds = tester.getRect(themePicker);
        final narrowPageBounds = tester.getRect(settingsPage);
        final narrowInset =
            tester.getTopLeft(settingsBrand).dx - narrowPageBounds.left;
        expect(
          narrowThemeBounds.left - narrowPageBounds.left,
          closeTo(narrowInset, .01),
        );
        expect(
          narrowPageBounds.right - narrowThemeBounds.right,
          closeTo(narrowInset, .01),
        );
        await tester.tap(find.widgetWithText(SwitchListTile, '显示继续观看'));
        await tester.pump(const Duration(milliseconds: 450));
        expect(
          await SharedPreferencesAsync().getBool('orvex.home.continue.v1'),
          isFalse,
        );
        await tester.tap(find.byKey(const ValueKey('tab-0')));
        await tester.pump(const Duration(milliseconds: 450));
        expect(find.text('继续观看'), findsNothing);
        expect(
          (await history.list())
              .firstWhere(
                (record) => record.media.resumeKey == videos[5].resumeKey,
              )
              .position,
          checkpoint.position,
        );
        expect(session.engine, same(settingsEngine));
        expect(session.frame.position, settingsPosition);
        await tester.tap(find.byKey(const ValueKey('tab-3')));
        await tester.pump(const Duration(milliseconds: 450));
        await tester.tap(find.widgetWithText(SwitchListTile, '显示继续观看'));
        await tester.pump(const Duration(milliseconds: 450));
        await appearance.setMode(ThemeMode.dark);
        await tester.pump(const Duration(milliseconds: 450));
        expect(tester.getRect(mini), miniBounds);
        await checkSettingsLicenses(
          bottomOverlay: mini,
          screenshot: 'library-settings-narrow-bottom',
        );
        final matchNote = find.textContaining('来源为 Bangumi。');
        final noteHeight = tester.getSize(matchNote).height;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        try {
          await tester.pump(const Duration(milliseconds: 450));
          expect(tester.getSize(matchNote).height, greaterThan(noteHeight));
          final note = tester.renderObject<RenderParagraph>(matchNote);
          final lineTops = note
              .getBoxesForSelection(
                TextSelection(
                  baseOffset: 0,
                  extentOffset: note.text.toPlainText().length,
                ),
              )
              .map((box) => box.top)
              .toSet();
          expect(lineTops.length, greaterThan(1));
          await checkSettingsLicenses(
            bottomOverlay: mini,
            screenshot: 'library-settings-narrow-large-text',
          );
        } finally {
          tester.platformDispatcher.clearTextScaleFactorTestValue();
        }
        observations['settingsPreservePlaybackAndLicenses'] = true;
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
