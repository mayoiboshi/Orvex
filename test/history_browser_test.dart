import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/features/library/application/history_browser.dart';
import 'package:orvex/features/library/domain/playback_record.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';

List<PlaybackRecord> records(int count) => [
  for (var i = 0; i < count; i++)
    PlaybackRecord(
      media: LocalMedia(uri: Uri.file('/$i.mp4'), name: '$i.mp4'),
      position: const Duration(seconds: 5),
      duration: const Duration(minutes: 10),
      updatedAt: DateTime.utc(2026, 11, 8),
    ),
];

void main() {
  for (final size in [0, 18, 30, 67]) {
    test('reads only the requested batches from a snapshot of $size', () async {
      final source = records(size);
      final browser = HistoryBrowser();
      addTearDown(browser.dispose);
      final reads = <(int, int)>[];
      await browser.refresh(
        () async => HistoryBrowseSnapshot(
          total: size,
          readPage: (offset, count) async {
            reads.add((offset, count));
            return source.sublist(offset, offset + count);
          },
        ),
      );
      expect(browser.total, size);
      expect(browser.records, source.take(30));
      for (var i = 0; i < 4; i++) {
        await browser.loadMore();
      }
      expect(browser.records, source);
      expect(browser.hasMore, isFalse);
      expect(reads, switch (size) {
        0 => [],
        18 => [(0, 18)],
        30 => [(0, 30)],
        _ => [(0, 30), (30, 30), (60, 7)],
      });
    });
  }

  test(
    'concurrent scroll requests coalesce and a failed batch retries in place',
    () async {
      final source = records(64);
      final browser = HistoryBrowser();
      addTearDown(browser.dispose);
      final failure = Completer<List<PlaybackRecord>>();
      final calls = <int>[];
      await browser.refresh(
        () async => HistoryBrowseSnapshot(
          total: source.length,
          readPage: (offset, count) async {
            calls.add(offset);
            if (offset == 30 && calls.length == 2) return failure.future;
            return source.sublist(offset, offset + count);
          },
        ),
      );
      final pending = browser.loadMore();
      await Future.wait(List.generate(12, (_) => browser.loadMore()));
      expect(calls, [0, 30]);
      failure.completeError(StateError('batch unavailable'));
      await pending;
      expect(browser.appendFailed, isTrue);
      expect(browser.records, source.take(30));
      await browser.loadMore();
      expect(calls, [0, 30]);
      await browser.loadMore(retry: true);
      expect(browser.records, source.take(60));
      expect(browser.appendFailed, isFalse);
      expect(calls, [0, 30, 30]);
    },
  );

  test(
    'refresh discards an old append and replaces the frozen order',
    () async {
      final source = records(64);
      final browser = HistoryBrowser();
      addTearDown(browser.dispose);
      final oldPage = Completer<List<PlaybackRecord>>();
      await browser.refresh(
        () async => HistoryBrowseSnapshot(
          total: source.length,
          readPage: (offset, count) async =>
              offset == 0 ? source.take(count).toList() : oldPage.future,
        ),
      );
      final stale = browser.loadMore();
      final refreshed = [source.last, ...source.take(source.length - 1)];
      await browser.refresh(
        () async => HistoryBrowseSnapshot.fromRecords(refreshed),
      );
      await browser.loadMore();
      oldPage.complete(source.sublist(30, 60));
      await stale;
      await browser.loadMore();
      expect(browser.records, refreshed);
      expect(browser.total, source.length);
    },
  );

  test(
    'writes that move a record during browsing do not affect later batches',
    () async {
      final source = records(64);
      final initial = List.of(source);
      final browser = HistoryBrowser();
      addTearDown(browser.dispose);
      await browser.refresh(
        () async => HistoryBrowseSnapshot.fromRecords(source),
      );
      source.insert(0, source.removeLast());
      await browser.loadMore();
      await browser.loadMore();
      expect(browser.records, initial);
      await browser.refresh(
        () async => HistoryBrowseSnapshot.fromRecords(source),
      );
      expect(browser.records.first, initial.last);
      expect(browser.records.length, 30);
    },
  );
}
