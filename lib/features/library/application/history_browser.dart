import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../domain/playback_record.dart';

/// The persisted list is read once. Each page is read from its frozen order,
/// even if a newer checkpoint moves a record to the front of the live history.
class HistoryBrowseSnapshot {
  const HistoryBrowseSnapshot({required this.total, required this.readPage});

  factory HistoryBrowseSnapshot.fromRecords(List<PlaybackRecord> records) {
    final snapshot = List<PlaybackRecord>.unmodifiable(records);
    return HistoryBrowseSnapshot(
      total: snapshot.length,
      readPage: (offset, count) async =>
          snapshot.getRange(offset, offset + count).toList(),
    );
  }

  final int total;
  final Future<List<PlaybackRecord>> Function(int offset, int count) readPage;
}

class HistoryBrowser extends ChangeNotifier {
  static const pageSize = 30;
  static const prefetchViewports = .75;

  HistoryBrowseSnapshot? _snapshot;
  List<PlaybackRecord> _records = const [];
  int _generation = 0;
  bool _disposed = false;

  bool refreshing = false;
  bool appending = false;
  bool refreshFailed = false;
  bool appendFailed = false;

  List<PlaybackRecord> get records => _records;
  int? get total => _snapshot?.total;
  bool get hasMore => _records.length < (total ?? 0);

  Future<void> refresh(Future<HistoryBrowseSnapshot> Function() open) async {
    if (_disposed) return;
    final generation = ++_generation;
    refreshing = true;
    appending = refreshFailed = appendFailed = false;
    notifyListeners();
    try {
      final snapshot = await open();
      if (!_isCurrent(generation)) return;
      final first = await _read(snapshot, 0);
      if (!_isCurrent(generation)) return;
      _snapshot = snapshot;
      _records = List.unmodifiable(first);
    } catch (_) {
      if (_isCurrent(generation)) refreshFailed = true;
    } finally {
      if (_isCurrent(generation)) {
        refreshing = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadMore({bool retry = false}) async {
    if (_disposed ||
        refreshing ||
        appending ||
        refreshFailed ||
        (appendFailed && !retry) ||
        !hasMore) {
      return;
    }
    final generation = _generation;
    appending = true;
    appendFailed = false;
    notifyListeners();
    try {
      final next = await _read(_snapshot!, _records.length);
      if (_isCurrent(generation)) {
        _records = List.unmodifiable([..._records, ...next]);
      }
    } catch (_) {
      if (_isCurrent(generation)) appendFailed = true;
    } finally {
      if (_isCurrent(generation)) {
        appending = false;
        notifyListeners();
      }
    }
  }

  Future<List<PlaybackRecord>> _read(
    HistoryBrowseSnapshot snapshot,
    int offset,
  ) async {
    final count = math.min(pageSize, snapshot.total - offset);
    if (count == 0) return const [];
    final page = await snapshot.readPage(offset, count);
    if (page.length != count) throw StateError('Incomplete history page');
    return page;
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
