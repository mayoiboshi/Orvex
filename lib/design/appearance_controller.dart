import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App appearance only. Playback continues to use its existing session.
class AppearanceController extends ChangeNotifier with WidgetsBindingObserver {
  AppearanceController({SharedPreferencesAsync? preferences})
    : _preferences = preferences ?? SharedPreferencesAsync() {
    WidgetsBinding.instance.addObserver(this);
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'accessibilityChanged') await _readSystemPreferences();
    });
    _readMotion();
  }

  static const themeKey = 'orvex.appearance.theme.v1';
  static const transparencyKey = 'orvex.appearance.reduce-transparency.v1';
  static const _channel = MethodChannel('dev.orvex/appearance');
  final SharedPreferencesAsync _preferences;
  ThemeMode mode = ThemeMode.system;
  bool reduceTransparency = false;
  bool systemReduceTransparency = false;
  bool reduceMotion = false;
  bool _systemReduceMotion = false;
  String? error;
  bool _disposed = false;
  int _modeRevision = 0;
  int _transparencyRevision = 0;
  Future<void> _writes = Future.value();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    final modeRevision = _modeRevision;
    final transparencyRevision = _transparencyRevision;
    try {
      final name = await _preferences.getString(themeKey);
      final reduced = await _preferences.getBool(transparencyKey);
      if (!_disposed && modeRevision == _modeRevision) {
        mode = ThemeMode.values.firstWhere(
          (mode) => mode.name == name,
          orElse: () => ThemeMode.system,
        );
      }
      if (!_disposed && transparencyRevision == _transparencyRevision) {
        reduceTransparency = reduced ?? false;
      }
    } catch (_) {
      if (!_disposed) error = '外观偏好未能读取，当前使用默认设置';
    }
    _notify();
    unawaited(_readSystemPreferences());
  }

  void _readMotion() {
    final features =
        WidgetsBinding.instance.platformDispatcher.accessibilityFeatures;
    reduceMotion =
        features.reduceMotion ||
        features.disableAnimations ||
        _systemReduceMotion;
  }

  Future<void> _readSystemPreferences() async {
    if (defaultTargetPlatform != TargetPlatform.iOS &&
        defaultTargetPlatform != TargetPlatform.macOS) {
      _readMotion();
      _notify();
      return;
    }
    try {
      final value = await _channel.invokeMapMethod<String, bool>(
        'accessibilityPreferences',
      );
      if (!_disposed) {
        systemReduceTransparency = value?['reduceTransparency'] ?? false;
        _systemReduceMotion = value?['reduceMotion'] ?? false;
      }
    } on MissingPluginException {
      // Flutter has no reduce-transparency flag; other hosts use the app toggle.
    } on PlatformException {
      // A platform bridge must never prevent the app from opening.
    }
    _readMotion();
    _notify();
  }

  @override
  void didChangeAccessibilityFeatures() {
    _readMotion();
    _notify();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_readSystemPreferences());
  }

  Future<void> setMode(ThemeMode value) {
    mode = value;
    _modeRevision++;
    _notify();
    return _save(() => _preferences.setString(themeKey, value.name));
  }

  Future<void> setReduceTransparency(bool value) {
    reduceTransparency = value;
    _transparencyRevision++;
    _notify();
    return _save(() => _preferences.setBool(transparencyKey, value));
  }

  Future<void> _save(Future<void> Function() write) {
    _writes = _writes.then((_) async {
      try {
        await write();
        error = null;
      } catch (_) {
        error = '外观已应用，但暂未保存，请重试';
      }
      _notify();
    });
    return _writes;
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _channel.setMethodCallHandler(null);
    super.dispose();
  }
}

class AppearanceScope extends InheritedNotifier<AppearanceController> {
  const AppearanceScope({
    super.key,
    required AppearanceController controller,
    required super.child,
  }) : super(notifier: controller);

  static AppearanceController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppearanceScope>()?.notifier;
}
