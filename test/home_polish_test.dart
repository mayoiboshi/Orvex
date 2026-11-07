import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/design/appearance_controller.dart';
import 'package:orvex/design/orvex_theme.dart';
import 'package:orvex/features/anime_metadata/application/anime_metadata_controller.dart';
import 'package:orvex/features/library/domain/playback_record.dart';
import 'package:orvex/features/library/presentation/library_views.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';

import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'support/fake_metadata.dart';

void main() {
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
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        for (final brightness in Brightness.values) {
          for (final scale in [1.0, 2.0]) {
            await tester.pumpWidget(
              MaterialApp(
                key: ValueKey('$width-$brightness-$scale'),
                theme: OrvexTheme.create(brightness),
                home: MediaQuery(
                  data: MediaQueryData(
                    size: Size(width, 900),
                    textScaler: TextScaler.linear(scale),
                    padding: const EdgeInsets.only(bottom: 34),
                    viewPadding: const EdgeInsets.only(bottom: 34),
                  ),
                  child: Scaffold(
                    extendBody: true,
                    bottomNavigationBar: LibraryTabBar(
                      selected: 0,
                      onSelected: tabs.add,
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
                      onMetadata: (_) => details++,
                      appearance: appearance,
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
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
            for (var i = 0; i < 4; i++) {
              final target = find.byKey(ValueKey('tab-$i'));
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
              await tester.tap(target);
              expect(tabs.last, i);
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
