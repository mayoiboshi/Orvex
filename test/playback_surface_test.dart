import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/features/player/application/playback_session.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:orvex/features/player/infrastructure/player_brightness.dart';
import 'package:orvex/features/player/presentation/playback_surface.dart';

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

  void update({int? seconds, bool? playing, double? rate, double? volume}) {
    frame = PlaybackFrame(
      position: Duration(seconds: seconds ?? 30),
      duration: const Duration(minutes: 2),
      playing: playing ?? true,
      rate: rate ?? frame.rate,
      volume: volume ?? frame.volume,
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

void main() {
  Future<SurfaceSession> mount(
    WidgetTester tester, {
    double width = 320,
    double height = 180,
    bool playing = true,
    bool fullscreen = false,
    EdgeInsets padding = EdgeInsets.zero,
    VoidCallback? onFullscreen,
    VoidCallback? onSubtitle,
    DisplayStub? display,
    Widget? input,
  }) async {
    final engine = FakeEngine();
    final session = SurfaceSession(engine)..update(playing: playing);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Focus(
            autofocus: true,
            child: MediaQuery(
              data: MediaQueryData(padding: padding),
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
                        brightness: display ?? DisplayStub(),
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
    final blank = point(tester, 0.08, 0.32);
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

  testWidgets('mobile double tap seeks once without single tap or speed', (
    tester,
  ) async {
    final session = await mount(tester);
    await doubleTap(tester, point(tester, 0.08, 0.32));
    expect(session.seeks, [const Duration(seconds: 20)]);
    expect(opacity(tester), 1);
    await doubleTap(tester, point(tester, 0.92, 0.32));
    expect(session.seeks.last, const Duration(seconds: 30));
    expect(session.toggles, 0);
    expect(session.rates, isEmpty);
  });

  testWidgets('central long press restores chosen rate on release and cancel', (
    tester,
  ) async {
    final session = await mount(tester);
    session.update(rate: 1.5);
    final center = point(tester, 0.5, 0.3);
    var press = await tester.startGesture(center);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    expect(session.rates, [2]);
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('临时 2 倍速'), findsOneWidget);
    expect(opacity(tester), 1);
    await press.up();
    await tester.pump();
    expect(session.rates, [2, 1.5]);
    press = await tester.startGesture(center);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await press.cancel();
    await tester.pump();
    expect(session.rates, [2, 1.5, 2, 1.5]);
    expect(session.seeks, isEmpty);
    expect(session.toggles, 0);
  });

  testWidgets('long press resets on pause, lifecycle and view disposal', (
    tester,
  ) async {
    final display = DisplayStub();
    final session = await mount(tester, display: display);
    session.update(rate: 1.25);
    var press = await tester.startGesture(point(tester, 0.5, 0.3));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    session.update(playing: false);
    await tester.pump();
    expect(session.rates, [2, 1.25]);
    await press.up();
    session.update();
    press = await tester.startGesture(point(tester, 0.5, 0.3));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(session.rates, [2, 1.25, 2, 1.25]);
    expect(display.restores, 1);
    await press.cancel();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    press = await tester.startGesture(point(tester, 0.5, 0.3));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(session.rates, [2, 1.25, 2, 1.25, 2, 1.25]);
    await press.cancel();
  });

  testWidgets('background before long press recognition cannot start 2x', (
    tester,
  ) async {
    final session = await mount(tester);
    final press = await tester.startGesture(point(tester, 0.5, 0.3));
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
      final press = await tester.startGesture(point(tester, 0.5, 0.3));
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
    var drag = await tester.startGesture(point(tester, 0.85, 0.45));
    await drag.moveBy(const Offset(0, -20));
    await drag.moveBy(const Offset(0, -50));
    await tester.pump();
    expect(session.volumes, isNotEmpty);
    expect(session.volumes.last, greaterThan(40));
    expect(find.textContaining('音量 '), findsOneWidget);
    await drag.up();
    drag = await tester.startGesture(point(tester, 0.15, 0.45));
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
      await tester.dragFrom(point(tester, 0.15, 0.45), const Offset(0, -40));
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
    final drag = await tester.startGesture(point(tester, 0.15, 0.45));
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
    await doubleTap(tester, point(tester, 0.15, 0.4));
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
    await mouse.moveTo(point(tester, 0.1, 0.4));
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
      await doubleTap(tester, point(tester, 0.9, 0.4));
      expect(session.seeks, isEmpty);
      await tester.tap(find.byTooltip('解除锁定'));
      await tester.pump();
      expect(find.byTooltip('播放设置').hitTestable(), findsOneWidget);
    },
  );
}
