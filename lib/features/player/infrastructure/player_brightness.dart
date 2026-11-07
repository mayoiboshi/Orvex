import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Display-only capability, independent of the playback engine.
class PlayerBrightness {
  static const _channel = MethodChannel('dev.orvex/display');

  Future<double?> read() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return null;
    try {
      return await _channel.invokeMethod<double>('getBrightness');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> set(double value) =>
      _channel.invokeMethod<void>('setBrightness', value.clamp(0.05, 1.0));

  Future<void> restore() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      await _channel.invokeMethod<void>('restoreBrightness');
    } on PlatformException {
      // The native resign-active observer also restores the display.
    } on MissingPluginException {
      // Older hosts and unsupported targets have no brightness control.
    }
  }
}
