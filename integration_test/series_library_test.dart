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
import 'package:orvex/features/anime_metadata/domain/anime_subject.dart';
import 'package:orvex/features/anime_metadata/infrastructure/bangumi_client.dart';
import 'package:orvex/features/anime_metadata/infrastructure/metadata_store.dart';
import 'package:orvex/features/folder_library/folder_library.dart';
import 'package:orvex/features/folder_library/folder_models.dart';
import 'package:orvex/features/media_sources/imported_file_store.dart';
import 'package:orvex/features/media_sources/local_file_source.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class ObservedBangumiClient extends BangumiClient {
  ObservedBangumiClient({required super.httpClient});
  final firstResults = <String, int?>{};
  final queries = <String>[];
  @override
  Future<List<AnimeSubject>> search(String keyword) async {
    queries.add(keyword);
    final results = await super.search(keyword);
    firstResults[keyword] = results.firstOrNull?.id;
    return results;
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'native scanned episodes group, first live Bangumi candidate, poster and cross-folder queue',
    (tester) async {
      expect(Platform.isIOS, isTrue);
      expect(
        await const MethodChannel('dev.orvex/audio-session')
            .invokeMethod<bool>('isSimulator'),
        isTrue,
        reason: 'Generated source fixtures must never run on physical devices',
      );
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
      MediaKit.ensureInitialized();
      final documents = await getApplicationDocumentsDirectory();
      final descriptor = File(
        '${documents.path}/orvex-folder-native-test.json',
      );
      expect(
        await descriptor.exists(),
        isTrue,
        reason: 'Prepare native folder fixture with MediaFolderAccessTests on this simulator first',
      );
      final root = FolderRoot.fromJson(
        jsonDecode(await descriptor.readAsString()) as Map<String, dynamic>,
      );
      final base = await Directory('${documents.path}/OrvexSeriesEvidence')
          .create();
      final evidence = await base.createTemp('run-');
      final library = FolderLibrary(
        directory: () async => Directory('${evidence.path}/library'),
      );
      await library.initialize();
      library.roots.clear();
      library.entries.clear();
      library.roots.add(root);
      await library.scan(root);
      expect(library.discovered, 7);
      final http = HttpClient();
      const proxy = String.fromEnvironment('ORVEX_BANGUMI_TEST_PROXY');
      if (proxy.isNotEmpty) http.findProxy = (_) => 'PROXY $proxy';
      final client = ObservedBangumiClient(httpClient: http);
      final metadata = AnimeMetadataController(
        client: client,
        store: MetadataStore(
          directoryProvider: () async => Directory('${evidence.path}/metadata'),
        ),
        queryResolver: (m) => library.identityFor(m).query,
        groupResolver: (m) => library.identityFor(m).key,
      );
      final originalPrefs = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      final appearance = AppearanceController();
      await appearance.initialize();
      final container = ProviderContainer(
        overrides: [
          folderLibraryProvider.overrideWithValue(library),
          animeMetadataProvider.overrideWithValue(metadata),
          appearanceProvider.overrideWithValue(appearance),
          localFilesProvider.overrideWithValue(
            LocalFileSource(
              imports: ImportedFileStore(
                directoryProvider: () async =>
                    Directory('${evidence.path}/empty-imports'),
              ),
            ),
          ),
        ],
      );
      final session = container.read(sessionProvider);
      final screen = GlobalKey();
      Future<void> until(bool Function() ready, String label) async {
        final end = DateTime.now().add(const Duration(seconds: 65));
        while (!ready() && DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          ready(),
          isTrue,
          reason: '$label; ${metadata.error}; ${session.error}',
        );
      }

      Future<void> capture(String name) async {
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        final boundary =
            screen.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${evidence.path}/$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      }

      try {
        await tester.pumpWidget(
          RepaintBoundary(
            key: screen,
            child: UncontrolledProviderScope(
              container: container,
              child: const OrvexApp(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('tab-1')));
        await tester.pumpAndSettle();
        final groups = library.series(const []);
        final series = groups.singleWhere((g) => g.media.length == 5);
        expect(groups.length, 3);
        await until(
          () =>
              series.media.every((m) => metadata.subjectFor(m) != null) &&
              metadata.posterPath(
                    metadata.subjectFor(series.representative)!.id,
                  ) !=
                  null,
          'scan automatically matches series and downloads real Bangumi poster',
        );
        expect(
          metadata.subjectFor(series.representative)?.id,
          client.firstResults[series.identity.query],
        );
        expect(
          client.queries.where((q) => q == series.identity.query).length,
          1,
        );
        await appearance.setMode(ThemeMode.light);
        await tester.pumpAndSettle();
        await capture('series-light');
        await appearance.setMode(ThemeMode.dark);
        await tester.pumpAndSettle();
        await capture('series-dark');
        await tester.ensureVisible(
          find.byKey(ValueKey('series-${series.key}')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('series-${series.key}')));
        await tester.pumpAndSettle();
        await capture('episodes-dark');
        final episode = series.media.singleWhere(
          (m) => library.identityFor(m).episode == 124,
        );
        final row = find.byKey(ValueKey(episode.resumeKey));
        await tester.ensureVisible(row);
        await tester.pumpAndSettle();
        await tester.tap(row);
        await until(
          () => session.ready && session.frame.duration > Duration.zero,
          'episode row opens native playback',
        );
        expect(session.playlist.length, 5);
        expect(session.playlistIndex, 3);
        await session.seek(const Duration(seconds: 4));
        await session.pauseForInterruption();
        await tester.pumpAndSettle();
        await capture('series-player-dark');
        final next = find.byTooltip('下一集');
        await tester.ensureVisible(next);
        await tester.tap(next);
        await until(
          () =>
              session.ready &&
              library.identityFor(session.media!).episode == 125,
          'next follows the name-derived series queue',
        );
        await session.pauseForInterruption();
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byTooltip('返回首页'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('返回首页'));
        await tester.pumpAndSettle();
        expect(
          find.byTooltip('返回剧集'),
          findsOneWidget,
          reason: 'Returning restores the selected series',
        );
        await tester.tap(find.byTooltip('返回剧集'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('folders-view')));
        await tester.pumpAndSettle();
        expect(find.text(root.name), findsOneWidget);
        await capture('folders-dark');
        await File('${evidence.path}/results.txt').writeAsString(
          'Actual native bookmark + seven generated fixture files; five numbered episodes group across range folders, two movies stay independent.\nReal Bangumi API candidate first ID: ${client.firstResults[series.identity.query]}; five members use that result with one search.\nActual cached poster, light/dark overview, episode list, native playback and next-episode across the grouped context.\nOriginal folder browsing retained; return restores selected series.\nSimulator playback audio is not a physical sound acceptance test.\n',
        );
        debugPrint('ORVEX_SERIES_EVIDENCE=${evidence.path}');
      } finally {
        await session.shutdown();
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        metadata.dispose();
        appearance.dispose();
        library.dispose();
        SharedPreferencesAsyncPlatform.instance = originalPrefs;
      }
    },
  );
}
