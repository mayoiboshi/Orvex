import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/app/orvex_app.dart';
import 'package:orvex/features/anime_metadata/application/anime_metadata_controller.dart';
import 'package:orvex/features/anime_metadata/domain/anime_subject.dart';
import 'package:orvex/features/anime_metadata/presentation/anime_metadata_sheet.dart';
import 'package:orvex/features/library/infrastructure/playback_history_store.dart';
import 'package:orvex/features/media_sources/imported_file_store.dart';
import 'package:orvex/features/media_sources/local_file_source.dart';
import 'package:orvex/features/player/application/playback_session.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:orvex/features/player/presentation/playback_surface.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'support/fakes.dart';
import 'support/fake_metadata.dart';

class TestImports extends ImportedFileStore {
  List<LocalMedia> videos = [];
  @override
  Future<List<LocalMedia>> listVideos() async => videos;
}

void main() {
  late TestImports imports;
  late LocalFileSource files;
  late PlaybackHistoryStore history;
  late FakeEngine engine;
  late PlaybackSession session;
  late AnimeMetadataController metadata;
  bool hasSession = false;

  setUp(() async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    imports = TestImports();
    files = LocalFileSource(imports: imports);
    hasSession = false;
  });

  tearDown(() {
    if (!hasSession) return;
    session.dispose();
    metadata.dispose();
  });

  Future<void> mount(WidgetTester tester, Size size) async {
    history = PlaybackHistoryStore();
    metadata = AnimeMetadataController(
      client: FakeBangumiClient(),
      store: MemoryMetadataStore(),
    );
    engine = FakeEngine();
    session = PlaybackSession(
      createEngine: () => engine,
      resumeStore: MemoryResumeStore(),
      onCheckpoint: history.record,
    );
    hasSession = true;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWithValue(session),
          localFilesProvider.overrideWithValue(files),
          historyStoreProvider.overrideWithValue(history),
          animeMetadataProvider.overrideWithValue(metadata),
        ],
        child: const OrvexApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final size in [
    const Size(360, 800),
    const Size(430, 932),
    const Size(744, 1133),
    const Size(1194, 834),
  ]) {
    testWidgets('four tabs fit phone and iPad layout ${size.width}', (
      tester,
    ) async {
      await mount(tester, size);
      expect(find.text('好故事，\n从这里开始。'), findsOneWidget);
      for (var index = 1; index < 4; index++) {
        await tester.tap(find.byKey(ValueKey('tab-$index')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      expect(find.text('显示继续观看'), findsOneWidget);
      await tester.tap(find.widgetWithText(SwitchListTile, '显示继续观看'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tab-0')));
      await tester.pumpAndSettle();
      expect(find.text('继续观看'), findsNothing);
      expect(find.byKey(const ValueKey('tab-3')), findsOneWidget);
    });
  }

  testWidgets(
    'library search opens media and returning shows real persisted history',
    (tester) async {
      final video = LocalMedia(
        uri: Uri.file('/Imports/我的旅行.mp4'),
        name: '我的旅行.mp4',
      );
      imports.videos = [
        video,
        LocalMedia(uri: Uri.file('/Imports/另一部影片.mkv'), name: '另一部影片.mkv'),
      ];
      await mount(tester, const Size(390, 844));
      await tester.tap(find.byKey(const ValueKey('tab-1')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '旅行');
      await tester.pumpAndSettle();
      expect(find.text('另一部影片'), findsNothing);
      await tester.tap(find.text('我的旅行'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(session.loading, isFalse, reason: 'open error: ${session.error}');
      await tester.pumpAndSettle();
      expect(session.media?.uri, video.uri);
      expect(find.byType(PlaybackSurface), findsOneWidget);
      engine.frameController.add(
        const PlaybackFrame(
          position: Duration(minutes: 3),
          duration: Duration(minutes: 10),
          playing: true,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('返回首页'));
      await tester.pumpAndSettle();
      expect(engine.pauses, 1);
      await tester.tap(find.byKey(const ValueKey('tab-2')));
      await tester.pumpAndSettle();
      expect(find.text('看到 03:00'), findsOneWidget);
      final saved = (await tester.runAsync(PlaybackHistoryStore().list))!;
      expect(saved.single.media.uri, video.uri);
      expect(saved.single.position, const Duration(minutes: 3));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'matched titles are searchable and the details sheet permits correction and ignore',
    (tester) async {
      final video = LocalMedia(
        uri: Uri.file('/Imports/a/[ANi] 示例番剧 - 01.mp4'),
        name: '[ANi] 示例番剧 - 01.mp4',
      );
      imports.videos = [video];
      await mount(tester, const Size(390, 844));
      const subject = AnimeSubject(
        id: 1,
        name: 'Example Anime',
        nameCn: '匹配后的番剧名',
        summary: '用于验证资料面板的测试简介。',
        date: '2023-01-01',
        episodes: 12,
        score: 8.2,
      );
      await tester.runAsync(() => metadata.select(video, subject));
      await tester.tap(find.byKey(const ValueKey('tab-1')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '匹配后的');
      await tester.pumpAndSettle();
      expect(find.text('匹配后的番剧名 · 第 1 集'), findsOneWidget);
      await tester.tap(find.byTooltip('番剧资料'));
      await tester.pumpAndSettle();
      expect(find.text('剧情简介'), findsOneWidget);
      expect(find.text('用于验证资料面板的测试简介。'), findsOneWidget);
      const corrected = AnimeSubject(
        id: 2,
        name: 'Corrected',
        nameCn: '更正的番剧',
        date: '2024-01-01',
        episodes: 12,
      );
      (metadata.client as FakeBangumiClient).results = [corrected];
      await tester.enterText(
        find.descendant(
          of: find.byType(AnimeMetadataSheet),
          matching: find.byType(TextField),
        ),
        '更正的番剧',
      );
      await tester.tap(find.byTooltip('搜索 Bangumi'));
      await tester.pumpAndSettle();
      final correctedTile = find.widgetWithText(ListTile, '更正的番剧');
      await tester.ensureVisible(correctedTile);
      await tester.tap(correctedTile);
      await tester.pumpAndSettle();
      expect(metadata.subjectFor(video)?.id, 2);
      await tester.ensureVisible(find.text('不关联此视频'));
      await tester.tap(find.text('不关联此视频'));
      await tester.pumpAndSettle();
      expect(metadata.matchFor(video)?.status, AnimeMatchStatus.ignored);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test('time label distinguishes long videos', () {
    expect(
      formatTime(const Duration(hours: 2, minutes: 3, seconds: 4)),
      '2:03:04',
    );
    expect(formatTime(const Duration(seconds: -5)), '00:00');
  });
}
