import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:orvex/features/player/application/playback_session.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:orvex/features/player/infrastructure/media_kit_engine.dart';
import 'package:orvex/features/player/presentation/playback_surface.dart';
import 'package:orvex/features/player/presentation/subtitle_style_settings.dart';

class _Resume implements ResumeStore {
  @override
  Future<Duration> read(String key) async => Duration.zero;
  @override
  Future<void> write(String key, Duration position) async {}
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('iPad simulator anchored subtitle menu navigation', (
    tester,
  ) async {
    expect(Platform.isIOS, isTrue);
    expect(
      await const MethodChannel('dev.orvex/audio-session')
          .invokeMethod<bool>('isSimulator'),
      isTrue,
      reason: 'Generated fixture must never run on a physical device',
    );
    MediaKit.ensureInitialized();
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
    ]);
    final temp = await Directory.systemTemp.createTemp('orvex-menu-');
    final fixture = await rootBundle.load('test/fixtures/generated.mp4');
    final video = await File('${temp.path}/video.mp4').writeAsBytes(
      fixture.buffer.asUint8List(fixture.offsetInBytes, fixture.lengthInBytes),
    );
    final session = PlaybackSession(
      createEngine: () => MediaKitEngine(silentAudioForTesting: true),
      resumeStore: _Resume(),
    );
    Future<void> until(bool Function() ready) async {
      final deadline = DateTime.now().add(const Duration(seconds: 25));
      while (!ready() && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(ready(), isTrue, reason: session.error);
    }

    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlaybackSurface(
              session: session,
              fullscreen: true,
              title: '字幕菜单模拟器验证',
              onFullscreen: () {},
              onSubtitle: () {},
            ),
          ),
        ),
      );
      final open = session.open(LocalMedia(uri: video.uri, name: 'video.mp4'));
      await until(() => session.ready && session.frame.duration.inSeconds > 10);
      await open;
      await session.pauseForInterruption();
      await tester.pump(const Duration(milliseconds: 500));
      final anchor = find.byTooltip('字幕');
      expect(anchor, findsOneWidget);
      final anchorRect = tester.getRect(anchor);
      await tester.tap(anchor);
      await tester.pump(const Duration(milliseconds: 500));
      final panel = find.byKey(const ValueKey('subtitle-menu-panel'));
      expect(panel, findsOneWidget);
      final first = tester.getRect(panel);
      expect(first.bottom, lessThanOrEqualTo(anchorRect.top));
      expect((first.right - anchorRect.right).abs(), lessThanOrEqualTo(8));
      final route = ModalRoute.of(tester.element(panel));
      await tester.tap(find.text('字幕设置…'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(SubtitleStyleSettings), findsOneWidget);
      expect(ModalRoute.of(tester.element(panel)), same(route));
      expect(tester.getRect(panel).right, first.right);
      await tester.tap(find.byTooltip('返回字幕轨道'));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('关闭字幕'), findsOneWidget);
      expect(ModalRoute.of(tester.element(panel)), same(route));
      expect(tester.takeException(), isNull);
    } finally {
      session.dispose();
      await tester.pump(const Duration(milliseconds: 300));
      await SystemChrome.setPreferredOrientations([]);
      await temp.delete(recursive: true);
    }
  });
}
