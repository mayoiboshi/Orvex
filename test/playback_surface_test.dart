import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/features/player/application/playback_session.dart';
import 'package:orvex/features/player/domain/playback_defaults.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:orvex/features/player/infrastructure/player_brightness.dart';
import 'package:orvex/features/player/infrastructure/player_system_volume.dart';
import 'package:orvex/features/player/presentation/volume_indicator.dart';
import 'package:orvex/features/player/presentation/playback_surface.dart';
import 'package:orvex/features/player/presentation/subtitle_style_settings.dart';

import 'support/fakes.dart';

// These tests exercise visible interaction and command boundaries. Session
// ordering, persistence and native decoding have separate behavioral tests.
class SurfaceSession extends PlaybackSession {
  SurfaceSession(this.player)
    : super(createEngine: () => player, resumeStore: MemoryResumeStore()) {
    media = LocalMedia(uri: Uri.file('/video-a.mp4'), name: '视频 A.mp4');
    update();
  }
  FakeEngine player;
  final seeks = <Duration>[];
  final rates = <double>[];
  final volumes = <double>[];
  final audio = <String>[];
  final subtitles = <String>[];
  int toggles = 0;
  bool acknowledgeSeek = true;

  @override
  PlaybackEngine get engine => player;
  @override
  bool get ready => true;

  void update({
    int? seconds,
    bool? playing,
    bool buffering = false,
    double? rate,
    double? volume,
    List<MediaTrack>? subtitleTracks,
  }) {
    frame = PlaybackFrame(
      position: Duration(seconds: seconds ?? 30),
      duration: const Duration(minutes: 2),
      playing: playing ?? true,
      buffering: buffering,
      rate: rate ?? frame.rate,
      volume: volume ?? frame.volume,
      subtitleTracks: subtitleTracks ?? frame.subtitleTracks,
    );
    notifyListeners();
  }

  @override
  Future<void> seek(Duration target) async {
    seeks.add(target);
    if (acknowledgeSeek) update(seconds: target.inSeconds);
  }

  @override
  Future<void> setRate(double rate) async {
    rates.add(rate);
    update(
      seconds: frame.position.inSeconds,
      playing: frame.playing,
      rate: rate,
    );
  }

  @override
  Future<void> setVolume(double volume) async {
    volumes.add(volume);
    update(volume: volume);
  }

  @override
  Future<void> togglePause() async {
    toggles++;
    update(playing: !frame.playing);
  }

  @override
  Future<void> selectAudio(String id) async => audio.add(id);
  @override
  Future<void> selectSubtitle(String id) async => subtitles.add(id);
}

class DisplayStub extends PlayerBrightness {
  double? value = 0.5;
  bool fail = false;
  final writes = <double>[];
  int restores = 0;
  @override
  Future<double?> read() async => value;
  @override
  Future<void> set(double value) async {
    if (fail) throw StateError('display unavailable');
    writes.add(value);
  }

  @override
  Future<void> restore() async => restores++;
}

class VolumeStub extends PlayerSystemVolume {
  final events = StreamController<SystemVolumeReading>.broadcast(sync: true);
  final presentations = <bool>[];
  final writes = <double>[];

  @override
  Future<bool> available() async => true;
  @override
  Stream<SystemVolumeReading> get changes => events.stream;
  @override
  Future<void> present(bool active) async => presentations.add(active);
  @override
  Future<bool> set(double level) async {
    writes.add(level);
    events.add(SystemVolumeReading(level));
    return true;
  }
}

void main() {
  Future<SurfaceSession> mount(
    WidgetTester tester, {
    double width = 320,
    double height = 180,
    bool playing = true,
    bool fullscreen = false,
    bool accessibleNavigation = false,
    TextScaler textScaler = TextScaler.noScaling,
    ThemeData? theme,
    EdgeInsets padding = EdgeInsets.zero,
    VoidCallback? onFullscreen,
    VoidCallback? onSubtitle,
    VoidCallback? onEpisodes,
    DisplayStub? display,
    VolumeStub? volume,
    Widget? input,
  }) async {
    final engine = FakeEngine();
    final session = SurfaceSession(engine)..update(playing: playing);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? ThemeData.dark(),
        home: Scaffold(
          body: Focus(
            autofocus: true,
            child: MediaQuery(
              data: MediaQueryData(
                padding: padding,
                accessibleNavigation: accessibleNavigation,
                textScaler: textScaler,
              ),
              child: Column(
                children: [
                  Center(
                    child: SizedBox(
                      width: width,
                      height: height,
                      child: PlaybackSurface(
                        session: session,
                        fullscreen: fullscreen,
                        onFullscreen: onFullscreen ?? () {},
                        onSubtitle: onSubtitle ?? () {},
                        onEpisodes: onEpisodes,
                        brightness: display ?? DisplayStub(),
                        systemVolume: volume,
                      ),
                    ),
                  ),
                  ?input,
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
      await engine.cleanUp();
      await tester.pump();
    });
    return session;
  }

  Finder getProgress() => find.byKey(const ValueKey('playback-progress'));
  testWidgets(
    'fullscreen subtitle menu opens style settings and preserves subtitle choices',
    (tester) async {
      var external = false;
      final session = await mount(
        tester,
        width: 740,
        height: 350,
        fullscreen: true,
        playing: false,
        theme: ThemeData.light(),
        onSubtitle: () => external = true,
      );
      session.update(
        playing: false,
        subtitleTracks: const [MediaTrack('3', '中文字幕')],
      );
      await tester.pump();
      await tester.tap(find.byTooltip('字幕'));
      await tester.pumpAndSettle();
      expect(find.text('自动选择'), findsOneWidget);
      expect(find.text('关闭字幕'), findsOneWidget);
      expect(find.text('打开外挂字幕…'), findsOneWidget);
      final panel = find.byKey(const ValueKey('subtitle-menu-panel'));
      final route = ModalRoute.of(tester.element(panel));
      final right = tester.getRect(panel).right;
      expect(Theme.of(tester.element(panel)).brightness, Brightness.dark);
      await tester.tap(find.text('字幕设置…'));
      await tester.pumpAndSettle();
      expect(find.byType(SubtitleStyleSettings), findsOneWidget);
      expect(find.text('字幕设置'), findsOneWidget);
      expect(ModalRoute.of(tester.element(panel)), same(route));
      expect(tester.getRect(panel).right, right);
      expect(find.byTooltip('返回字幕轨道'), findsOneWidget);
      expect(session.toggles, 0);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(SubtitleStyleSettings), findsNothing);
      expect(find.text('关闭字幕'), findsOneWidget);
      await tester.tap(find.text('关闭字幕'));
      await tester.pumpAndSettle();
      expect(session.subtitles, contains('no'));
      await tester.tap(find.byTooltip('字幕'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('中文字幕'));
      await tester.pumpAndSettle();
      expect(session.subtitles, contains('3'));
      await tester.tap(find.byTooltip('字幕'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('打开外挂字幕…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开外挂字幕…'));
      await tester.pumpAndSettle();
      expect(external, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('subtitle settings suspend and then restore control auto-hide', (
    tester,
  ) async {
    await mount(
      tester,
      width: 740,
      height: 350,
      fullscreen: true,
      playing: true,
    );
    await tester.tap(find.byTooltip('字幕'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('字幕设置…'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(const ValueKey('playback-controls')),
          )
          .opacity,
      1,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('关闭字幕'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(const ValueKey('playback-controls')),
          )
          .opacity,
      0,
    );
  });

  testWidgets(
    'subtitle settings stay in one anchored route and outside click closes it',
    (tester) async {
      await mount(
        tester,
        width: 740,
        height: 350,
        fullscreen: true,
        playing: false,
      );
      await tester.tap(find.byTooltip('字幕'));
      await tester.pumpAndSettle();
      final panel = find.byKey(const ValueKey('subtitle-menu-panel'));
      final route = ModalRoute.of(tester.element(panel));
      final right = tester.getRect(panel).right;
      await tester.tap(find.text('字幕设置…'));
      await tester.pumpAndSettle();
      expect(ModalRoute.of(tester.element(panel)), same(route));
      expect(tester.getRect(panel).right, right);
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      expect(panel, findsNothing);
      expect(find.byType(SubtitleStyleSettings), findsNothing);
    },
  );

  testWidgets(
    'subtitle menu closes on resize, background, and session switch even with color list open',
    (tester) async {
      final session = await mount(
        tester,
        width: 740,
        height: 350,
        fullscreen: true,
        playing: false,
      );
      Future<void> show() async {
        await tester.tap(find.byTooltip('字幕'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('subtitle-menu-panel')),
          findsOneWidget,
        );
      }

      await show();
      tester.binding.handleMetricsChanged();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('subtitle-menu-panel')), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      await show();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('subtitle-menu-panel')), findsNothing);
      await show();
      await tester.tap(find.text('字幕设置…'));
      await tester.pumpAndSettle();
      final color = find.byType(DropdownButton<String>).first;
      await tester.ensureVisible(color);
      await tester.pumpAndSettle();
      await tester.tap(color);
      await tester.pumpAndSettle();
      expect(find.text('黄色'), findsWidgets);
      final replacement = FakeEngine();
      session.player = replacement;
      session.update(playing: false);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('subtitle-menu-panel')), findsNothing);
      expect(find.byType(SubtitleStyleSettings), findsNothing);
      expect(find.text('黄色'), findsNothing);
      await replacement.cleanUp();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'subtitle menu remains within a small screen with large text and keyboard return',
    (tester) async {
      tester.view.physicalSize = const Size(400, 240);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await mount(
        tester,
        width: 320,
        height: 180,
        fullscreen: true,
        playing: false,
      );
      await tester.tap(find.byTooltip('播放设置'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('字幕'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('字幕'));
      await tester.pumpAndSettle();
      final panel = find.byKey(const ValueKey('subtitle-menu-panel'));
      final rect = tester.getRect(panel);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(400));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(240));
      await tester.ensureVisible(find.text('字幕设置…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('字幕设置…'));
      await tester.pumpAndSettle();
      expect(find.byType(SubtitleStyleSettings), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(SubtitleStyleSettings), findsNothing);
      expect(find.text('关闭字幕'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final fullscreen in [false, true]) {
    testWidgets(
      'small ${fullscreen ? 'fullscreen' : 'inline'} subtitle settings return to playback settings',
      (tester) async {
        final session = await mount(
          tester,
          width: 320,
          height: 180,
          fullscreen: fullscreen,
          playing: true,
        );
        await tester.tap(find.byTooltip('播放设置'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('字幕'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('字幕设置…'));
        await tester.pumpAndSettle();
        expect(find.byType(SubtitleStyleSettings), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(SubtitleStyleSettings), findsNothing);
        expect(find.text('播放设置'), findsOneWidget);
        expect(find.text('关闭字幕'), findsOneWidget);
        await tester.tap(find.text('关闭字幕'));
        await tester.pumpAndSettle();
        expect(session.subtitles, contains('no'));
        await tester.pump(const Duration(seconds: 4));
        expect(
          tester
              .widget<AnimatedOpacity>(
                find.byKey(const ValueKey('playback-controls')),
              )
              .opacity,
          1,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('fullscreen episode entry follows speed', (tester) async {
    var opened = false;
    await mount(
      tester,
      width: 740,
      height: 350,
      fullscreen: true,
      onEpisodes: () => opened = true,
    );
    final speed = find.byTooltip('播放速度');
    final episodes = find.byTooltip('选择集数');
    expect(
      tester.getRect(episodes).left,
      greaterThanOrEqualTo(tester.getRect(speed).right),
    );
    await tester.tap(episodes);
    expect(opened, isTrue);
  });
  testWidgets('small fullscreen retains episode entry in settings', (
    tester,
  ) async {
    var opened = false;
    await mount(
      tester,
      width: 320,
      height: 180,
      fullscreen: true,
      onEpisodes: () => opened = true,
    );
    expect(find.byTooltip('选择集数'), findsNothing);
    await tester.tap(find.byTooltip('播放设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择集数'));
    await tester.pumpAndSettle();
    expect(opened, isTrue);
  });
  double opacity(WidgetTester tester) => tester
      .widget<AnimatedOpacity>(find.byKey(const ValueKey('playback-controls')))
      .opacity;
  Offset point(WidgetTester tester, double x, double y) {
    final rect = tester.getRect(find.byType(PlaybackSurface));
    return Offset(rect.left + rect.width * x, rect.top + rect.height * y);
  }

  Future<void> doubleTap(WidgetTester tester, Offset position) async {
    await tester.tapAt(position);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(position);
    await tester.pump(const Duration(milliseconds: 350));
  }

  testWidgets('controls fade after idle, pause retains them, taps toggle', (
    tester,
  ) async {
    final session = await mount(tester);
    await tester.pump(const Duration(milliseconds: 3300));
    expect(opacity(tester), 0);
    session.update(playing: false);
    await tester.pump(const Duration(milliseconds: 200));
    expect(opacity(tester), 1);
    await tester.pump(const Duration(seconds: 5));
    expect(opacity(tester), 1);
    final blank = point(tester, 0.08, 0.39);
    await tester.tapAt(blank);
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      opacity(tester),
      0,
      reason: 'manual hiding is still allowed on pause',
    );
    await tester.tapAt(blank);
    await tester.pump(const Duration(milliseconds: 400));
    expect(opacity(tester), 1);
    await tester.tap(find.byTooltip('播放'));
    await tester.pump();
    expect(session.toggles, 1);
    await tester.pump(const Duration(milliseconds: 3300));
    expect(opacity(tester), 0);
  });

  testWidgets('edge controls leave the center open without moving video', (
    tester,
  ) async {
    await mount(tester, width: 740, height: 480, fullscreen: true);
    final video = find.byKey(const ValueKey('video-gestures'));
    final dock = find.byKey(const ValueKey('playback-bottom-controls'));
    final rect = tester.getRect(video);
    expect(tester.getRect(dock).top, greaterThan(rect.center.dy));
    expect(tester.getRect(dock).bottom, rect.bottom);
    expect(
      tester.getCenter(find.byTooltip('暂停')).dy,
      greaterThan(rect.center.dy),
    );
    expect(tester.getSize(getProgress()).height, greaterThanOrEqualTo(44));
    expect(find.text('字幕'), findsNothing);
    expect(find.text('音轨'), findsNothing);
    expect(find.byTooltip('字幕'), findsOneWidget);
    expect(find.byTooltip('音轨'), findsOneWidget);
    await tester.tap(find.byTooltip('字幕'));
    await tester.pumpAndSettle();
    expect(find.text('关闭字幕'), findsOneWidget);
    await tester.tap(find.text('关闭字幕'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 3400));
    expect(opacity(tester), 0);
    expect(tester.getRect(video), rect);
    expect(find.byTooltip('暂停').hitTestable(), findsNothing);
    await tester.tapAt(point(tester, 0.5, 0.39));
    await tester.pump(const Duration(milliseconds: 400));
    expect(opacity(tester), 1);
    expect(tester.getRect(video), rect);
  });

  // Fullscreen controls reserve eight pixels on each side.
  for (final width in [615.0, 616.0, 715.0, 716.0]) {
    testWidgets('track controls use icons at width $width with large text', (
      tester,
    ) async {
      await mount(
        tester,
        width: width,
        height: 400,
        fullscreen: true,
        textScaler: const TextScaler.linear(1.5),
      );
      expect(find.text('音轨'), findsNothing);
      expect(find.text('字幕'), findsNothing);
      for (final label in ['音轨', '字幕']) {
        final button = find.byTooltip(label);
        expect(button, width >= 616 ? findsOneWidget : findsNothing);
        if (width >= 616) {
          final size = tester.getSize(button);
          expect(size.width, greaterThanOrEqualTo(44));
          expect(size.height, greaterThanOrEqualTo(44));
        }
      }
    });
  }

  for (final width in [320.0, 740.0]) {
    testWidgets(
      'full screen transport is centered and corners remain accessible at $width',
      (tester) async {
        var fullscreens = 0;
        final session = await mount(
          tester,
          width: width,
          height: 300,
          fullscreen: true,
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 20),
          onFullscreen: () => fullscreens++,
        );
        final surface = tester.getRect(find.byType(PlaybackSurface));
        final settings = tester.getRect(find.byTooltip('播放设置'));
        final fullscreen = tester.getRect(find.byTooltip('退出全屏').last);
        final previous = tester.getRect(find.byTooltip('后退 10 秒'));
        final play = tester.getRect(find.byTooltip('暂停'));
        final next = tester.getRect(find.byTooltip('快进 10 秒'));
        final progress = tester.getRect(getProgress());
        expect(settings.top, greaterThanOrEqualTo(surface.top + 16));
        expect(settings.right, lessThanOrEqualTo(surface.right - 12));
        expect(fullscreen.right, lessThanOrEqualTo(surface.right - 12));
        expect(fullscreen.bottom, lessThanOrEqualTo(surface.bottom - 20));
        expect(settings.center.dx, fullscreen.center.dx);
        expect(play.center.dx, closeTo(surface.center.dx, 0.1));
        expect(previous.right, lessThanOrEqualTo(play.left));
        expect(play.right, lessThanOrEqualTo(next.left));
        expect(next.right, lessThanOrEqualTo(fullscreen.left));
        expect(progress.bottom, lessThanOrEqualTo(play.top));
        await tester.tap(find.byTooltip('后退 10 秒'));
        await tester.pump();
        expect(session.seeks, [const Duration(seconds: 20)]);
        await tester.tap(find.byTooltip('退出全屏').last);
        expect(fullscreens, 1);
        await tester.tap(find.byTooltip('播放设置'));
        await tester.pumpAndSettle();
        expect(find.text('播放设置'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'narrow short full screen keeps corner and transport targets separate',
    (tester) async {
      var fullscreens = 0;
      final session = await mount(
        tester,
        width: 220,
        height: 200,
        fullscreen: true,
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 20),
        onFullscreen: () => fullscreens++,
      );
      final settings = tester.getRect(find.byTooltip('播放设置'));
      final lock = tester.getRect(find.byTooltip('锁定屏幕'));
      final progress = tester.getRect(getProgress());
      final back = tester.getRect(find.byTooltip('后退 10 秒'));
      final next = tester.getRect(find.byTooltip('快进 10 秒'));
      final fullscreen = tester.getRect(find.byTooltip('退出全屏').last);
      expect(settings.bottom, lessThanOrEqualTo(progress.top));
      expect(lock.bottom, lessThanOrEqualTo(progress.top));
      expect(next.right, lessThanOrEqualTo(fullscreen.left));
      expect(back.width, greaterThanOrEqualTo(44));
      expect(fullscreen.width, greaterThanOrEqualTo(44));
      await tester.tap(find.byTooltip('快进 10 秒'));
      await tester.pump();
      expect(session.seeks, [const Duration(seconds: 40)]);
      await tester.tap(find.byTooltip('退出全屏').last);
      expect(fullscreens, 1);
      await tester.tap(find.byTooltip('锁定屏幕'));
      await tester.pump();
      expect(find.byTooltip('解除锁定'), findsOneWidget);
      await tester.tap(find.byTooltip('解除锁定'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'very narrow screen keeps playback and settings transport available',
    (tester) async {
      final session = await mount(
        tester,
        width: 190,
        height: 200,
        fullscreen: true,
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 20),
      );
      final progress = tester.getRect(getProgress());
      expect(
        tester.getRect(find.byTooltip('锁定屏幕')).bottom,
        lessThanOrEqualTo(progress.top),
      );
      expect(find.byTooltip('快进 10 秒'), findsNothing);
      await tester.tap(find.byTooltip('播放设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('快进 10 秒'));
      await tester.pump();
      expect(session.seeks, [const Duration(seconds: 40)]);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('buffering preserves a hidden overlay and a seek preview', (
    tester,
  ) async {
    final session = await mount(tester);
    await tester.pump(const Duration(seconds: 4));
    expect(opacity(tester), 0);
    session.update(playing: false, buffering: true);
    await tester.pump();
    expect(opacity(tester), 0);
    session.update();
    await tester.pump();
    await tester.tapAt(point(tester, 0.5, 0.39));
    await tester.pump(const Duration(milliseconds: 400));
    final drag = await tester.startGesture(tester.getCenter(getProgress()));
    await drag.moveBy(const Offset(32, 0));
    await tester.pump();
    final preview = tester.widget<Slider>(getProgress()).value;
    session.update(playing: false, buffering: true);
    await tester.pump(const Duration(seconds: 4));
    expect(tester.widget<Slider>(getProgress()).value, preview);
    expect(opacity(tester), 1);
    await drag.up();
    await tester.pump();
    expect(session.seeks, hasLength(1));
  });

  testWidgets('accessible navigation keeps controls visible until dismissed', (
    tester,
  ) async {
    await mount(tester, accessibleNavigation: true);
    await tester.pump(const Duration(seconds: 5));
    expect(opacity(tester), 1);
    await tester.tapAt(point(tester, 0.5, 0.39));
    await tester.pump(const Duration(milliseconds: 400));
    expect(opacity(tester), 0);
  });

  testWidgets('keyboard focus keeps the controls awake', (tester) async {
    final manager = FocusManager.instance;
    final previousStrategy = manager.highlightStrategy;
    manager.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
    addTearDown(() => manager.highlightStrategy = previousStrategy);
    await mount(tester, fullscreen: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(manager.primaryFocus?.debugLabel, isNot('Video controls'));
    await tester.pump(const Duration(seconds: 5));
    expect(opacity(tester), 1);
    await tester.tapAt(point(tester, 0.5, 0.39));
    await tester.pump(const Duration(milliseconds: 400));
    expect(opacity(tester), 0);
  });

  testWidgets('mobile double tap toggles once at the left, center and right', (
    tester,
  ) async {
    final session = await mount(tester);
    for (final x in [0.08, 0.5, 0.92]) {
      final previous = session.toggles;
      final target = point(tester, x, 0.39);
      await doubleTap(tester, target);
      expect(session.frame.playing, isFalse);
      expect(session.toggles, previous + 1);
      expect(opacity(tester), 1);
      await doubleTap(tester, target);
      expect(session.frame.playing, isTrue);
      expect(session.toggles, previous + 2);
      expect(opacity(tester), 1);
    }
    expect(session.seeks, isEmpty);
    expect(session.rates, isEmpty);
  });

  testWidgets('horizontal drag wins over tap and hold on either side', (
    tester,
  ) async {
    final session = await mount(tester, width: 600);
    for (final x in [0.08, 0.92]) {
      final drag = await tester.startGesture(point(tester, x, 0.39));
      final offset = Offset(x < 0.5 ? 22 : -22, 0);
      await drag.moveBy(offset);
      await drag.moveBy(offset);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await drag.up();
      await tester.pump();
    }
    expect(session.seeks, hasLength(2));
    expect(session.rates, isEmpty);
    expect(session.toggles, 0);
  });

  testWidgets(
    'mobile gesture preference leaves transport buttons using the chosen step',
    (tester) async {
      final session = await mount(tester, width: 640);
      session.currentDefaults = const PlaybackDefaults(
        skipSeconds: 5,
        touchGestures: false,
      );
      session.update();
      await tester.pump();
      await doubleTap(tester, point(tester, 0.92, 0.39));
      expect(session.seeks, isEmpty);
      expect(find.byTooltip('快进 5 秒'), findsNothing);
      await tester.tap(find.byTooltip('播放设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('快进 5 秒'));
      await tester.pump();
      expect(session.seeks, [const Duration(seconds: 35)]);
      expect(session.toggles, 0);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'hold across the video restores chosen rate on release and cancel',
    (tester) async {
      final session = await mount(tester);
      session.update(rate: 1.5);
      final delay = kLongPressTimeout + const Duration(milliseconds: 50);
      for (final x in [0.08, 0.5, 0.92]) {
        final press = await tester.startGesture(point(tester, x, 0.39));
        await tester.pump(delay);
        expect(session.frame.rate, 2);
        expect(find.text('临时 2 倍速'), findsOneWidget);
        if (x == 0.5) {
          await tester.pump(const Duration(seconds: 4));
          expect(opacity(tester), 1);
          await press.cancel();
        } else {
          await press.up();
        }
        await tester.pump();
        expect(session.frame.rate, 1.5);
      }
      expect(session.rates, [2, 1.5, 2, 1.5, 2, 1.5]);
      expect(session.volumes, isEmpty);
      expect(session.seeks, isEmpty);
      expect(session.toggles, 0);
    },
  );

  testWidgets('long press resets on pause, lifecycle and view disposal', (
    tester,
  ) async {
    final display = DisplayStub();
    final session = await mount(tester, display: display);
    session.update(rate: 1.25);
    var press = await tester.startGesture(point(tester, 0.5, 0.39));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    session.update(playing: false);
    await tester.pump();
    expect(session.rates, [2, 1.25]);
    await press.up();
    session.update();
    press = await tester.startGesture(point(tester, 0.5, 0.39));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(session.rates, [2, 1.25, 2, 1.25]);
    expect(display.restores, 1);
    await press.cancel();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    press = await tester.startGesture(point(tester, 0.5, 0.39));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(session.rates, [2, 1.25, 2, 1.25, 2, 1.25]);
    await press.cancel();
  });

  testWidgets('background before long press recognition cannot start 2x', (
    tester,
  ) async {
    final session = await mount(tester);
    final press = await tester.startGesture(point(tester, 0.5, 0.39));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    expect(session.rates, isEmpty);
    await press.cancel();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  });

  testWidgets('slider keeps target during playback updates, seeks on release', (
    tester,
  ) async {
    final session = await mount(tester)
      ..acknowledgeSeek = false;
    final rect = tester.getRect(getProgress());
    final drag = await tester.startGesture(rect.center);
    await drag.moveBy(const Offset(50, 0));
    await tester.pump();
    final preview = tester.widget<Slider>(getProgress()).value;
    expect(session.seeks, isEmpty);
    session.update(seconds: 31);
    await tester.pump();
    expect(tester.widget<Slider>(getProgress()).value, preview);
    expect(find.byKey(const ValueKey('gesture-feedback')), findsOneWidget);
    await drag.up();
    await tester.pump();
    expect(session.seeks, hasLength(1));
    expect(session.seeks.single.inMilliseconds, preview.round());
    expect(tester.widget<Slider>(getProgress()).value, preview);
    session.update(seconds: session.seeks.single.inSeconds);
    await tester.pump();
    expect(find.byKey(const ValueKey('gesture-feedback')), findsNothing);
  });

  testWidgets('slider cancellation and backgrounding do not commit a seek', (
    tester,
  ) async {
    final session = await mount(tester);
    var drag = await tester.startGesture(tester.getCenter(getProgress()));
    await drag.moveBy(const Offset(40, 0));
    await tester.pump();
    await drag.cancel();
    await tester.pump();
    expect(session.seeks, isEmpty);
    expect(find.byKey(const ValueKey('gesture-feedback')), findsNothing);
    drag = await tester.startGesture(tester.getCenter(getProgress()));
    await drag.moveBy(const Offset(40, 0));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await drag.up();
    await tester.pump();
    expect(session.seeks, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  });

  testWidgets(
    'switching engine clears preview and does not restore into new video',
    (tester) async {
      final session = await mount(tester);
      final press = await tester.startGesture(point(tester, 0.5, 0.39));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      final nextEngine = FakeEngine();
      session.player = nextEngine;
      session.media = LocalMedia(
        uri: Uri.file('/video-b.mp4'),
        name: '视频 B.mp4',
      );
      session.update(rate: 1);
      await press.up();
      await tester.pump();
      expect(session.rates, [
        2,
      ], reason: 'old speed must not affect a new engine');
      expect(find.text('视频 B.mp4'), findsOneWidget);
      expect(find.text('临时 2 倍速'), findsNothing);
      final drag = await tester.startGesture(tester.getCenter(getProgress()));
      await drag.moveBy(const Offset(30, 0));
      await tester.pump();
      session.player = FakeEngine();
      session.update();
      await drag.up();
      await tester.pump();
      expect(session.seeks, isEmpty);
      await nextEngine.cleanUp();
      await session.player.cleanUp();
    },
  );

  testWidgets('vertical gestures adjust the correct level without seeking', (
    tester,
  ) async {
    final display = DisplayStub();
    final session = await mount(
      tester,
      width: 600,
      height: 340,
      display: display,
    );
    session.update(volume: 40);
    await tester.pump();
    var drag = await tester.startGesture(point(tester, 0.85, 0.39));
    await drag.moveBy(const Offset(0, -20));
    await drag.moveBy(const Offset(0, -50));
    await tester.pump();
    expect(session.volumes, isNotEmpty);
    expect(session.volumes.last, greaterThan(40));
    expect(find.byType(VolumeIndicator), findsOneWidget);
    await drag.up();
    drag = await tester.startGesture(point(tester, 0.15, 0.39));
    await drag.moveBy(const Offset(0, -20));
    await drag.moveBy(const Offset(0, -50));
    await tester.pump();
    expect(display.writes.last, greaterThan(0.5));
    expect(find.textContaining('亮度 '), findsOneWidget);
    await drag.cancel();
    await tester.pump(const Duration(milliseconds: 400));
    expect(session.seeks, isEmpty);
    expect(session.rates, isEmpty);
  });

  testWidgets('system volume drives the HUD, drag, and settings', (
    tester,
  ) async {
    final volume = VolumeStub();
    addTearDown(volume.events.close);
    final session = await mount(tester, height: 320, volume: volume);
    final hud = find.byType(VolumeIndicator);
    volume.events.add(const SystemVolumeReading(0.3, reset: true));
    await tester.pump();
    expect(volume.presentations, [true]);
    expect(hud, findsNothing);

    volume.events.add(const SystemVolumeReading(0.4, delta: 0.1));
    await tester.pump();
    expect(tester.widget<VolumeIndicator>(hud).volume, 40);
    expect(tester.widget<VolumeIndicator>(hud).steps, isNull);
    volume.events.add(const SystemVolumeReading(0.5, delta: 0.1));
    await tester.pump();
    expect(tester.widget<VolumeIndicator>(hud).steps, 10);
    await tester.pump(const Duration(milliseconds: 1200));
    expect(hud, findsNothing);

    final drag = await tester.startGesture(point(tester, 0.85, 0.39));
    await drag.moveBy(const Offset(0, -24));
    await drag.moveBy(const Offset(0, -40));
    await tester.pump();
    await drag.up();
    await tester.pump();
    expect(volume.writes.last, greaterThan(0.5));
    expect(session.volumes, isEmpty);
    expect(
      tester.widget<VolumeIndicator>(hud).volume,
      closeTo(volume.writes.last * 100, 0.01),
    );
    expect(tester.widget<VolumeIndicator>(hud).steps, 10);

    await tester.tap(find.byTooltip('播放设置'));
    await tester.pumpAndSettle();
    expect(find.textContaining('系统音量 '), findsOneWidget);
    final slider = find.byKey(const ValueKey('settings-volume'));
    await tester.ensureVisible(slider);
    await tester.tapAt(tester.getRect(slider).centerLeft + const Offset(50, 0));
    await tester.pumpAndSettle();
    expect(volume.writes.last, lessThan(0.5));
    final beforeMute = volume.writes.last;
    final mute = find.byTooltip('静音');
    await tester.ensureVisible(mute);
    await tester.tap(mute);
    await tester.pumpAndSettle();
    expect(volume.writes.last, 0);
    await tester.tap(find.byTooltip('取消静音'));
    await tester.pumpAndSettle();
    expect(volume.writes.last, closeTo(beforeMute, 0.0001));
    expect(session.volumes, isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(volume.events.hasListener, isFalse);
  });

  testWidgets('paused system changes stay quiet and a new route clears ticks', (
    tester,
  ) async {
    final volume = VolumeStub();
    addTearDown(volume.events.close);
    final session = await mount(tester, volume: volume, playing: false);
    final hud = find.byType(VolumeIndicator);
    volume.events.add(const SystemVolumeReading(0.4, reset: true));
    volume.events.add(const SystemVolumeReading(0.4625, delta: 0.0625));
    volume.events.add(const SystemVolumeReading(0.525, delta: 0.0625));
    await tester.pump();
    expect(volume.presentations, isEmpty);
    expect(hud, findsNothing);

    session.update();
    volume.events.add(const SystemVolumeReading(0.5875, delta: 0.0625));
    await tester.pump();
    expect(volume.presentations, [true]);
    expect(tester.widget<VolumeIndicator>(hud).steps, 16);
    volume.events.add(const SystemVolumeReading(0.2, reset: true));
    await tester.pump();
    expect(tester.widget<VolumeIndicator>(hud).steps, isNull);
    expect(tester.widget<VolumeIndicator>(hud).volume, 20);

    session.update(playing: false);
    await tester.pump();
    expect(volume.presentations, [true, false]);
  });

  testWidgets(
    'unsupported brightness degrades and settings operate real controls',
    (tester) async {
      final display = DisplayStub()..value = null;
      var subtitles = 0;
      final session = await mount(
        tester,
        display: display,
        onSubtitle: () => subtitles++,
      );
      await tester.dragFrom(point(tester, 0.15, 0.39), const Offset(0, -40));
      expect(display.writes, isEmpty);
      await tester.tap(find.byTooltip('播放设置'));
      await tester.pumpAndSettle();
      expect(find.text('亮度请使用系统控制'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      expect(opacity(tester), 1, reason: 'settings keep controls awake');
      await tester.tap(find.byTooltip('音轨'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.ancestor(
          of: find.text('关闭音轨'),
          matching: find.byType(CheckedPopupMenuItem<String>),
        ),
      );
      await tester.pumpAndSettle();
      expect(session.audio, ['no']);
      await tester.tap(find.text('打开外挂字幕…'));
      await tester.pumpAndSettle();
      expect(subtitles, 1);
      expect(find.byKey(const ValueKey('settings-volume')), findsNothing);
    },
  );

  testWidgets('brightness failure disables gesture and restores display', (
    tester,
  ) async {
    final display = DisplayStub()..fail = true;
    await mount(tester, width: 600, height: 340, display: display);
    final drag = await tester.startGesture(point(tester, 0.15, 0.39));
    await drag.moveBy(const Offset(0, -20));
    await drag.moveBy(const Offset(0, -30));
    await tester.pump();
    expect(find.text('亮度调节不可用，请使用系统控制'), findsOneWidget);
    expect(display.restores, 1);
    await drag.up();
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('desktop double click, hover and keyboard respect input focus', (
    tester,
  ) async {
    final inputFocus = FocusNode();
    addTearDown(inputFocus.dispose);
    var fullscreens = 0;
    final session = await mount(
      tester,
      width: 600,
      height: 340,
      onFullscreen: () => fullscreens++,
      input: TextField(focusNode: inputFocus),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(session.toggles, 1, reason: 'opening video must focus it');
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await doubleTap(tester, point(tester, 0.15, 0.39));
    expect(fullscreens, 1);
    expect(session.seeks, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(session.toggles, 3);
    expect(session.seeks, [const Duration(seconds: 40)]);
    inputFocus.requestFocus();
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'abc');
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    expect(session.toggles, 3);
    expect(session.seeks, hasLength(1));
    session.update(playing: true);
    await tester.pump(const Duration(milliseconds: 3300));
    expect(opacity(tester), 0);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(point(tester, 0.1, 0.39));
    await tester.pump();
    expect(opacity(tester), 1);
    expect(inputFocus.hasFocus, isTrue, reason: 'hover must not steal focus');
    await mouse.removePointer();
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
    'full screen controls fit safe insets and lock disables gestures',
    (tester) async {
      final session = await mount(
        tester,
        width: 600,
        height: 300,
        fullscreen: true,
        padding: const EdgeInsets.fromLTRB(40, 24, 40, 20),
      );
      final surface = tester.getRect(find.byType(PlaybackSurface));
      final back = tester.getRect(find.byTooltip('退出全屏').first);
      expect(back.left, greaterThanOrEqualTo(surface.left + 40));
      expect(back.top, greaterThanOrEqualTo(surface.top + 24));
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('锁定屏幕'));
      await tester.pump();
      expect(find.byTooltip('播放设置').hitTestable(), findsNothing);
      await doubleTap(tester, point(tester, 0.9, 0.39));
      expect(session.seeks, isEmpty);
      expect(session.toggles, 0);
      final hold = await tester.startGesture(point(tester, 0.1, 0.39));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await hold.up();
      expect(session.rates, isEmpty);
      await tester.tap(find.byTooltip('解除锁定'));
      await tester.pump();
      expect(find.byTooltip('播放设置').hitTestable(), findsOneWidget);
    },
  );
}
