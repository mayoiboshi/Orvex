import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('AirPlay native candidate fails closed without a video route', (
    tester,
  ) async {
    expect(Platform.isIOS, isTrue);
    expect(
      await const MethodChannel('dev.orvex/audio-session')
          .invokeMethod<bool>('isSimulator'),
      isTrue,
      reason: 'Generated media must never run on a physical device',
    );
    const channel = MethodChannel('dev.orvex/airplay');
    const events = EventChannel('dev.orvex/airplay/events');
    final bridge = (await channel.invokeMethod<String>('identity'))!;
    final claim = (await channel.invokeMethod<String>('claimPlayback', {
      'bridgeId': bridge,
    }))!;
    await expectLater(
      channel.invokeMethod<String>('claimPlayback', {'bridgeId': bridge}),
      throwsA(
        isA<PlatformException>().having((e) => e.code, 'code', 'owner_busy'),
      ),
    );
    await expectLater(
      channel.invokeMethod<void>('releasePlayback', {
        'bridgeId': bridge,
        'claimId': 'stale',
      }),
      throwsA(
        isA<PlatformException>().having((e) => e.code, 'code', 'stale_owner'),
      ),
    );
    final observed = <Map<dynamic, dynamic>>[];
    final subscription = events
        .receiveBroadcastStream({
          'bridgeId': bridge,
          'claimId': claim,
          'subscriptionId': 'native-test',
        })
        .listen((event) {
          if (event is Map) observed.add(event);
        });
    final imports = Directory(
      '${(await getApplicationDocumentsDirectory()).path}/Imports',
    );
    await imports.create(recursive: true);
    final temp = await imports.createTemp('orvex-airplay-native-');
    final importPath =
        'Imports/${temp.uri.pathSegments.where((part) => part.isNotEmpty).last}/fixture.mp4';
    final bytes = await rootBundle.load('test/fixtures/generated.mp4');
    final video = await File('${temp.path}/fixture.mp4').writeAsBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
    try {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 64,
              height: 64,
              child: UiKitView(viewType: 'dev.orvex/airplay-picker'),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final prepared = await channel.invokeMapMethod<String, dynamic>(
        'prepare',
        {
          'uri': video.uri.toString(),
          'importPath': importPath,
          'positionMs': 4000,
          'token': 17,
          'bridgeId': bridge,
          'claimId': claim,
        },
      );
      expect(prepared, isNotNull);
      expect(prepared!['token'], 17);
      expect(prepared['ready'], isTrue);
      expect(prepared['external'], isFalse);
      expect(prepared['playing'], isFalse);
      expect(prepared['positionValid'], isTrue);
      expect(
        (prepared['positionMs'] as int) - 4000,
        inInclusiveRange(-100, 100),
      );
      final seeked = await channel.invokeMapMethod<String, dynamic>('seek', {
        'positionMs': 2000,
        'token': 17,
        'bridgeId': bridge,
        'claimId': claim,
      });
      expect(
        (seeked!['positionMs'] as int) - 2000,
        inInclusiveRange(-100, 100),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        observed.any(
          (e) =>
              e['token'] == 17 &&
              e['event'] == 'seeked' &&
              e['positionMs'] == 2000,
        ),
        isTrue,
      );
      await expectLater(
        channel.invokeMethod<void>('play', {
          'token': 17,
          'bridgeId': bridge,
          'claimId': claim,
        }),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'route_unavailable',
          ),
        ),
      );
      await channel.invokeMethod<void>('probe', {
        'token': 17,
        'bridgeId': bridge,
        'claimId': claim,
      });
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        observed.any((e) => e['token'] == 17 && e['event'] == 'ready'),
        isTrue,
      );
      final status = await channel.invokeMapMethod<String, dynamic>('status', {
        'token': 17,
        'bridgeId': bridge,
        'claimId': claim,
      });
      expect(status!['external'], isFalse);
      expect(status['probing'], isTrue);
      expect(
        observed
            .where((e) => e['token'] == 17)
            .every((e) => e['external'] != true),
        isTrue,
      );
      await channel.invokeMethod<void>('close', {
        'token': 17,
        'bridgeId': bridge,
        'claimId': claim,
      });
      await channel.invokeMethod<void>('close', {
        'token': 17,
        'bridgeId': bridge,
        'claimId': claim,
      });
      await expectLater(
        channel.invokeMethod<void>('status', {
          'token': 17,
          'bridgeId': bridge,
          'claimId': claim,
        }),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'stale_session',
          ),
        ),
      );
      await expectLater(
        channel.invokeMethod<void>('prepare', {
          'uri': File('${temp.path}/missing.mp4').uri.toString(),
          'importPath':
              'Imports/${temp.uri.pathSegments.where((part) => part.isNotEmpty).last}/missing.mp4',
          'positionMs': 0,
          'token': 18,
          'bridgeId': bridge,
          'claimId': claim,
        }),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'prepare_failed',
          ),
        ),
      );
      final canceled = channel
          .invokeMethod<void>('prepare', {
            'uri': video.uri.toString(),
            'importPath': importPath,
            'positionMs': 0,
            'token': 19,
            'bridgeId': bridge,
            'claimId': claim,
          })
          .then(
            (_) => false,
            onError: (Object error) =>
                error is PlatformException && error.code == 'canceled',
          );
      await channel.invokeMethod<void>('close', {
        'token': 19,
        'bridgeId': bridge,
        'claimId': claim,
      });
      expect(await canceled, isTrue);
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        observed.where((e) => e['token'] == 19 && e['event'] == 'ready'),
        isEmpty,
      );
      await channel.invokeMethod<void>('prepare', {
        'uri': video.uri.toString(),
        'importPath': importPath,
        'positionMs': 0,
        'token': 20,
        'bridgeId': bridge,
        'claimId': claim,
      });
      await channel.invokeMethod<void>('close', {
        'token': 20,
        'bridgeId': bridge,
        'claimId': claim,
      });
      await channel.invokeMethod<void>('prepare', {
        'uri': video.uri.toString(),
        'importPath': importPath,
        'positionMs': 0,
        'token': 4294967320,
        'bridgeId': bridge,
        'claimId': claim,
      });
      await expectLater(
        channel.invokeMethod<void>('close', {
          'token': 20,
          'bridgeId': bridge,
          'claimId': claim,
        }),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'stale_session',
          ),
        ),
      );
      final newer = await channel.invokeMapMethod<String, dynamic>('status', {
        'token': 4294967320,
        'bridgeId': bridge,
        'claimId': claim,
      });
      expect(newer!['token'], 4294967320);
      expect(newer['ready'], isTrue);
      await channel.invokeMethod<void>('close', {
        'token': 4294967320,
        'bridgeId': bridge,
        'claimId': claim,
      });
    } finally {
      await subscription.cancel();
      await channel.invokeMethod<void>('releasePlayback', {
        'bridgeId': bridge,
        'claimId': claim,
      });
      await temp.delete(recursive: true);
    }
  });
}
