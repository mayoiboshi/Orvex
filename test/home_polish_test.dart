import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/design/appearance_controller.dart';
import 'package:orvex/design/orvex_theme.dart';
import 'package:orvex/design/glass.dart';
import 'package:orvex/features/anime_metadata/application/anime_metadata_controller.dart';
import 'package:orvex/features/library/domain/playback_record.dart';
import 'package:orvex/features/library/application/history_browser.dart';
import 'package:orvex/features/library/presentation/library_browse_style.dart';
import 'package:orvex/features/library/presentation/library_views.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';

import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'support/fake_metadata.dart';

void main() {
  testWidgets(
    'history fills a short page without scrolling and retries at the footer',
    (tester) async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      final browser = HistoryBrowser();
      final metadata = AnimeMetadataController(
        client: FakeBangumiClient(),
        store: MemoryMetadataStore(),
      );
      final appearance = AppearanceController();
      addTearDown(browser.dispose);
      addTearDown(metadata.dispose);
      addTearDown(appearance.dispose);
      tester.view.physicalSize = const Size(500, 5000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final records = [
        for (var i = 0; i < 48; i++)
          PlaybackRecord(
            media: LocalMedia(uri: Uri.file('/$i.mp4'), name: '$i.mp4'),
            position: Duration.zero,
            duration: Duration.zero,
            updatedAt: null,
          ),
      ];
      final calls = <int>[];
      await browser.refresh(
        () async => HistoryBrowseSnapshot(
          total: records.length,
          readPage: (offset, count) async {
            calls.add(offset);
            if (offset == 30 && calls.length == 2) {
              throw StateError('read failed');
            }
            return records.sublist(offset, offset + count);
          },
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: OrvexTheme.create(Brightness.dark),
          home: Scaffold(
            body: LibraryViews(
              tab: 2,
              videos: const [],
              history: const [],
              historyBrowser: browser,
              loading: false,
              picking: false,
              showContinue: true,
              query: '',
              onQuery: (_) {},
              onImport: () {},
              onOpen: (_) {},
              onTab: (_) {},
              onRefresh: () async {},
              onShowContinue: (_) {},
              metadata: metadata,
              onMetadata: (_, {group}) {},
              appearance: appearance,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, [0, 30]);
      expect(browser.records.length, 30);
      expect(find.text('48 条记录'), findsOneWidget);
      expect(find.text('0.mp4'), findsOneWidget);
      final retry = find.text('加载更多记录失败 · 重试');
      expect(retry.hitTestable(), findsOneWidget);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(calls, [0, 30, 30]);
      expect(browser.records.length, 48);
      expect(retry, findsNothing);
      expect(find.text('47.mp4'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'history offers library navigation and one playback action per row',
    (tester) async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      final metadata = AnimeMetadataController(
        client: FakeBangumiClient(),
        store: MemoryMetadataStore(),
      );
      final appearance = AppearanceController();
      addTearDown(metadata.dispose);
      addTearDown(appearance.dispose);
      tester.view.physicalSize = const Size(360, 700);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final media = LocalMedia(
        uri: Uri.file('/history.mp4'),
        name: '${List.filled(12, '无关联资料的长文件名').join()}.mp4',
      );
      var imports = 0, details = 0;
      final opened = <LocalMedia>[];
      final tabs = <int>[];
      Future<void> show(List<PlaybackRecord> history) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: OrvexTheme.create(Brightness.light),
            home: Scaffold(
              body: LibraryViews(
                tab: 2,
                videos: const [],
                history: history,
                loading: false,
                picking: false,
                showContinue: true,
                query: '',
                onQuery: (_) {},
                onImport: () => imports++,
                onOpen: opened.add,
                onTab: tabs.add,
                onRefresh: () async {},
                onShowContinue: (_) {},
                metadata: metadata,
                onMetadata: (_, {group}) => details++,
                appearance: appearance,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await show([]);
      final emptyPanel = find.ancestor(
        of: find.text('还没有播放记录'),
        matching: find.byType(GlassSurface),
      );
      final emptyBounds = tester.getRect(emptyPanel);
      expect(emptyBounds.left, libraryBrowseInset(360));
      expect(360 - emptyBounds.right, libraryBrowseInset(360));
      expect(find.byTooltip('打开本地视频'), findsNothing);
      await tester.tap(find.text('前往媒体库'));
      expect(tabs, [1]);
      expect(imports, 0);
      await show([
        PlaybackRecord(
          media: media,
          position: const Duration(seconds: 50),
          duration: Duration.zero,
          updatedAt: null,
        ),
      ]);
      expect(find.text('1 条记录'), findsOneWidget);
      expect(find.text('最近播放时间未知'), findsOneWidget);
      expect(find.text('未看完 · 00:50'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(
        tester.widget<MediaCover>(find.byType(MediaCover)).fit,
        BoxFit.contain,
      );
      await tester.longPress(find.text(media.name));
      expect(details, 1);
      expect(opened, isEmpty);
      await tester.tap(find.byTooltip('继续播放'));
      expect(opened, [media]);
      await tester.tap(find.text(media.name));
      expect(opened, [media, media]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'populated Home preserves actions and touch areas across sizes, themes and large text',
    (tester) async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      final metadata = AnimeMetadataController(
        client: FakeBangumiClient(),
        store: MemoryMetadataStore(),
      );
      final appearance = AppearanceController();
      addTearDown(metadata.dispose);
      addTearDown(appearance.dispose);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final videos = [
        for (var i = 0; i < 8; i++)
          LocalMedia(
            uri: Uri.file('/fixtures/Home-$i.mp4'),
            name: '很长的番剧标题与 English Title 名称 - 0$i.mp4',
          ),
      ];
      final records = [
        for (var i = 0; i < 4; i++)
          PlaybackRecord(
            media: videos[i],
            position: Duration(minutes: i + 1),
            duration: const Duration(minutes: 24),
            updatedAt: DateTime.utc(2026, 11, 6),
          ),
      ];
      var imports = 0, details = 0;
      final opened = <LocalMedia>[];
      final tabs = <int>[];
      for (final width in [360.0, 438.0, 834.0, 1210.0]) {
        final bottomInset = width < 600 ? 34.0 : 20.0;
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        for (final brightness in Brightness.values) {
          for (final scale in [1.0, 2.0]) {
            var selectedTab = 0;
            await tester.pumpWidget(
              MaterialApp(
                key: ValueKey('$width-$brightness-$scale'),
                theme: OrvexTheme.create(brightness)
                    .copyWith(platform: TargetPlatform.iOS),
                home: MediaQuery(
                  data: MediaQueryData(
                    size: Size(width, 900),
                    textScaler: TextScaler.linear(scale),
                    padding: EdgeInsets.only(bottom: bottomInset),
                    viewPadding: EdgeInsets.only(bottom: bottomInset),
                  ),
                  child: Scaffold(
                    extendBody: true,
                    bottomNavigationBar: StatefulBuilder(
                      builder: (context, setState) => LibraryTabBar(
                        selected: selectedTab,
                        onSelected: (index) {
                          tabs.add(index);
                          setState(() => selectedTab = index);
                        },
                      ),
                    ),
                    body: LibraryViews(
                      tab: 0,
                      videos: videos,
                      history: records,
                      loading: false,
                      picking: false,
                      showContinue: true,
                      query: '',
                      onQuery: (_) {},
                      onImport: () => imports++,
                      onOpen: opened.add,
                      onTab: tabs.add,
                      onRefresh: () async {},
                      onShowContinue: (_) {},
                      metadata: metadata,
                      onMetadata: (_, {group}) => details++,
                      appearance: appearance,
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(
              tester.getBottomLeft(find.byKey(const ValueKey('tab-0'))).dy,
              closeTo(880, 0.1),
              reason: 'the capsule ends 18 points above the screen edge',
            );
            await tester.tap(find.byTooltip('搜索媒体库'));
            expect(tabs.last, 1);
            await tester.tap(find.byTooltip('打开本地视频'));
            await tester.ensureVisible(
              find.byKey(const ValueKey('home-resume')),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(const ValueKey('home-resume')));
            expect(opened.last.resumeKey, videos.first.resumeKey);
            final rail = find.byKey(
              ValueKey('home-continue-${videos[1].resumeKey}'),
            );
            await tester.ensureVisible(rail);
            await tester.pumpAndSettle();
            await tester.tap(rail);
            expect(opened.last.resumeKey, videos[1].resumeKey);
            await tester.longPress(rail);
            final library = find.byKey(const ValueKey('home-library'));
            await Scrollable.ensureVisible(
              tester.element(library),
              alignment: 0.35,
            );
            await tester.pumpAndSettle();
            final tabCalls = tabs.length;
            await tester.tap(library);
            expect(tabs.length, tabCalls + 1);
            expect(tabs.last, 1);
            final recent = find.byKey(
              ValueKey('home-recent-${videos.last.resumeKey}'),
            );
            final home = find.byKey(const PageStorageKey('library-tab-0'));
            final scroll = tester.state<ScrollableState>(
              find
                  .descendant(of: home, matching: find.byType(Scrollable))
                  .first,
            );
            scroll.position.jumpTo(scroll.position.maxScrollExtent);
            await tester.pumpAndSettle();
            expect(
              tester.getBottomLeft(recent).dy,
              lessThan(tester.getTopLeft(find.byType(LibraryTabBar)).dy),
            );
            expect(
              tester.getBottomLeft(library).dy,
              lessThan(tester.getTopLeft(find.byType(LibraryTabBar)).dy),
            );
            await Scrollable.ensureVisible(
              tester.element(recent),
              alignment: 0.2,
            );
            await tester.pumpAndSettle();
            expect(
              tester.getTopLeft(recent).dy,
              greaterThanOrEqualTo(0),
              reason: '$width $brightness scale $scale after scrolling to card',
            );
            expect(
              tester.getBottomLeft(recent).dy,
              lessThan(tester.getTopLeft(find.byType(LibraryTabBar)).dy),
            );
            await tester.tap(recent);
            expect(opened.last.resumeKey, videos.last.resumeKey);
            final info = find.descendant(
              of: recent,
              matching: find.byTooltip('番剧资料'),
            );
            await tester.tap(info);
            final bar = find.byType(LibraryTabBar);
            final homeBar = tester.getRect(bar);
            for (var i = 0; i < 4; i++) {
              final target = find.byKey(ValueKey('tab-$i'));
              await tester.tap(target);
              await tester.pumpAndSettle();
              expect(tabs.last, i);
              expect(
                tester.getRect(bar),
                homeBar,
                reason: 'tab $i at $width $brightness scale $scale',
              );
              expect(
                tester.getSize(target).height,
                greaterThanOrEqualTo(OrvexMetrics.hitSize),
              );
              expect(
                tester.getSize(target).width,
                greaterThanOrEqualTo(OrvexMetrics.hitSize),
              );
              final icon = tester.getRect(
                find.descendant(of: target, matching: find.byType(Icon)),
              );
              final label = tester.getRect(
                find.descendant(of: target, matching: find.byType(Text)),
              );
              expect(
                icon.expandToInclude(label).center.dy,
                closeTo(tester.getCenter(target).dy, 0.5),
                reason: 'tab $i at $width $brightness scale $scale',
              );
            }
            expect(
              tester.takeException(),
              isNull,
              reason: '$width $brightness scale $scale',
            );
          }
        }
      }
      expect(imports, 16);
      expect(details, 32);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
