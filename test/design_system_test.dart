import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:orvex/app/orvex_app.dart';
import 'package:orvex/design/appearance_controller.dart';
import 'package:orvex/design/glass.dart';
import 'package:orvex/design/orvex_theme.dart';
import 'package:orvex/features/anime_metadata/application/anime_metadata_controller.dart';
import 'package:orvex/features/library/presentation/library_views.dart';
import 'package:orvex/features/media_sources/imported_file_store.dart';
import 'package:orvex/features/media_sources/local_file_source.dart';
import 'package:orvex/features/player/application/playback_session.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'support/fake_metadata.dart';
import 'support/fakes.dart';

class EmptyImports extends ImportedFileStore {
  @override
  Future<List<LocalMedia>> listVideos() async => [];
}

class SlowPreferences extends SharedPreferencesAsync {
  final read = Completer<String?>();
  @override
  Future<String?> getString(String key) => read.future;
  @override
  Future<bool?> getBool(String key) async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  test('appearance defaults to system and survives reopening', () async {
    final controller = AppearanceController();
    await controller.initialize();
    expect(controller.mode, ThemeMode.system);
    await controller.setReduceTransparency(true);
    controller.dispose();
    for (final mode in [ThemeMode.dark, ThemeMode.light, ThemeMode.system]) {
      final saved = AppearanceController();
      await saved.setMode(mode);
      saved.dispose();
      final reopened = AppearanceController();
      await reopened.initialize();
      expect(reopened.mode, mode);
      expect(reopened.reduceTransparency, isTrue);
      reopened.dispose();
    }
  });

  test(
    'late preference load preserves user choice and other saved settings',
    () async {
      final prefs = SlowPreferences();
      final controller = AppearanceController(preferences: prefs);
      final loading = controller.initialize();
      await controller.setMode(ThemeMode.dark);
      prefs.read.complete('light');
      await loading;
      expect(controller.mode, ThemeMode.dark);
      expect(controller.reduceTransparency, isTrue);
      await Future.wait([
        controller.setMode(ThemeMode.light),
        controller.setMode(ThemeMode.dark),
        controller.setMode(ThemeMode.system),
      ]);
      expect(
        await SharedPreferencesAsync().getString(AppearanceController.themeKey),
        'system',
      );
      controller.dispose();
    },
  );

  Future<AppearanceController> mount(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    double scale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final controller = AppearanceController();
    final metadata = AnimeMetadataController(
      client: FakeBangumiClient(),
      store: MemoryMetadataStore(),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appearanceProvider.overrideWithValue(controller),
          localFilesProvider.overrideWithValue(
            LocalFileSource(imports: EmptyImports()),
          ),
          animeMetadataProvider.overrideWithValue(metadata),
        ],
        child: const OrvexApp(),
      ),
    );
    await controller.initialize();
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      metadata.dispose();
    });
    return controller;
  }

  Future<void> chooseTheme(
    WidgetTester tester,
    ThemeMode mode, {
    ThemeMode? current,
  }) async {
    final picker = find.byKey(const ValueKey('theme-picker'));
    await tester.ensureVisible(picker);
    await tester.tap(picker);
    await tester.pumpAndSettle();
    if (current != null) {
      for (final option in ThemeMode.values) {
        final item = find.byKey(ValueKey('theme-${option.name}'));
        expect(
          tester.widget<CheckedPopupMenuItem<ThemeMode>>(item).checked,
          option == current,
        );
      }
    }
    await tester.tap(find.byKey(ValueKey('theme-${mode.name}')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'settings change theme immediately, persist, and follow system changes',
    (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final controller = await mount(tester);
      Brightness brightness() =>
          Theme.of(tester.element(find.byType(LibraryViews))).brightness;
      void expectOrbitMark() {
        final brands = find.byType(OrvexBrand);
        expect(brands, findsWidgets);
        for (final brand in brands.evaluate()) {
          final mark = find.descendant(
            of: find.byWidget(brand.widget),
            matching: find.byType(Image),
          );
          final image = tester.widget<Image>(mark);
          expect(
            (image.image as AssetImage).assetName,
            'assets/brand/orbit-mark.png',
          );
          expect(image.color, OrvexColors.of(brand).accent);
        }
      }

      expect(brightness(), Brightness.light);
      expectOrbitMark();
      await tester.tap(find.byKey(const ValueKey('tab-3')));
      await tester.pumpAndSettle();
      await chooseTheme(tester, ThemeMode.dark, current: ThemeMode.system);
      expect(brightness(), Brightness.dark);
      expect(find.widgetWithText(ListTile, 'Orvex'), findsOneWidget);
      expectOrbitMark();
      expect(
        await SharedPreferencesAsync().getString(AppearanceController.themeKey),
        'dark',
      );
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      await chooseTheme(tester, ThemeMode.light, current: ThemeMode.dark);
      expect(brightness(), Brightness.light);
      await chooseTheme(tester, ThemeMode.system, current: ThemeMode.light);
      expect(brightness(), Brightness.dark);
      expect(find.text('跟随系统'), findsOneWidget);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(brightness(), Brightness.light);
      await tester.tap(find.byKey(const ValueKey('reduce-transparency')));
      await tester.pumpAndSettle();
      expect(controller.reduceTransparency, isTrue);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'theme changes preserve the active playback engine and progress',
    (tester) async {
      final controller = AppearanceController();
      // Stream/session futures use real async scheduling; UI animation clocks stay controlled.
      final engine = (await tester.runAsync(() async => FakeEngine()))!;
      final session = (await tester.runAsync(
        () async => PlaybackSession(
          createEngine: () => engine,
          resumeStore: MemoryResumeStore(),
        ),
      ))!;
      final metadata = AnimeMetadataController(
        client: FakeBangumiClient(),
        store: MemoryMetadataStore(),
      );
      addTearDown(() async {
        await session.shutdown();
        session.dispose();
        controller.dispose();
        metadata.dispose();
        await engine.cleanUp();
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appearanceProvider.overrideWithValue(controller),
            sessionProvider.overrideWithValue(session),
            localFilesProvider.overrideWithValue(
              LocalFileSource(imports: EmptyImports()),
            ),
            animeMetadataProvider.overrideWithValue(metadata),
          ],
          child: const OrvexApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => session.open(
          LocalMedia(uri: Uri.file('/video.mp4'), name: 'video.mp4'),
        ),
      );
      await tester.runAsync(() async {
        engine.frameController.add(
          const PlaybackFrame(
            position: Duration(seconds: 38),
            duration: Duration(minutes: 2),
            playing: true,
          ),
        );
      });
      await tester.pump();
      await controller.setMode(ThemeMode.dark);
      await tester.pumpAndSettle();
      await controller.setMode(ThemeMode.light);
      await tester.pumpAndSettle();
      expect(identical(session.engine, engine), isTrue);
      expect(engine.disposed, isFalse);
      expect(session.frame.position, const Duration(seconds: 38));
      expect(session.frame.playing, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets('glass honors high contrast in ${brightness.name}', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: OrvexTheme.create(brightness),
          home: const MediaQuery(
            data: MediaQueryData(highContrast: true),
            child: GlassSurface(blur: true, child: Text('Readable surface')),
          ),
        ),
      );
      expect(find.byType(BackdropFilter), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Apple accessibility disables transparency and motion', (
    tester,
  ) async {
    const channel = MethodChannel('dev.orvex/appearance');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => {'reduceTransparency': true, 'reduceMotion': true},
    );
    final controller = AppearanceController();
    await controller.initialize();
    await tester.pump();
    expect(controller.systemReduceTransparency, isTrue);
    expect(controller.reduceMotion, isTrue);
    await tester.pumpWidget(
      AppearanceScope(
        controller: controller,
        child: MaterialApp(
          theme: OrvexTheme.create(Brightness.light),
          home: const GlassSurface(blur: true, child: Text('Opaque')),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);
    await controller.setReduceTransparency(true);
    await controller.setReduceTransparency(false);
    await tester.pumpAndSettle();
    expect(controller.reduceTransparency, isFalse);
    expect(controller.systemReduceTransparency, isTrue);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(
      OrvexMetrics.duration(tester.element(find.byType(GlassSurface))),
      Duration.zero,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('desktop uses a sidebar and keeps all four destinations', (
    tester,
  ) async {
    await mount(tester, size: const Size(1200, 800));
    expect(find.byType(LibrarySidebar), findsOneWidget);
    expect(find.byType(LibraryTabBar), findsNothing);
    for (var tab = 1; tab < 4; tab++) {
      await tester.tap(find.byKey(ValueKey('tab-$tab')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
    'Bangumi settings controls automatic requests and saves the preference',
    (tester) async {
      await mount(tester);
      await tester.tap(find.byKey(const ValueKey('tab-3')));
      await tester.pumpAndSettle();
      final metadata = ProviderScope.containerOf(
        tester.element(find.byType(OrvexApp)),
      ).read(animeMetadataProvider);
      final client = metadata.client as FakeBangumiClient;
      final toggle = find.byKey(const ValueKey('automatic-bangumi'));
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect((await metadata.store.read()).automatic, isFalse);
      await metadata.scan([
        LocalMedia(uri: Uri.file('/Match - 01.mp4'), name: 'Match - 01.mp4'),
      ]);
      expect(client.queries, isEmpty);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect((await metadata.store.read()).automatic, isTrue);
      expect(client.queries, ['Match']);
    },
  );

  testWidgets(
    'settings shows the installed version and opens licenses in a narrow window',
    (tester) async {
      PackageInfo.setMockInitialValues(
        appName: 'Orvex',
        packageName: 'dev.orvex.orvex',
        version: '2.7.3',
        buildNumber: '81',
        buildSignature: '',
      );
      await mount(tester, size: const Size(360, 640), scale: 2);
      await tester.tap(find.byKey(const ValueKey('tab-3')));
      await tester.pumpAndSettle();
      expect(find.text('导入本地视频'), findsNothing);
      expect(find.text('外挂字幕'), findsNothing);
      expect(find.text('自动保存播放进度'), findsNothing);
      final settings = find.byKey(const PageStorageKey('library-tab-3'));
      final license = find.text('开源许可');
      final position = tester
          .state<ScrollableState>(
            find
                .descendant(of: settings, matching: find.byType(Scrollable))
                .first,
          )
          .position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('版本 2.7.3'), findsOneWidget);
      expect(license.hitTestable(), findsOneWidget);
      await tester.tap(license);
      await tester.pumpAndSettle();
      expect(find.byType(LicensePage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'small landscape and larger text keep navigation and settings usable',
    (tester) async {
      await mount(tester, size: const Size(640, 360), scale: 1.3);
      await tester.tap(find.byKey(const ValueKey('tab-3')));
      await tester.pumpAndSettle();
      await chooseTheme(tester, ThemeMode.dark, current: ThemeMode.system);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('tab-0')).hitTestable(), findsOneWidget);
    },
  );
}
