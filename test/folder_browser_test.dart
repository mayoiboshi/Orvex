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
