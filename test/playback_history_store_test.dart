import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/features/library/infrastructure/playback_history_store.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(
    () => SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty(),
  );

  test('old UUID duplicates rebase to the existing import, retaining the most recent position', () async {
    const relative = 'Imports/media-one/Conan 0615.mkv';
    final old = Uri.file(
      '/private/var/mobile/Containers/Data/Application/OLD/Documents/$relative',
    );
    final newer = Uri.file(
      '/private/var/mobile/Containers/Data/Application/NEWER/Documents/$relative',
    );
    final current = LocalMedia(
      uri: Uri.file(
        '/private/var/mobile/Containers/Data/Application/CURRENT/Documents/$relative',
      ),
      name: 'Conan 0615.mkv',
      importPath: relative,
    );
    final oldRecords = [
      jsonEncode({
        'uri': old.toString(),
        'name': current.name,
        'position': 42000,
        'duration': 1452000,
        'updatedAt': '2026-11-05T14:26:14Z',
        'completed': false,
      }),
      jsonEncode({
        'uri': newer.toString(),
        'name': current.name,
        'position': 33000,
        'duration': 1452000,
        'updatedAt': '2026-11-05T15:16:01Z',
        'completed': false,
      }),
    ];
    final preferences = SharedPreferencesAsync();
    await preferences.setStringList(PlaybackHistoryStore.legacyKey, oldRecords);
    final store = PlaybackHistoryStore();
    final records = await store.list(importedVideos: [current]);
    expect(records.single.media.uri, current.uri);
    expect(records.single.media.resumeKey, current.resumeKey);
    expect(records.single.position, const Duration(seconds: 33));
    expect(
      await preferences.getStringList(PlaybackHistoryStore.legacyKey),
      oldRecords,
    );
    await store.record(
      current,
      const PlaybackFrame(
        position: Duration(seconds: 12),
        duration: Duration(minutes: 24),
      ),
    );
    expect(
      (await PlaybackHistoryStore().list()).single.position,
      const Duration(seconds: 12),
    );
  });

  test(
    'separate imports with identical names remain separate histories',
    () async {
      final first = LocalMedia(
        uri: Uri.file('/current/Documents/Imports/media-a/Conan.mkv'),
        name: 'Conan.mkv',
        importPath: 'Imports/media-a/Conan.mkv',
      );
      final second = LocalMedia(
        uri: Uri.file('/current/Documents/Imports/media-b/Conan.mkv'),
        name: 'Conan.mkv',
        importPath: 'Imports/media-b/Conan.mkv',
      );
      final store = PlaybackHistoryStore();
      await store.record(
        first,
        const PlaybackFrame(
          position: Duration(seconds: 10),
          duration: Duration(minutes: 20),
        ),
      );
      await store.record(
        second,
        const PlaybackFrame(
          position: Duration(seconds: 20),
          duration: Duration(minutes: 20),
        ),
      );
      final records = await store.list(importedVideos: [first, second]);
      expect(records.length, 2);
      expect(records.map((record) => record.media.resumeKey).toSet().length, 2);
    },
  );

  test(
    'concurrent checkpoints retain newest position and unique recency order',
    () async {
      final store = PlaybackHistoryStore();
      final a = LocalMedia(uri: Uri.file('/Imports/旅程.mp4'), name: '旅程.mp4');
      final b = LocalMedia(uri: Uri.file('/Imports/b.mkv'), name: 'b.mkv');
      await Future.wait([
        store.record(
          a,
          const PlaybackFrame(
            position: Duration(seconds: 12),
            duration: Duration(minutes: 2),
          ),
        ),
        store.record(
          b,
          const PlaybackFrame(
            position: Duration(seconds: 20),
            duration: Duration(minutes: 2),
          ),
        ),
        store.record(
          a,
          const PlaybackFrame(
            position: Duration(seconds: 35),
            duration: Duration(minutes: 2),
          ),
        ),
      ]);
      final records = await PlaybackHistoryStore().list();
      expect(records.map((r) => r.media.name), ['旅程.mp4', 'b.mkv']);
      expect(records.first.position, const Duration(seconds: 35));
      expect(records.first.canContinue, isTrue);
    },
  );

  test('completion remains in history and corrupt entries do not hide valid records', () async {
    final store = PlaybackHistoryStore();
    final source = LocalMedia(
      uri: Uri.file('/Imports/movie.mp4'),
      name: 'movie.mp4',
    );
    await store.record(
      source,
      const PlaybackFrame(
        position: Duration(minutes: 2),
        duration: Duration(minutes: 2),
        completed: true,
      ),
    );
    final preferences = SharedPreferencesAsync();
    final values = await preferences.getStringList(PlaybackHistoryStore.key);
    await preferences.setStringList(PlaybackHistoryStore.key, [
      'broken json',
      '{}',
      ...values!,
    ]);
    final records = await store.list();
    expect(records.single.completed, isTrue);
    expect(records.single.canContinue, isFalse);
    expect(records.single.progress, 1);
  });
}
