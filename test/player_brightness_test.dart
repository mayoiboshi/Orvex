import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/features/player/infrastructure/player_brightness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.orvex/display');
  final calls = <MethodCall>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    calls.clear();
  });

  testWidgets('iOS brightness reads capability, clamps, and restores', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'getBrightness' ? 0.6 : null;
    });
    final display = PlayerBrightness();
    expect(await display.read(), 0.6);
    await display.set(-1);
    await display.set(2);
    await display.restore();
    expect(calls.map((call) => call.method), [
      'getBrightness',
      'setBrightness',
      'setBrightness',
      'restoreBrightness',
    ]);
    expect(calls[1].arguments, 0.05);
    expect(calls[2].arguments, 1.0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('missing or failing display channel degrades without throwing', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw MissingPluginException();
    });
    final display = PlayerBrightness();
    expect(await display.read(), isNull);
    await display.restore();
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'display_unavailable');
    });
    expect(await display.read(), isNull);
    await display.restore();
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('other platforms do not call native display methods', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return 0.5;
    });
    final display = PlayerBrightness();
    expect(await display.read(), isNull);
    await display.restore();
    expect(calls, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
