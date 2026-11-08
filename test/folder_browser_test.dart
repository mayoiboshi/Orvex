import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/design/orvex_theme.dart';
import 'package:orvex/features/anime_metadata/application/anime_metadata_controller.dart';
import 'package:orvex/features/folder_library/folder_access.dart';
import 'package:orvex/features/folder_library/folder_browser.dart';
import 'package:orvex/features/folder_library/folder_library.dart';
import 'package:orvex/features/folder_library/folder_models.dart';
import 'package:orvex/features/folder_library/thumbnail_cache.dart';
import 'package:orvex/features/library/domain/library_overview.dart';
import 'package:orvex/features/library/domain/playback_record.dart';
import 'package:orvex/features/library/presentation/series_library.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';

import 'support/fake_metadata.dart';

class _NoPreviewAccess extends FolderAccess {
  @override
  bool get native => false;
  @override
  Future<({Uint8List bytes, int duration})> thumbnail(
    FolderLease lease,
    String path,
  ) => throw UnsupportedError('Preview unavailable in widget test');
}

class _NoPreviewCache extends ThumbnailCache {
  _NoPreviewCache(super.library);
  @override
  ThumbnailRequest request(FolderEntry entry) {
    final request = ThumbnailRequest(entry)
      ..issue = 'Preview unavailable in widget test';
    request.completer.complete(null);
    return request;
  }
}

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('folder scope and unwatched controls in ${brightness.name}', (
      tester,
    ) async {
      final library = FolderLibrary(access: _NoPreviewAccess());
      final cache = _NoPreviewCache(library);
      final metadata = AnimeMetadataController(
        client: FakeBangumiClient(),
        store: MemoryMetadataStore(),
      );
      addTearDown(() {
        cache.dispose();
        library.dispose();
        metadata.dispose();
      });
      tester.view.physicalSize = const Size(438, 834);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = FolderRoot(
        id: 'source',
        name: '本地文件',
        grant: 'bookmark',
        location: 'file:///source/',
      )..scannedAt = DateTime.utc(2026);
      final rootVideos = List.generate(
        40,
        (index) => FolderEntry(
          id: 'video-$index',
          rootId: root.id,
          path: '视频-$index.mp4',
          directory: false,
        ),
      );
      final childVideo = FolderEntry(
        id: 'child-video',
        rootId: root.id,
        path: '子目录/子集.mp4',
        directory: false,
      );
      final history = [
        for (final entry in [rootVideos.first, childVideo])
          PlaybackRecord(
            media: entry.media,
            position: const Duration(seconds: 9),
            duration: const Duration(minutes: 1),
            updatedAt: DateTime.utc(2026),
          ),
      ];
      final opened = <LocalMedia>[];
      Widget app({
        List<LocalMedia> imported = const [],
        bool unavailable = false,
      }) => MaterialApp(
        theme: OrvexTheme.create(brightness),
        home: Scaffold(
          body: FolderBrowser(
            library: library,
            thumbnails: cache,
            imported: imported,
            importedUnavailable: unavailable,
            history: history,
            metadata: metadata,
            onOpen: opened.add,
            onImport: null,
            onMetadata: (_) {},
            libraryHeader: const SizedBox.shrink(),
            libraryInset: 18,
          ),
        ),
      );
      Future<void> tap(Finder target) async {
        await tester.tap(target);
        await tester.pumpAndSettle();
      }

      await tester.pumpWidget(app());
      expect(find.text('正在读取媒体…'), findsOneWidget);
      library.loading = false;
      library.changed();
      await tester.pump();
      expect(find.text('尚未添加媒体'), findsOneWidget);
      expect(find.text('选择媒体根目录 · 保留原文件'), findsOneWidget);
      await tester.pumpWidget(app(unavailable: true));
      expect(find.text('尚未添加媒体'), findsNothing);
      await tester.pumpWidget(app());

      library.roots.add(root);
      library.entries.addAll([
        ...rootVideos,
        FolderEntry(id: 'child', rootId: root.id, path: '子目录', directory: true),
        childVideo,
      ]);
      library.changed();
      await tester.pumpAndSettle();
      expect(find.text('媒体来源 · 1 个目录'), findsOneWidget);
      expect(find.text('41 个视频 · 已缓存目录'), findsOneWidget);
      expect(find.text('独立导入'), findsNothing);
      expect(find.text('这里还没有视频'), findsNothing);
      expect(find.text('选择媒体根目录 · 保留原文件'), findsNothing);
      await tap(find.text('本地文件'));

      final filter = find.widgetWithText(FilterChip, '仅未播放');
      expect(tester.widget<FilterChip>(filter).selected, isFalse);
      expect(find.text('1 个子文件夹 · 40 个视频'), findsOneWidget);
      expect(
        find.byKey(ValueKey(rootVideos.first.media.resumeKey)),
        findsOneWidget,
      );
      await tap(filter);
      expect(tester.widget<FilterChip>(filter).selected, isTrue);
      expect(find.text('1 个子文件夹 · 当前结果 · 39 个视频'), findsOneWidget);
      expect(
        find.byKey(ValueKey(rootVideos.first.media.resumeKey)),
        findsNothing,
      );
      await tester.enterText(find.byType(TextFormField), '没有这个文件');
      await tester.pumpAndSettle();
      expect(find.text('当前范围没有符合搜索的未播放视频'), findsOneWidget);
      await tap(find.text('清除筛选'));
      expect(find.text('当前范围没有符合搜索的视频'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), '');
      await tester.pumpAndSettle();
      await tap(filter);
      await tap(find.widgetWithText(ChoiceChip, '子目录'));
      expect(tester.widget<FilterChip>(filter).selected, isTrue);
      expect(find.text('当前范围没有未播放的视频'), findsOneWidget);
      await tap(find.text('清除筛选'));
      expect(tester.widget<FilterChip>(filter).selected, isFalse);
      await tap(find.byKey(ValueKey(childVideo.media.resumeKey)));
      expect(opened.single.resumeKey, childVideo.media.resumeKey);
      await tap(find.byTooltip('返回上一层目录'));
      expect(tester.widget<FilterChip>(filter).selected, isTrue);
      await tap(find.byTooltip('返回上一层目录'));
      expect(find.text('媒体来源 · 1 个目录'), findsOneWidget);
      expect(find.text('独立导入'), findsNothing);
      final imported = LocalMedia(
        uri: Uri.file('/test/独立视频.mp4'),
        name: '独立视频.mp4',
      );
      await tester.pumpWidget(app(imported: [imported]));
      await tester.pumpAndSettle();
      expect(find.text('媒体来源 · 1 个目录'), findsOneWidget);
      expect(find.text('独立导入'), findsOneWidget);
      expect(find.text('1 个视频'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'successful folder scans show a one-time toast above navigation',
    (tester) async {
      final (directory, library) = (await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'orvex-scan-toast-',
        );
        await File('${directory.path}/sample.mp4').create();
        return (
          directory,
          FolderLibrary(
            access: _NoPreviewAccess(),
            directory: () async => directory,
          ),
        );
      }))!;
      final cache = _NoPreviewCache(library);
      final metadata = AnimeMetadataController(
        client: FakeBangumiClient(),
        store: MemoryMetadataStore(),
      );
      final root = FolderRoot(
        id: 'toast',
        name: '本地文件',
        grant: directory.path,
        location: directory.uri.toString(),
      );
      library.roots.add(root);
      addTearDown(() async {
        cache.dispose();
        library.dispose();
        metadata.dispose();
        await directory.delete(recursive: true);
      });

      Widget app() => MaterialApp(
        theme: OrvexTheme.create(Brightness.dark),
        home: Scaffold(
          extendBody: true,
          bottomNavigationBar: const SizedBox(key: ValueKey('nav'), height: 60),
          body: SeriesLibrary(
            library: library,
            thumbnails: cache,
            imported: const [],
            history: const [],
            metadata: metadata,
            onOpen: (_) {},
            onImport: null,
            onMetadata: (_) {},
            arrivals: const {},
            sort: defaultLibrarySort,
            onSort: (_) {},
            compact: false,
            onCompact: (_) {},
            importStatus: null,
            onDismissImport: () {},
            onSelection: (_) {},
          ),
        ),
      );
      await tester.pumpWidget(app());
      await tester.tap(find.byKey(const ValueKey('folders-view')));
      await tester.pumpAndSettle();

      final toast = find.byType(SnackBar);
      for (var scan = 0; scan < 2; scan++) {
        await tester.runAsync(() => library.scan(root));
        await tester.pump();
        await tester.pumpAndSettle();
        expect(toast, findsOneWidget);
        expect(find.text('扫描完成 · 已读取 1 个目录 · 发现 1 个视频'), findsOneWidget);
        expect(find.text('关闭'), findsNothing);
        expect(
          tester.getBottomLeft(toast).dy,
          lessThanOrEqualTo(
            tester.getTopLeft(find.byKey(const ValueKey('nav'))).dy,
          ),
        );
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
        expect(toast, findsNothing);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(toast, findsNothing);

      root.grant = '${directory.path}/missing';
      await tester.runAsync(() => library.scan(root));
      await tester.pumpAndSettle();
      expect(find.text('扫描失败'), findsOneWidget);
      expect(toast, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'standalone folders keep navigation history and parent search on iOS edge back',
    (tester) async {
      late Directory directory;
      late FolderLibrary library;
      late ThumbnailCache cache;
      late AnimeMetadataController metadata;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('orvex-folder-back-');
        library = FolderLibrary(
          access: _NoPreviewAccess(),
          directory: () async => directory,
        );
        await library.initialize();
        library.roots.add(
          FolderRoot(
            id: 'root',
            name: '返回目录测试',
            grant: directory.path,
            location: directory.uri.toString(),
          ),
        );
        library.entries.addAll([
          FolderEntry(id: 'a', rootId: 'root', path: 'a', directory: true),
          FolderEntry(id: 'b', rootId: 'root', path: 'b', directory: true),
          FolderEntry(
            id: 'one',
            rootId: 'root',
            path: 'a/第1集.mp4',
            directory: false,
          ),
        ]);
        library.changed();
        cache = _NoPreviewCache(library);
        metadata = AnimeMetadataController(
          client: FakeBangumiClient(),
          store: MemoryMetadataStore(),
        );
      });
      addTearDown(() async {
        cache.dispose();
        library.dispose();
        metadata.dispose();
        await directory.delete(recursive: true);
      });
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: OrvexTheme.create(Brightness.light),
          home: Scaffold(
            body: FolderBrowser(
              library: library,
              thumbnails: cache,
              imported: const [],
              history: const [],
              metadata: metadata,
              onOpen: (_) {},
              onImport: () {},
              onMetadata: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('返回目录测试'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '保留筛选');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'a'));
      await tester.pumpAndSettle();
      expect(find.text('第1集'), findsOneWidget);
      await tester.dragFrom(const Offset(2, 400), const Offset(310, 0));
      await tester.pumpAndSettle();
      expect(find.text('保留筛选'), findsOneWidget);
      expect(find.text('第1集'), findsNothing);
      await tester.dragFrom(const Offset(2, 400), const Offset(310, 0));
      await tester.pumpAndSettle();
      expect(find.text('返回目录测试'), findsOneWidget);
      expect(find.byTooltip('返回上一层目录'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'large lazy folder playlist, location, browsing and text scaling $brightness',
      (tester) async {
        late Directory temporary;
        late FolderLibrary library;
        late ThumbnailCache cache;
        late AnimeMetadataController metadata;
        late LocalMedia current;
        await tester.runAsync(() async {
          temporary = await Directory.systemTemp.createTemp('orvex-folder-ui-');
          library = FolderLibrary(
            access: _NoPreviewAccess(),
            directory: () async => temporary,
          );
          await library.initialize();
          library.roots.add(
            FolderRoot(
              id: 'root',
              name: '任意作品',
              grant: temporary.path,
              location: temporary.uri.toString(),
            ),
          );
          library.entries.addAll([
            FolderEntry(id: 'a', rootId: 'root', path: 'a', directory: true),
            FolderEntry(id: 'b', rootId: 'root', path: 'b', directory: true),
            for (var i = 0; i < 1000; i++)
              FolderEntry(
                id: '$i',
                rootId: 'root',
                path: 'a/第$i集.mp4',
                directory: false,
              ),
          ]);
          library.changed();
          current = library.entries.singleWhere((e) => e.id == '500').media;
          cache = _NoPreviewCache(library);
          metadata = AnimeMetadataController(
            client: FakeBangumiClient(),
            store: MemoryMetadataStore(),
          );
        });
        addTearDown(() async {
          cache.dispose();
          library.dispose();
          metadata.dispose();
          await temporary.delete(recursive: true);
        });
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final opened = <LocalMedia>[];
        await tester.pumpWidget(
          MaterialApp(
            theme: OrvexTheme.create(brightness),
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(360, 800),
                textScaler: TextScaler.linear(1.7),
              ),
              child: Scaffold(
                body: FolderBrowser(
                  library: library,
                  thumbnails: cache,
                  imported: const [],
                  history: const [],
                  metadata: metadata,
                  onOpen: opened.add,
                  onImport: () {},
                  onMetadata: (_) {},
                  current: current,
                  header: const SizedBox(height: 100, child: Text('测试视频区域')),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('第500集'), findsOneWidget);
        expect(
          find.byType(InkWell).evaluate().length,
          lessThan(60),
          reason: '1000 videos must not build 1000 rows',
        );
        expect(
          opened,
          isEmpty,
          reason: 'Automatic location does not change playback',
        );
        final scroll = find.byType(CustomScrollView);
        final position = tester
            .widget<CustomScrollView>(scroll)
            .controller!
            .position;
        await tester.drag(scroll, Offset(0, position.pixels + 800));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ChoiceChip, 'b'));
        await tester.pumpAndSettle();
        expect(find.text('这里还没有视频'), findsOneWidget);
        expect(opened, isEmpty);
        await tester.tap(find.byTooltip('定位当前视频'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('第500集'));
        await tester.pump();
        expect(opened.single.resumeKey, current.resumeKey);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
