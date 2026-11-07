import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orvex/design/orvex_theme.dart';
import 'package:orvex/features/anime_metadata/application/anime_metadata_controller.dart';
import 'package:orvex/features/anime_metadata/infrastructure/metadata_store.dart';
import 'package:orvex/features/folder_library/folder_browser.dart';
import 'package:orvex/features/folder_library/folder_library.dart';
import 'package:orvex/features/folder_library/thumbnail_cache.dart';
import 'package:orvex/features/media_sources/imported_file_store.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'repeated imports reuse identity and actual native thumbnails appear in imported rows',
    (tester) async {
      expect(Platform.isIOS, isTrue, reason: 'iOS simulator experiment only');
      expect(
        await const MethodChannel('dev.orvex/audio-session')
            .invokeMethod<bool>('isSimulator'),
        isTrue,
        reason: 'Never import generated fixtures on physical devices',
      );
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
      final root = await Directory.systemTemp.createTemp(
        'orvex-import-preview-',
      );
      final originalPrefs = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      final imports = ImportedFileStore();
      final library = FolderLibrary(directory: () async => root);
      await library.initialize();
      final metadata = AnimeMetadataController(
        store: MetadataStore(directoryProvider: () async => root),
      );
      await metadata.initialize();
      await metadata.setAutomatic(false);
      final thumbnails = ThumbnailCache(library, imports: imports);
      final screen = GlobalKey();
      try {
        final bytes = await rootBundle.load('test/fixtures/generated.mp4');
        final source = await File('${root.path}/单集预览验证.mp4')
            .writeAsBytes(bytes.buffer.asUint8List());
        final first = await imports.import(XFile(source.path));
        final count = (await imports.listVideos()).length;
        final second = await ImportedFileStore().import(XFile(source.path));
        expect(second.resumeKey, first.resumeKey);
        expect(second.uri, first.uri);
        expect((await imports.listVideos()).length, count);
        final preview = thumbnails.requestImported(first);
        final file = await preview.result;
        expect(file, isNotNull, reason: preview.issue);
        expect(preview.duration, greaterThan(10000));
        final codec = await ui.instantiateImageCodec(await file!.readAsBytes());
        final frame = await codec.getNextFrame();
        expect(frame.image.width, greaterThan(100));
        expect(frame.image.height, greaterThan(60));
        frame.image.dispose();
        codec.dispose();
        final cached = thumbnails.requestImported(first);
        expect((await cached.result)?.path, file.path);
        expect(cached.duration, preview.duration);
        final opened = <LocalMedia>[];
        for (final brightness in [Brightness.light, Brightness.dark]) {
          await tester.pumpWidget(
            RepaintBoundary(
              key: screen,
              child: MaterialApp(
                theme: OrvexTheme.create(brightness),
                home: Scaffold(
                  body: SafeArea(
                    child: FolderBrowser(
                      library: library,
                      thumbnails: thumbnails,
                      imported: [first],
                      history: const [],
                      metadata: metadata,
                      onOpen: opened.add,
                      onImport: () {},
                      onMetadata: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          );
          final end = DateTime.now().add(const Duration(seconds: 20));
          while (find.byType(Image).evaluate().isEmpty &&
              DateTime.now().isBefore(end)) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          await tester.pumpAndSettle();
          expect(
            find.byType(Image),
            findsOneWidget,
            reason: 'Imported row must render its native extracted frame',
          );
          expect(tester.takeException(), isNull);
          final boundary =
              screen.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('${root.path}/imported-${brightness.name}.png')
              .writeAsBytes(png!.buffer.asUint8List());
          image.dispose();
        }
        await tester.tap(find.byType(Image));
        await tester.pump();
        expect(opened.single.resumeKey, first.resumeKey);
        await File('${root.path}/results.txt').writeAsString(
          'Repeated import and store restart: same stable identity, no additional video.\nApp-owned Imports relative path -> native AVAssetImageGenerator -> decodable JPEG -> real row Image, both themes.\nCached duration survives the second request.\nPhysical device, sound and MKV preview: Not Tested.\n',
        );
        debugPrint('ORVEX_IMPORT_PREVIEW_EVIDENCE=${root.path}');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        thumbnails.dispose();
        library.dispose();
        metadata.dispose();
        SharedPreferencesAsyncPlatform.instance = originalPrefs;
      }
    },
  );
}
