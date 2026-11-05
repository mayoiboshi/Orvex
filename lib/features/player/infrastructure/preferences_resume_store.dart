import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/playback_engine.dart';

class PreferencesResumeStore implements ResumeStore {
  final SharedPreferencesAsync _preferences = SharedPreferencesAsync();
  static const _importPrefix = 'orvex.import.v1:';
  static const _legacyPrefix = 'orvex.resume.v1.';
  String _key(String media) => media.startsWith(_importPrefix)
      ? 'orvex.resume.v2.$media'
      : '$_legacyPrefix$media';

  @override
  Future<Duration> read(String key) async {
    final saved = await _preferences.getInt(_key(key));
    if (saved != null) return _position(saved);
    if (!key.startsWith(_importPrefix)) return Duration.zero;

    // Latest viewing time wins, even if the user deliberately sought backward.
    // Do not take the furthest position across stale app-container UUIDs.
    Map<String, dynamic>? latest;
    DateTime? latestDate;
    for (final historyKey in ['orvex.history.v2', 'orvex.history.v1']) {
      for (final raw
          in await _preferences.getStringList(historyKey) ?? <String>[]) {
        try {
          final entry = jsonDecode(raw) as Map<String, dynamic>;
          final media = LocalMedia(
            uri: Uri.parse(entry['uri'] as String),
            name: entry['name'] as String,
            importPath: entry['importPath'] as String?,
          );
          if (media.resumeKey != key || entry['position'] is! int) continue;
          final date = DateTime.parse(entry['updatedAt'] as String);
          if (latestDate == null || date.isAfter(latestDate)) {
            latest = entry;
            latestDate = date;
          }
        } on FormatException {
          // Preserve migration of other valid records.
        } on TypeError {
          // Preserve migration of other valid records.
        }
      }
    }
    int? migrated;
    if (latest != null) {
      migrated = latest['completed'] == true
          ? 0
          : await _preferences.getInt('$_legacyPrefix${latest['uri']}') ??
                latest['position'] as int;
    } else {
      final matching = <int>[];
      for (final storedKey in await _preferences.getKeys()) {
        if (!storedKey.startsWith(_legacyPrefix)) continue;
        final uri = Uri.tryParse(storedKey.substring(_legacyPrefix.length));
        if (uri == null) continue;
        final relative = legacyImportedPath(uri);
        if (relative == null || '$_importPrefix$relative' != key) continue;
        final value = await _preferences.getInt(storedKey);
        if (value != null) matching.add(value);
      }
      if (matching.toSet().length == 1) migrated = matching.first;
    }
    if (migrated == null) return Duration.zero;
    final position = _position(migrated);
    await write(key, position);
    return position;
  }

  Duration _position(int milliseconds) =>
      Duration(milliseconds: milliseconds < 0 ? 0 : milliseconds);

  @override
  Future<void> write(String key, Duration position) =>
      _preferences.setInt(_key(key), position.inMilliseconds);
}
