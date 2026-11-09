import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class SystemVolumeReading {
  const SystemVolumeReading(this.level, {this.delta, this.reset = false});

  final double level;
  final double? delta;
  final bool reset;
}

/// User-driven output control for Apple devices. Other hosts keep the engine's
/// volume control.
class PlayerSystemVolume {
  static const _methods = MethodChannel('dev.orvex/volume');
  static final _changes = const EventChannel('dev.orvex/volume-events')
      .receiveBroadcastStream()
      .map((event) {
        final data = event as Map<Object?, Object?>;
        return SystemVolumeReading(
          (data['level'] as num).toDouble(),
          delta: (data['delta'] as num?)?.toDouble(),
          reset: data['reset'] == true,
        );
      });

  Future<bool> available() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return false;
    return await _tryCall<bool>('isAvailable') ?? false;
  }

  Stream<SystemVolumeReading> get changes => _changes;

  Future<double?> currentLevel() => _tryCall<double>('currentLevel');

  Future<void> present(bool active) async {
    await _tryCall<void>('present', active);
  }

  Future<bool> set(double level) async =>
      await _tryCall<bool>('set', level) ?? false;

  Future<T?> _tryCall<T>(String method, [Object? arguments]) async {
    try {
      return await _methods.invokeMethod<T>(method, arguments);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

/// One observed change can be a drag, a batched event or a clipped step. Use
/// repeated, evenly spaced samples from the current output route.
class VolumeSteps {
  int? count;
  int? _candidate;

  void observe(SystemVolumeReading reading) {
    if (reading.reset) {
      count = null;
      _candidate = null;
    }
    final delta = reading.delta;
    if (delta == null || !delta.isFinite || delta < 1 / 32 || delta > 1 / 4) {
      return;
    }
    final divisions = (1 / delta).round();
    if ((1 / divisions - delta).abs() > 0.002) return;
    if (count != null && divisions <= count!) return;
    if (_candidate == divisions) count = divisions;
    _candidate = divisions;
  }
}
