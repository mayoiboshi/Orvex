import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:orvex/app/orvex_app.dart';
import 'package:orvex/features/anime_metadata/application/anime_metadata_controller.dart';
import 'package:orvex/features/anime_metadata/domain/anime_subject.dart';
import 'package:orvex/features/anime_metadata/infrastructure/bangumi_client.dart';
import 'package:orvex/features/anime_metadata/infrastructure/bangumi_data_index.dart';
import 'package:orvex/features/anime_metadata/infrastructure/metadata_store.dart';
import 'package:orvex/features/library/infrastructure/playback_history_store.dart';
import 'package:orvex/features/media_sources/imported_file_store.dart';
import 'package:orvex/features/media_sources/local_file_source.dart';
import 'package:orvex/features/player/application/playback_session.dart';
import 'package:orvex/features/player/infrastructure/media_kit_engine.dart';
import 'package:orvex/features/player/infrastructure/preferences_resume_store.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _OfflineClient extends BangumiClient {
  int requests = 0;

  @override
  Future<List<AnimeSubject>> search(String keyword) async {
    requests++;
    throw const SocketException('offline fixture');
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets(
    'fresh offline matching uses the packaged index and local video still plays',
    (tester) async {
      expect(Platform.isIOS, isTrue);
      expect(
        await const MethodChannel('dev.orvex/audio-session')
            .invokeMethod<bool>('isSimulator'),
        isTrue,
      );
      MediaKit.ensureInitialized();
      final root = await Directory.systemTemp.createTemp('orvex-bangumi-data-');
      final previousPreferences = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      final real = BangumiDataAsset();
      final local = BangumiDataAsset(
        loader: () async {
          final rss = ProcessInfo.currentRss;
          final timer = Stopwatch()..start();
          final index = await real.index;
          debugPrint(
            'ORVEX_LOCAL_INDEX entries=${index.length} cold_us=${timer.elapsedMicroseconds} rss_delta_bytes=${ProcessInfo.currentRss - rss}',
          );
          timer.reset();
          for (var i = 0; i < 1000; i++) {
            index.match('Meitantei Conan', 'Meitantei Conan 0644.mkv');
            index.search('葬送');
          }
          debugPrint(
            'ORVEX_LOCAL_INDEX warm_2000_us=${timer.elapsedMicroseconds}',
          );
          return index;
        },
      );
      final client = _OfflineClient();
      final store = MetadataStore(
        directoryProvider: () async => Directory('${root.path}/metadata'),
      );
      final imports = ImportedFileStore(
        directoryProvider: () async => Directory('${root.path}/documents'),
      );
      final history = PlaybackHistoryStore();
      final controller = AnimeMetadataController(
        client: client,
        store: store,
        localIndex: local,
        isOffline: () async => true,
      );
      final session = PlaybackSession(
        createEngine: () => MediaKitEngine(silentAudioForTesting: true),
        resumeStore: PreferencesResumeStore(),
        onCheckpoint: history.record,
      );

      Future<void> until(bool Function() condition) async {
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (!condition() && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(condition(), isTrue, reason: session.error);
      }

      try {
        final sample = await rootBundle.load('test/fixtures/generated.mp4');
        final file =
            await File(
              '${root.path}/[LPSub] Meitantei Conan [01][AVC AAC][1080p][JPSC].mp4',
            ).writeAsBytes(
              sample.buffer.asUint8List(
                sample.offsetInBytes,
                sample.lengthInBytes,
              ),
            );
        final video = await imports.import(XFile(file.path));
        expect((await store.read()).entries, isEmpty);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              animeMetadataProvider.overrideWithValue(controller),
              localFilesProvider.overrideWithValue(
                LocalFileSource(imports: imports),
              ),
              historyStoreProvider.overrideWithValue(history),
              sessionProvider.overrideWithValue(session),
            ],
            child: const OrvexApp(),
          ),
        );
        await until(
          () =>
              controller.subjectFor(video)?.bangumiId == 899 &&
              !controller.busy,
        );
        final subject = controller.subjectFor(video)!;
        expect(subject.fromLocalIndex, isTrue);
        expect(subject.episodes, 0);
        expect(client.requests, 0);
        expect(
          (await store.read()).entries.values.single.subject?.bangumiId,
          899,
        );

        await tester.tap(find.byKey(const ValueKey('tab-3')));
        await tester.pump(const Duration(milliseconds: 450));
        final toggle = find.byKey(const ValueKey('offline-bangumi-fallback'));
        await tester.ensureVisible(toggle);
        expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
        await tester.tap(toggle);
        await until(() => !controller.offlineFallback);
        expect(controller.subjectFor(video)?.bangumiId, 899);

        final attribution = find.widgetWithText(ListTile, '数据来源');
        await tester.ensureVisible(attribution);
        await tester.tap(attribution);
        await tester.pump(const Duration(milliseconds: 450));
        expect(find.textContaining('CC BY 4.0'), findsOneWidget);
        expect(
          find.textContaining('https://github.com/bangumi-data/bangumi-data'),
          findsOneWidget,
        );
        await tester.tap(find.widgetWithText(TextButton, '关闭'));
        await tester.pump(const Duration(milliseconds: 450));

        unawaited(session.open(video));
        await until(
          () => session.ready && session.frame.position.inSeconds >= 2,
        );
        expect(find.text('本地番剧索引 · 查看作品资料'), findsOneWidget);
        await tester.tap(find.text('本地番剧索引 · 查看作品资料'));
        await tester.pump(const Duration(milliseconds: 450));
        expect(find.textContaining('已使用本地番剧索引'), findsOneWidget);
        expect(find.text('从 Bangumi 补全资料'), findsOneWidget);
        expect(client.requests, 0);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await session.shutdown();
        session.dispose();
        controller.dispose();
        SharedPreferencesAsyncPlatform.instance = previousPreferences;
        await root.delete(recursive: true);
      }
    },
  );
}
