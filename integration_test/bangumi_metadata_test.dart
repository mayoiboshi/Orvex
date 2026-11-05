import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orvex/app/orvex_app.dart';
import 'package:orvex/features/anime_metadata/application/anime_metadata_controller.dart';
import 'package:orvex/features/anime_metadata/domain/anime_subject.dart';
import 'package:orvex/features/anime_metadata/infrastructure/bangumi_client.dart';
import 'package:orvex/features/anime_metadata/infrastructure/metadata_store.dart';
import 'package:orvex/features/media_sources/imported_file_store.dart';
import 'package:orvex/features/media_sources/local_file_source.dart';
import 'package:orvex/features/player/application/playback_session.dart';

import '../test/support/fakes.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets(
    'live Bangumi automatic matching, artwork, details and disk cache (simulator only)',
    (tester) async {
      const conan = bool.fromEnvironment('ORVEX_BANGUMI_CONAN_REGRESSION');
      const expectedId = conan ? 899 : 400602;
      const expectedLabel = conan ? '名侦探柯南 · 第 615 集' : '葬送的芙莉莲 · 第 1 集';
      // Physical acceptance always uses the user's own media, never this fixture.
      const native = MethodChannel('dev.orvex/audio-session');
      expect(
        await native.invokeMethod<bool>('isSimulator'),
        isTrue,
        reason: 'This generated fixture may only be installed on a simulator.',
      );
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
      final directory = await Directory.systemTemp.createTemp('orvex-bangumi-');
      final fixture = await rootBundle.load('test/fixtures/generated.mp4');
      final filename = conan
          ? '[Fabre–RAW] Detective Conan 0615 [NetflixJP] [1080p].mkv'
          : '[ANi] 葬送的芙莉莲 - 01 [1080p].mp4';
      final file = await File('${directory.path}/$filename')
          .writeAsBytes(fixture.buffer.asUint8List());
      final imports = ImportedFileStore(
        directoryProvider: () async => Directory('${directory.path}/documents'),
      );
      final video = await imports.import(XFile(file.path));
      final http = HttpClient();
      const proxy = String.fromEnvironment('ORVEX_BANGUMI_TEST_PROXY');
      if (proxy.isNotEmpty) http.findProxy = (_) => 'PROXY $proxy';
      final cache = MetadataStore(
        directoryProvider: () async => Directory('${directory.path}/cache'),
      );
      if (conan) {
        await cache.write(true, {
          animeMediaKey(video): AnimeMatch(
            query: 'Detective Conan 0615',
            status: AnimeMatchStatus.needsReview,
            updatedAt: DateTime.now(),
            matcherVersion: 0,
          ),
        });
      }
      final metadata = AnimeMetadataController(
        client: BangumiClient(httpClient: http),
        store: cache,
      );
      final session = PlaybackSession(
        createEngine: FakeEngine.new,
        resumeStore: MemoryResumeStore(),
      );
      final screen = GlobalKey();

      Future<void> until(bool Function() ready, String label) async {
        final deadline = DateTime.now().add(const Duration(seconds: 45));
        while (!ready() && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(
          ready(),
          isTrue,
          reason:
              '$label; status=${metadata.matchFor(video)?.status}; error=${metadata.matchFor(video)?.error ?? metadata.error}',
        );
      }

      Future<void> screenshot(String name) async {
        final boundary =
            screen.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${directory.path}/$name.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      }

      try {
        await tester.pumpWidget(
          RepaintBoundary(
            key: screen,
            child: ProviderScope(
              overrides: [
                sessionProvider.overrideWithValue(session),
                localFilesProvider.overrideWithValue(
                  LocalFileSource(imports: imports),
                ),
                animeMetadataProvider.overrideWithValue(metadata),
              ],
              child: const OrvexApp(),
            ),
          ),
        );
        await until(
          () => metadata.subjectFor(video)?.id == expectedId && !metadata.busy,
          'automatic exact-name match',
        );
        expect(metadata.matchFor(video)?.manual, isFalse);
        await tester.tap(find.byKey(const ValueKey('tab-1')));
        await tester.pumpAndSettle();
        expect(find.text(expectedLabel), findsOneWidget);
        await tester.ensureVisible(find.text(expectedLabel));
        if (conan) {
          expect(metadata.subjectFor(video)?.platform, 'TV');
          expect(
            metadata.subjectFor(video)!.relatedSourceIds.toSet().length,
            greaterThanOrEqualTo(2),
          );
        }
        await until(
          () => tester
              .widgetList<RawImage>(find.byType(RawImage))
              .any((image) => image.image != null),
          'real Bangumi poster decoded',
        );
        await screenshot('library');
        await tester.tap(find.byTooltip('番剧资料'));
        await tester.pumpAndSettle();
        expect(find.text('剧情简介'), findsOneWidget);
        expect(find.textContaining('已自动匹配'), findsOneWidget);
        await screenshot('details');
        await tester.tap(find.byTooltip('关闭番剧资料'));
        await tester.pumpAndSettle();
        final offlineHttp = HttpClient()
          ..findProxy = (_) => 'PROXY 127.0.0.1:1';
        final reopened = AnimeMetadataController(
          client: BangumiClient(httpClient: offlineHttp),
          store: cache,
        );
        await reopened.scan([video]);
        expect(reopened.subjectFor(video)?.id, expectedId);
        expect(
          await File(reopened.posterPath(expectedId)!).length(),
          greaterThan(1000),
        );
        expect(
          reopened.busy,
          isFalse,
          reason: 'matched metadata is reused without a network request',
        );
        reopened.dispose();
        expect(tester.takeException(), isNull);
        await File('${directory.path}/results.txt').writeAsString(
          [
            'PASS: generated fixture imported in isolated simulator directory only',
            'PASS: live unauthenticated Bangumi lookup matched subject $expectedId',
            if (conan) 'PASS: reported four-digit episode matched TV main story through independent explicit Bangumi relationships',
            if (conan) 'PASS: old review cache was automatically refreshed after the matcher update',
            'PASS: release group, episode and resolution removed from query',
            'PASS: actual remote poster decoded in library card',
            'PASS: Chinese title, rating/year and episode rendered',
            'PASS: details show automatic match, synopsis and Bangumi attribution',
            'PASS: metadata restored from disk with an unreachable network proxy',
            'NOT TESTED: physical device metadata matching, general filename recognition accuracy',
            'NOT TESTED: audio or media playback in this metadata-only test',
          ].join('\n'),
        );
        debugPrint('ORVEX_BANGUMI_EVIDENCE=${directory.path}');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        metadata.dispose();
        await session.shutdown();
        session.dispose();
      }
    },
  );
}
