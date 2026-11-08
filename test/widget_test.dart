import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/app/orvex_app.dart';
import 'package:orvex/design/orvex_theme.dart';
import 'package:orvex/features/anime_metadata/application/anime_metadata_controller.dart';
import 'package:orvex/features/anime_metadata/domain/anime_episode.dart';
import 'package:orvex/features/anime_metadata/domain/anime_subject.dart';
import 'package:orvex/features/anime_metadata/presentation/anime_metadata_sheet.dart';
import 'package:orvex/features/folder_library/folder_browser.dart';
import 'package:orvex/features/library/infrastructure/playback_history_store.dart';
import 'package:orvex/features/library/presentation/library_views.dart';
import 'package:orvex/features/media_sources/imported_file_store.dart';
import 'package:orvex/features/media_sources/local_file_source.dart';
import 'package:orvex/features/player/application/playback_session.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:orvex/features/player/presentation/playback_surface.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'support/fakes.dart';

import 'package:orvex/features/library/domain/media_series.dart';

import 'support/fake_metadata.dart';

class TestImports extends ImportedFileStore {
  List<LocalMedia> videos = [];
  final pendingResolutions = <String, Future<LocalMedia>>{};
  @override
  Future<List<LocalMedia>> listVideos() async => videos;

  @override
  Future<LocalMedia> resolve(LocalMedia media) =>
      pendingResolutions[media.resumeKey] ?? super.resolve(media);
}

void main() {
  late TestImports imports;
  late LocalFileSource files;
  late PlaybackHistoryStore history;
  late FakeEngine engine;
  late PlaybackSession session;
  late AnimeMetadataController metadata;
  late FakeBangumiClient bangumi;
  bool hasSession = false;
  int createdEngines = 0;

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
    bangumi = FakeBangumiClient();
    metadata = AnimeMetadataController(
      client: bangumi,
      store: MemoryMetadataStore(),
    );
    engine = FakeEngine();
    createdEngines = 0;
    session = PlaybackSession(
      createEngine: () {
        createdEngines++;
        return engine;
      },
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

  Iterable<Key?> recentCardKeys(WidgetTester tester) => tester
      .widgetList<InkWell>(
        find.byWidgetPredicate((widget) {
          final key = widget.key;
          return widget is InkWell &&
              key is ValueKey<String> &&
              key.value.startsWith('home-recent-');
        }),
      )
      .map((card) => card.key);

  LocalMedia datedVideo(String name, int day) => LocalMedia(
    uri: Uri.file('/test/$name.mp4'),
    name: '$name.mp4',
    modifiedAt: DateTime.utc(2026, 11, day),
  );

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
      expect(find.text('从这里开始观看'), findsOneWidget);
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
    'watch page fills the window and survives safe-area window resizing',
    (tester) async {
      final video = LocalMedia(
        uri: Uri.file('/Imports/layout.mp4'),
        name: '布局验证.mp4',
      );
      imports.videos = [video];
      await mount(tester, const Size(390, 844));
      await tester.tap(find.byKey(const ValueKey('tab-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('布局验证'));
      await tester.pumpAndSettle();
      final originalEngine = session.engine;
      final appearance = ProviderScope.containerOf(
        tester.element(find.byType(PlaybackSurface)),
      ).read(appearanceProvider);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      for (final scenario in [
        (const Size(390, 844), const FakeViewPadding(top: 59, bottom: 34)),
        (
          const Size(844, 390),
          const FakeViewPadding(left: 59, right: 59, bottom: 21),
        ),
        (const Size(834, 1210), const FakeViewPadding(top: 24, bottom: 20)),
        (const Size(1210, 834), const FakeViewPadding(top: 24, bottom: 20)),
        (const Size(430, 800), const FakeViewPadding(top: 24, bottom: 20)),
        (const Size(600, 480), const FakeViewPadding(top: 24, bottom: 20)),
        (const Size(390, 844), const FakeViewPadding(top: 59, bottom: 34)),
      ]) {
        tester.view.physicalSize = scenario.$1;
        tester.view.padding = scenario.$2;
        tester.view.viewPadding = scenario.$2;
        for (final mode in [ThemeMode.light, ThemeMode.dark]) {
          await appearance.setMode(mode);
          await tester.pumpAndSettle();
          await tester.drag(
            find.byType(CustomScrollView).last,
            const Offset(0, 2000),
          );
          await tester.pumpAndSettle();
          final rect = tester.getRect(find.byType(PlaybackSurface));
          final safeWidth =
              scenario.$1.width - scenario.$2.left - scenario.$2.right;
          expect(rect.width / rect.height, closeTo(16 / 9, 0.001));
          expect(rect.left, greaterThanOrEqualTo(scenario.$2.left));
          expect(
            rect.right,
            lessThanOrEqualTo(scenario.$1.width - scenario.$2.right),
          );
          expect(rect.top, greaterThanOrEqualTo(scenario.$2.top));
          expect(
            rect.bottom,
            lessThanOrEqualTo(scenario.$1.height - scenario.$2.bottom),
          );
          if (safeWidth < 600) expect(rect.width, closeTo(safeWidth, 0.01));
          final scaffold = find.byType(Scaffold).first;
          expect(tester.getSize(scaffold), scenario.$1);
          final colors = OrvexColors.of(tester.element(scaffold));
          expect(
            tester.widget<Scaffold>(scaffold).backgroundColor,
            colors.background,
          );
          expect(
            tester.getRect(find.byTooltip('返回首页')).top,
            greaterThanOrEqualTo(scenario.$2.top),
          );
          expect(session.engine, same(originalEngine));
          expect(tester.takeException(), isNull);
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'wide mode moves the playlist without restarting playback or losing filters',
    (tester) async {
      final episodes = [
        for (var i = 1; i <= 4; i++)
          LocalMedia(
            uri: Uri.file('/local/Show - 0$i.mp4'),
            name: 'Show - 0$i.mp4',
          ),
      ];
      imports.videos = episodes;
      await mount(tester, const Size(1210, 834));
      await session.open(episodes.first, queue: episodes);
      engine.frameController.add(
        const PlaybackFrame(
          playing: true,
          position: Duration(minutes: 3),
          duration: Duration(minutes: 20),
        ),
      );
      await tester.pumpAndSettle();
      final originalEngine = session.engine;
      final controls = tester.state(find.byType(PlaybackSurface));
      final appearance = ProviderScope.containerOf(
        tester.element(find.byType(PlaybackSurface)),
      ).read(appearanceProvider);
      final panel = find.byKey(const ValueKey('watch-episodes-panel'));
      final toggle = find.byKey(const ValueKey('playback-wide-mode'));
      final sidebarVideo = tester.getRect(find.byType(PlaybackSurface));
      expect(
        sidebarVideo.left,
        0,
        reason: 'No decorative outside video gutter',
      );
      expect(tester.getRect(panel).left, greaterThan(sidebarVideo.right));
      await tester.tap(find.byTooltip('搜索和筛选列表'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).last, '01');
      await tester.pumpAndSettle();
      for (final mode in [ThemeMode.light, ThemeMode.dark]) {
        await appearance.setMode(mode);
        await tester.pumpAndSettle();
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(panel, findsNothing);
        expect(
          tester.getSize(find.byType(PlaybackSurface)).width,
          greaterThan(sidebarVideo.width),
        );
        expect(tester.state(find.byType(PlaybackSurface)), same(controls));
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(panel, findsOneWidget);
        expect(find.text('01'), findsOneWidget);
        expect(tester.state(find.byType(PlaybackSurface)), same(controls));
      }
      // A small split window temporarily falls back, retaining the user's choice.
      tester.view.physicalSize = const Size(600, 480);
      await tester.pumpAndSettle();
      expect(panel, findsNothing);
      expect(toggle, findsNothing);
      tester.view.physicalSize = const Size(1210, 834);
      await tester.pumpAndSettle();
      expect(panel, findsOneWidget);
      expect(find.text('01'), findsOneWidget);
      expect(tester.state(find.byType(PlaybackSurface)), same(controls));
      expect(session.engine, same(originalEngine));
      expect(createdEngines, 1);
      expect(engine.pauses, 0);
      expect(engine.seeks, isEmpty);
      expect(session.frame.playing, isTrue);
      expect(session.frame.position, const Duration(minutes: 3));
      // The side list still uses the real open/queue action.
      await tester.enterText(find.byType(TextFormField).last, '02');
      await tester.pumpAndSettle();
      final row = find.byKey(ValueKey(episodes[1].resumeKey));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      // Broadcast stream cancellation crosses the fake/real async zones.
      for (var i = 0; i < 30 && !session.ready; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(session.ready, isTrue, reason: session.error);
      expect(createdEngines, 2);
      await tester.pumpAndSettle();
      expect(session.media?.resumeKey, episodes[1].resumeKey);
      expect(session.hasNext, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('watch details match and remember a corrected Bangumi episode', (
    tester,
  ) async {
    final video = LocalMedia(
      uri: Uri.file('/local/Detective Conan - 653.mp4'),
      name: 'Detective Conan - 653.mp4',
    );
    imports.videos = [video];
    await mount(tester, const Size(1210, 834));
    bangumi.episodeResults[899] = const [
      AnimeEpisode(id: 150925, sort: 653, chineseName: '毒与幻的设计（S）'),
      AnimeEpisode(
        id: 150926,
        sort: 654,
        name: 'Poison',
        airdate: '2012-05-05',
        description: '单集简介示例',
      ),
    ];
    await metadata.select(
      video,
      AnimeSubject.fromJson({'id': 899, 'type': 2, 'name_cn': '名侦探柯南'}),
    );
    await session.open(video);
    await tester.pumpAndSettle();

    expect(find.text('毒与幻的设计（S）'), findsOneWidget);
    await tester.tap(find.text('更正 Bangumi 单集'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '654');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Poison'));
    await tester.pumpAndSettle();
    expect(find.text('单集简介示例'), findsOneWidget);
    expect(find.textContaining('2012-05-05'), findsOneWidget);
    expect((await metadata.savedEpisode(video, 899))?.id, 150926);
    expect(await metadata.savedEpisode(video, 123), isNull);
    expect(bangumi.episodeRequests, [899]);

    await tester.tap(find.text('清除手动选择'));
    await tester.pumpAndSettle();
    expect(await metadata.savedEpisode(video, 899), isNull);
    expect(find.text('毒与幻的设计（S）'), findsOneWidget);
    expect(bangumi.episodeRequests, [899]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('dismissing watch dialogs keeps the current video playing', (
    tester,
  ) async {
    final video = LocalMedia(
      uri: Uri.file('/local/Show - 01.mp4'),
      name: 'Show - 01.mp4',
    );
    imports.videos = [video];
    await mount(tester, const Size(1210, 834));
    await session.open(video);
    engine.frameController.add(
      const PlaybackFrame(
        playing: true,
        position: Duration(minutes: 3),
        duration: Duration(minutes: 12),
      ),
    );
    await tester.pumpAndSettle();

    final surface = tester.state(find.byType(PlaybackSurface));
    for (final (title, button) in [
      ('播放操作', '知道了'),
      ('播放操作', '知道了'),
      ('文件详情', '关闭'),
    ]) {
      if (title == '播放操作') {
        await tester.tap(find.byTooltip('播放手势帮助'));
      } else {
        await tester.tap(find.byTooltip('视频操作'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('文件详情'));
      }
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AlertDialog, title), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, button));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.state(find.byType(PlaybackSurface)), same(surface));
      expect(session.engine, same(engine));
      expect(session.frame.playing, isTrue);
      expect(session.frame.position, const Duration(minutes: 3));
      expect(engine.pauses, 0);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('playback progress updates without rebuilding media browsers', (
    tester,
  ) async {
    final video = LocalMedia(
      uri: Uri.file('/local/Show - 01.mp4'),
      name: 'Show - 01.mp4',
    );
    imports.videos = [video];
    await mount(tester, const Size(1210, 834));
    await session.open(video);
    await tester.pumpAndSettle();

    final home = find.byType(LibraryViews, skipOffstage: false);
    final episodes = find.byType(FolderBrowser);
    final homeWidget = tester.widget(home);
    final episodesWidget = tester.widget(episodes);
    final row = find.byKey(ValueKey(video.resumeKey));
    final rowProgress = find.descendant(
      of: row,
      matching: find.byType(LinearProgressIndicator),
    );

    engine.frameController.add(
      const PlaybackFrame(
        playing: true,
        position: Duration(minutes: 3),
        duration: Duration(minutes: 12),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.widget(home), same(homeWidget));
    expect(tester.widget(episodes), same(episodesWidget));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('watch-information')),
        matching: find.text('03:00 / 12:00'),
      ),
      findsOneWidget,
    );
    expect(tester.widget<LinearProgressIndicator>(rowProgress).value, 0.25);
    await tester.tap(find.byTooltip('返回首页'));
    await tester.pumpAndSettle();
    expect(engine.pauses, 1);
    await tester.tap(find.byKey(const ValueKey('tab-2')));
    await tester.pumpAndSettle();
    engine.frameController.add(
      const PlaybackFrame(
        position: Duration(minutes: 3),
        duration: Duration(minutes: 12),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已暂停 · 03:00'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('leaving playback discards a pending episode selection', (
    tester,
  ) async {
    final episodes = [
      for (var i = 1; i <= 2; i++)
        LocalMedia(uri: Uri.file('/test/$i.mp4'), name: '返回验证 - $i.mp4'),
    ];
    imports.videos = episodes;
    await mount(tester, const Size(390, 844));
    await session.open(episodes.first, queue: episodes);
    await tester.pumpAndSettle();
    final resolved = Completer<LocalMedia>();
    imports.pendingResolutions[episodes.last.resumeKey] = resolved.future;
    final row = find.byKey(ValueKey(episodes.last.resumeKey));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    final back = find.byTooltip('返回首页');
    await tester.ensureVisible(back);
    await tester.pumpAndSettle();
    await tester.tap(back);
    await tester.pumpAndSettle();
    resolved.complete(episodes.last);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PlaybackSurface), findsNothing);
    expect(session.media?.resumeKey, episodes.first.resumeKey);
    expect(createdEngines, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'iOS interactive back cancels safely then returns one level at a time',
    (tester) async {
      imports.videos = [
        for (final n in [1, 2])
          LocalMedia(
            uri: Uri.file('/test/series-$n.mp4'),
            name: '返回测试 - $n.mp4',
          ),
      ];
      await mount(tester, const Size(390, 844));
      await tester.tap(find.byKey(const ValueKey('tab-1')));
      await tester.pumpAndSettle();
      final group = identifySeries(imports.videos.first).key;
      await tester.tap(find.byKey(ValueKey('series-$group')));
      await tester.pumpAndSettle();
      final row = find.byKey(ValueKey(imports.videos.first.resumeKey));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      engine.frameController.add(
        const PlaybackFrame(
          position: Duration(seconds: 10),
          duration: Duration(minutes: 20),
          playing: true,
        ),
      );
      await tester.pumpAndSettle();
      final pauses = engine.pauses;
      final originalEngine = session.engine;
      final swipe = await tester.startGesture(const Offset(2, 400));
      // Cross gesture slop before asserting following motion near tappable UI.
      await swipe.moveBy(const Offset(20, 0));
      await tester.pump();
      await swipe.moveBy(const Offset(60, 0));
      await tester.pump();
      expect(
        tester.getTopLeft(find.byType(PlaybackSurface)).dx,
        greaterThan(0),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await swipe.up();
      await tester.pumpAndSettle();
      expect(find.byType(PlaybackSurface), findsOneWidget);
      expect(engine.pauses, pauses);
      expect(session.engine, same(originalEngine));
      final complete = await tester.startGesture(const Offset(2, 400));
      await complete.moveBy(const Offset(20, 0));
      await tester.pump();
      await complete.moveBy(const Offset(290, 0));
      await tester.pump(const Duration(milliseconds: 500));
      await complete.up();
      await tester.pumpAndSettle();
      expect(find.byType(PlaybackSurface), findsNothing);
      expect(find.byTooltip('返回剧集'), findsOneWidget);
      expect(engine.pauses, pauses + 1);
      expect(session.engine, same(originalEngine));
      expect(session.frame.position, const Duration(seconds: 10));
      await tester.dragFrom(const Offset(2, 400), const Offset(310, 0));
      await tester.pumpAndSettle();
      expect(find.byTooltip('返回剧集'), findsNothing);
      expect(find.byKey(ValueKey('series-$group')), findsOneWidget);
      await tester.dragFrom(const Offset(2, 400), const Offset(310, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tab-1')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'Android system back returns player then series without popping the application',
    (tester) async {
      imports.videos = [
        for (final n in [1, 2])
          LocalMedia(
            uri: Uri.file('/test/android-$n.mp4'),
            name: '安卓返回 - $n.mp4',
          ),
      ];
      await mount(tester, const Size(390, 844));
      await tester.tap(find.byKey(const ValueKey('tab-1')));
      await tester.pumpAndSettle();
      final group = identifySeries(imports.videos.first).key;
      await tester.tap(find.byKey(ValueKey('series-$group')));
      await tester.pumpAndSettle();
      final row = find.byKey(ValueKey(imports.videos.first.resumeKey));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(PlaybackSurface), findsNothing);
      expect(find.byTooltip('返回剧集'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byTooltip('返回剧集'), findsNothing);
      expect(find.byKey(ValueKey('series-$group')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
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

  testWidgets(
    'series groups open a sorted queue and restore the episode list on return',
    (tester) async {
      imports.videos = [
        for (final n in [10, 2, 1])
          LocalMedia(
            uri: Uri.file('/test/Series-$n.mp4'),
            name: '示例番剧 - $n.mp4',
          ),
      ];
      tester.platformDispatcher.textScaleFactorTestValue = 1.7;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await mount(tester, const Size(360, 800));
      await tester.tap(find.byKey(const ValueKey('tab-1')));
      await tester.pumpAndSettle();
      final groupKey = identifySeries(imports.videos.first).key;
      expect(find.byKey(ValueKey('series-$groupKey')), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('series-$groupKey')));
      await tester.pumpAndSettle();
      expect(find.byTooltip('返回剧集'), findsOneWidget);
      final second = imports.videos.singleWhere((m) => m.name.contains('- 2.'));
      final row = find.byKey(ValueKey(second.resumeKey));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(session.playlist.map((m) => identifySeries(m).episode), [
        1,
        2,
        10,
      ]);
      expect(session.playlistIndex, 1);
      await tester.ensureVisible(find.byTooltip('返回首页'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('返回首页'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('返回剧集'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'recent additions show both series and the single-file resume movie',
    (tester) async {
      final conan = [for (var i = 1; i <= 28; i++) datedVideo('名侦探柯南 - $i', 2)];
      final tooMany = [
        for (var i = 1; i <= 12; i++) datedVideo('败犬女主太多了！ - $i', 3),
      ];
      final movie = datedVideo('超辉夜姬！', 1);
      imports.videos = [...conan, ...tooMany, movie];
      await PlaybackHistoryStore().record(
        movie,
        const PlaybackFrame(
          position: Duration(minutes: 90),
          duration: Duration(minutes: 142),
        ),
      );
      await mount(tester, const Size(1194, 834));
      await metadata.selectMany(
        conan,
        const AnimeSubject(id: 1, name: '名侦探柯南', nameCn: '', platform: 'TV'),
      );
      await metadata.selectMany(
        tooMany,
        const AnimeSubject(id: 2, name: '败犬女主太多了！', nameCn: '', platform: 'TV'),
      );
      await metadata.select(
        movie,
        const AnimeSubject(id: 3, name: '超辉夜姬！', nameCn: '', platform: '剧场版'),
      );
      await tester.pumpAndSettle();

      expect(find.text('41 部视频 · 1 部可继续观看'), findsOneWidget);
      expect(find.byKey(const ValueKey('home-resume')), findsOneWidget);
      expect(find.text('继续播放'), findsOneWidget);
      expect(recentCardKeys(tester), [
        const ValueKey('home-recent-bangumi:2'),
        const ValueKey('home-recent-bangumi:1'),
        ValueKey('home-recent-${movie.resumeKey}'),
      ]);
      expect(find.text('已收录 28 个视频'), findsOneWidget);
      expect(find.text('已收录 12 个视频'), findsOneWidget);
      final movieCard = find.byKey(ValueKey('home-recent-${movie.resumeKey}'));
      await Scrollable.ensureVisible(tester.element(movieCard), alignment: 0.2);
      await tester.pumpAndSettle();
      await tester.tap(movieCard);
      await tester.pumpAndSettle();
      expect(session.media?.resumeKey, movie.resumeKey);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('recent additions limit cards after grouping and sorting', (
    tester,
  ) async {
    final episodes = [
      for (var i = 1; i <= 9; i++) datedVideo('Series - $i', 10),
    ];
    final independent = [for (var i = 1; i <= 9; i++) datedVideo('Clip $i', i)];
    imports.videos = [...episodes, ...independent];
    await mount(tester, const Size(1194, 834));
    await metadata.selectMany(
      episodes,
      const AnimeSubject(id: 1, name: 'Series', nameCn: '', platform: 'TV'),
    );
    await tester.pumpAndSettle();
    expect(recentCardKeys(tester), [
      const ValueKey('home-recent-bangumi:1'),
      for (final media in independent.reversed.take(7))
        ValueKey('home-recent-${media.resumeKey}'),
    ]);
    expect(find.text('已收录 9 个视频'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('home work detail opens a file and keeps the detail on return', (
    tester,
  ) async {
    final videos = [
      for (final name in ['示例番剧 S01E02', '示例番剧 S02E01'])
        LocalMedia(uri: Uri.file('/test/$name.mp4'), name: '$name.mp4'),
    ];
    imports.videos = videos;
    await mount(tester, const Size(1194, 834));
    await metadata.selectMany(
      videos,
      const AnimeSubject(
        id: 55,
        name: '示例番剧',
        nameCn: '示例番剧',
        platform: 'TV',
        date: '2026-01-01',
        score: 7.5,
      ),
    );
    await tester.pumpAndSettle();
    final card = find.byKey(const ValueKey('home-recent-bangumi:55'));
    expect(card, findsOneWidget);
    expect(find.text('已收录 2 个视频'), findsOneWidget);
    expect(find.text('2026 · ★ 7.5'), findsOneWidget);
    final poster = find.descendant(
      of: card,
      matching: find.byType(AspectRatio),
    );
    final size = tester.getSize(poster);
    expect(size.width / size.height, closeTo(2 / 3, 0.001));
    expect(tester.getTopLeft(card).dx, tester.getTopLeft(find.text('最近添加')).dx);
    await tester.ensureVisible(card);
    await tester.tap(card);
    await tester.pumpAndSettle();
    for (final video in videos) {
      expect(find.byKey(ValueKey(video.resumeKey)), findsOneWidget);
    }
    final row = find.byKey(ValueKey(videos.last.resumeKey));
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(session.media?.resumeKey, videos.last.resumeKey);
    await tester.tap(find.byTooltip('返回首页'));
    await tester.pumpAndSettle();
    expect(row, findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(card, findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('time label distinguishes long videos', () {
    expect(
      formatTime(const Duration(hours: 2, minutes: 3, seconds: 4)),
      '2:03:04',
    );
    expect(formatTime(const Duration(seconds: -5)), '00:00');
  });
}
