import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:orvex/features/player/application/playback_session.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:orvex/features/player/infrastructure/airplay_playback_engine.dart';
import 'package:orvex/features/player/infrastructure/media_kit_engine.dart';
import 'package:orvex/features/player/presentation/playback_surface.dart';

class _Resume implements ResumeStore {
  @override
  Future<Duration> read(String key) async => Duration.zero;
  @override
  Future<void> write(String key, Duration position) async {}
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('simulator AirPlay entry prepares and cancels without a receiver', (
    tester,
  ) async {
    expect(Platform.isIOS, isTrue);
    expect(
      await const MethodChannel('dev.orvex/audio-session')
          .invokeMethod<bool>('isSimulator'),
      isTrue,
      reason: 'Generated video must only run on an iOS simulator',
    );
    MediaKit.ensureInitialized();
    final imports = Directory(
      '${(await getApplicationDocumentsDirectory()).path}/Imports',
    );
    await imports.create(recursive: true);
    final root = await imports.createTemp('orvex-airplay-flow-');
    final bytes = await rootBundle.load('test/fixtures/generated.mp4');
    final file = await File('${root.path}/video.mp4').writeAsBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
    final reservation = NativePlaybackReservation();
    final session = PlaybackSession(
      exclusivePlayback: true,
      playbackReservation: reservation,
      createEngine: () => AirPlayPlaybackEngine(
        MediaKitEngine(silentAudioForTesting: true),
        transport: MethodChannelAirPlayTransport(reservation: reservation),
      ),
      resumeStore: _Resume(),
    );
    Future<void> until(bool Function() ready, String label) async {
      final deadline = DateTime.now().add(const Duration(seconds: 25));
      while (!ready() && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(ready(), isTrue, reason: '$label: ${session.error}');
    }

    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlaybackSurface(
              session: session,
              fullscreen: true,
              onFullscreen: () {},
              onSubtitle: () {},
            ),
          ),
        ),
      );
      final opening = session.open(
        LocalMedia(
          uri: file.uri,
          name: 'video.mp4',
          importPath:
              'Imports/${root.uri.pathSegments.where((part) => part.isNotEmpty).last}/video.mp4',
        ),
      );
      await until(
        () => session.ready && session.frame.playing,
        'local playback',
      );
      await opening;
      await tester.tap(find.byTooltip('AirPlay 视频投屏'));
      await until(
        () => find.text('AirPlay 视频投屏').evaluate().isNotEmpty,
        'route dialog',
      );
      expect(find.byType(UiKitView), findsOneWidget);
      expect(find.textContaining('不会加载外挂字幕'), findsOneWidget);
      final engine = session.engine! as AirPlayPlaybackEngine;
      expect(engine.externalActive, isFalse);
      expect(session.frame.playing, isFalse);
      await tester.tap(find.text('取消'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(engine.externalActive, isFalse);
      expect(session.frame.playing, isFalse);
      expect(session.error, isNull);
      await session.togglePause();
      await until(() => session.frame.playing, 'manual resume');
    } finally {
      session.dispose();
      await tester.pump(const Duration(milliseconds: 500));
      await root.delete(recursive: true);
    }
  });
}
