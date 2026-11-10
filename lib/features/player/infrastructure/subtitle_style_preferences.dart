import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/subtitle_style.dart';

class SubtitleStylePreferences implements SubtitleStyleStore {
  SubtitleStylePreferences([SharedPreferencesAsync? preferences])
    : _preferences = preferences ?? SharedPreferencesAsync();
  static const key = 'orvex.player.subtitleStyle.v1';
  final SharedPreferencesAsync _preferences;

  @override
  Future<SubtitleStyle> read() async {
    final value = await _preferences.getString(key);
    if (value == null) return const SubtitleStyle();
    return SubtitleStyle.fromJson(jsonDecode(value) as Map<String, dynamic>);
  }

  @override
  Future<void> write(SubtitleStyle value) =>
      _preferences.setString(key, jsonEncode(value.toJson()));
}
