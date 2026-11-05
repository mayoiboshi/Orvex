import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../player/domain/playback_engine.dart';
import '../domain/playback_record.dart';

class PlaybackHistoryStore {
  final SharedPreferencesAsync _preferences = SharedPreferencesAsync();
  static const legacyKey = 'orvex.history.v1';
  static const key = 'orvex.history.v2';
  Future<void> _writes = Future.value();

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _writes.then((_) => action());
    _writes = result.then<void>((_) {}).catchError((Object _) {});
    return result;
  }

  Future<List<PlaybackRecord>> _read() async {
    final values =
        await _preferences.getStringList(key) ??
        await _preferences.getStringList(legacyKey) ??
        [];
    final records = <PlaybackRecord>[];
    for (final value in values) {
      try {
        final data = jsonDecode(value) as Map<String, dynamic>;
        final relative = data['importPath'] as String?;
        if (relative != null && !validImportPath(relative)) continue;
        records.add(
          PlaybackRecord(
            media: LocalMedia(
              uri: Uri.parse(data['uri'] as String),
              name: data['name'] as String,
              importPath: relative,
            ),
            position: Duration(milliseconds: data['position'] as int),
            duration: Duration(milliseconds: data['duration'] as int),
            updatedAt: DateTime.parse(data['updatedAt'] as String),
            completed: data['completed'] as bool,
          ),
        );
      } on FormatException {
        // One damaged entry must not hide the rest of the user's history.
      } on TypeError {
        // Ignore an invalid or incomplete payload.
      }
    }
    return _deduplicate(records);
  }

  List<PlaybackRecord> _deduplicate(List<PlaybackRecord> records) {
    records.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final seen = <String>{};
    return records
        .where((record) => seen.add(record.media.resumeKey))
        .take(100)
        .toList();
  }

  List<String> _encode(List<PlaybackRecord> records) => [
    for (final record in records)
      jsonEncode({
        'uri': record.media.uri.toString(),
        'name': record.media.name,
        if (record.media.relativeImportPath != null)
          'importPath': record.media.relativeImportPath,
        'position': record.position.inMilliseconds,
        'duration': record.duration.inMilliseconds,
        'updatedAt': record.updatedAt.toUtc().toIso8601String(),
        'completed': record.completed,
      }),
  ];

  Future<List<PlaybackRecord>> list({
    List<LocalMedia>? importedVideos,
  }) => _serialize(() async {
    final records = await _read();
    if (importedVideos == null) return records;
    final current = {
      for (final video in importedVideos) video.resumeKey: video,
    };
    final resolved = [
      for (final record in records)
        PlaybackRecord(
          media: current[record.media.resumeKey] ?? record.media,
          position: record.position,
          duration: record.duration,
          updatedAt: record.updatedAt,
          completed: record.completed,
        ),
    ];
    // v1 remains untouched as a recovery source. Do not merge unrelated copies
    // by filename: only the exact app-owned relative identity can be rebased.
    await _preferences.setStringList(key, _encode(resolved));
    return resolved;
  });

  Future<void> record(LocalMedia media, PlaybackFrame frame) {
    if (frame.duration <= Duration.zero) return Future.value();
    return _serialize(() async {
      final records = await _read();
      final next = _deduplicate([
        PlaybackRecord(
          media: media,
          position: frame.position,
          duration: frame.duration,
          updatedAt: DateTime.now().toUtc(),
          completed: frame.completed,
        ),
        ...records.where((record) => record.media.resumeKey != media.resumeKey),
      ]);
      await _preferences.setStringList(key, _encode(next));
    });
  }
}
