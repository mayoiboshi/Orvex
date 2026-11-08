import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/playback_defaults.dart';

class PlaybackPreferences extends ChangeNotifier {
  PlaybackPreferences(this._preferences);

  static const key = 'orvex.player.defaults.v1';
  static const autoNextKey = 'orvex.player.autoNext.v1';
  final SharedPreferencesAsync _preferences;
  late final Future<void> initialized = _load();
  Future<void> _writes = Future.value();
  bool _disposed = false;

  PlaybackDefaults defaults = const PlaybackDefaults();
  bool autoNext = false;
  String? error;

  Future<void> _load() async {
    try {
      final saved = await _preferences.getString(key);
      if (saved != null) {
        final data = jsonDecode(saved) as Map<String, dynamic>;
        T choice<T extends Enum>(List<T> values, String field, T fallback) =>
            values.where((value) => value.name == data[field]).firstOrNull ??
            fallback;
        final rate = data['rate'];
        final skip = data['skipSeconds'];
        final gestures = data['touchGestures'];
        defaults = PlaybackDefaults(
          reopen: choice(
            ReopenBehavior.values,
            'reopen',
            ReopenBehavior.resume,
          ),
          rate: rate is num && playbackRates.contains(rate)
              ? rate.toDouble()
              : 1,
          fit: choice(PlaybackFit.values, 'fit', PlaybackFit.contain),
          skipSeconds: skip is int && playbackSkipSteps.contains(skip)
              ? skip
              : 10,
          touchGestures: gestures is bool ? gestures : true,
          subtitleLanguage: choice(
            TrackLanguage.values,
            'subtitleLanguage',
            TrackLanguage.fileDefault,
          ),
          audioLanguage: choice(
            TrackLanguage.values,
            'audioLanguage',
            TrackLanguage.fileDefault,
          ),
        );
      }
    } catch (_) {
      error = '播放偏好未能读取，已使用默认值';
    }
    try {
      autoNext = await _preferences.getBool(autoNextKey) ?? false;
    } catch (_) {
      error = '自动下一集偏好未能读取';
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> update(PlaybackDefaults Function(PlaybackDefaults) change) =>
      _write(() async {
        final next = change(defaults);
        await _preferences.setString(
          key,
          jsonEncode({
            'reopen': next.reopen.name,
            'rate': next.rate,
            'fit': next.fit.name,
            'skipSeconds': next.skipSeconds,
            'touchGestures': next.touchGestures,
            'subtitleLanguage': next.subtitleLanguage.name,
            'audioLanguage': next.audioLanguage.name,
          }),
        );
        defaults = next;
      });

  Future<void> setAutoNext(bool value) => _write(() async {
    await _preferences.setBool(autoNextKey, value);
    autoNext = value;
  });

  Future<void> _write(Future<void> Function() save) =>
      _writes = _writes.then((_) async {
        await initialized;
        try {
          await save();
          error = null;
        } catch (_) {
          error = '播放偏好未能保存，请重试';
        }
        if (!_disposed) notifyListeners();
      });

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
