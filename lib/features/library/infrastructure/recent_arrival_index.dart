import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../player/domain/playback_engine.dart';

/// A presentation index. Null means the file was already present at upgrade.
class RecentArrivalIndex {
  RecentArrivalIndex(this.preferences, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static const _key = 'orvex.library.arrivals.v1';
  final SharedPreferencesAsync preferences;
  final DateTime Function() _clock;
  Map<String, int?>? _seen;
  Map<String, DateTime> _arrivals = const {};
  Future<void> _operations = Future.value();

  Future<Map<String, DateTime>> observe(List<LocalMedia> media) {
    final result = _operations.then((_) async {
      final stored = _seen ?? await _read();
      final updated = <String, int?>{...?stored};
      final now = _clock();
      for (final file in media) {
        updated.putIfAbsent(file.resumeKey, () {
          if (stored == null) return null;
          final arrival = file.relativeImportPath == null
              ? now
              : file.modifiedAt ?? now;
          return arrival.millisecondsSinceEpoch;
        });
      }
      if (stored != null && stored.length == updated.length && _seen != null) {
        return _arrivals;
      }
      if (stored == null || stored.length != updated.length) {
        await preferences.setString(_key, jsonEncode(updated));
      }
      _seen = updated;
      _arrivals = Map.unmodifiable({
        for (final entry in updated.entries)
          if (entry.value case final int time)
            entry.key: DateTime.fromMillisecondsSinceEpoch(time, isUtc: true),
      });
      return _arrivals;
    });
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<Map<String, int?>?> _read() async {
    final raw = await preferences.getString(_key);
    if (raw == null) return null;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      return Map<String, int?>.from(data);
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }
}
