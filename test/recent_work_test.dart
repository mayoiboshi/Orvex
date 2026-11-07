import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/features/anime_metadata/domain/anime_subject.dart';
import 'package:orvex/features/library/domain/media_series.dart';
import 'package:orvex/features/library/domain/recent_work.dart';
import 'package:orvex/features/library/infrastructure/recent_arrival_index.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

LocalMedia file(String name, int day, {bool imported = false}) => LocalMedia(
  uri: Uri.file('/fixtures/$name.mp4'),
  name: '$name.mp4',
  importPath: imported ? 'Imports/$name.mp4' : null,
  modifiedAt: DateTime.utc(2026, 11, day),
);

void main() {
  test(
    'group by confirmed series ID across seasons and sort by newest arrival',
    () {
      const original = AnimeSubject(
        id: 1,
        name: 'Show',
        nameCn: '',
        platform: 'TV',
      );
      const sameName = AnimeSubject(
        id: 2,
        name: 'Show',
        nameCn: '',
        platform: 'TV',
      );
      const filmOne = AnimeSubject(
        id: 3,
        name: 'Movie',
        nameCn: '',
        platform: '剧场版',
      );
      const filmTwo = AnimeSubject(
        id: 4,
        name: 'Movie II',
        nameCn: '',
        platform: '剧场版',
      );
      final first = file('Show S01E03', 1);
      final nextSeason = file('Show S02E01', 2);
      final separate = file('Other copy', 4);
      final movie = file('Movie', 5);
      final sequel = file('Movie II', 6);
      final ordinary = file('Phone video 42', 7);
      final unknown = file('Show - 04', 8);
      final uncertain = file('Another show - 05', 9);
      AnimeMatch matched(AnimeSubject subject, {bool manual = true}) =>
          AnimeMatch(
            query: subject.name,
            status: AnimeMatchStatus.matched,
            updatedAt: DateTime.utc(2026, 11, 1),
            subject: subject,
            candidates: [subject],
            manual: manual,
          );
      final matches = {
        first: matched(original),
        nextSeason: matched(original),
        separate: matched(sameName),
        movie: matched(filmOne),
        sequel: matched(filmTwo),
        uncertain: matched(original, manual: false),
      };
      final media = [
        first,
        nextSeason,
        separate,
        movie,
        sequel,
        ordinary,
        unknown,
        uncertain,
      ];
      List<RecentWork> groups(Map<String, DateTime> added) => buildRecentWorks(
        media,
        added: added,
        matchFor: (file) => matches[file],
        identify: identifySeries,
        resumedFile: first.resumeKey,
      );
      final old = groups({});
      expect(old.first.representative, same(uncertain));
      expect(old.where((work) => work.subject?.id == 2).single.files, [
        separate,
      ]);
      expect(
        old
            .where((work) => work.subject == null)
            .map((work) => work.representative),
        containsAll([movie, sequel, ordinary, unknown, uncertain]),
      );
      expect(old.length, 7);

      final recent = groups({nextSeason.resumeKey: DateTime.utc(2026, 11, 10)});
      expect(recent.first.subject, same(original));
      expect(recent.first.representative, same(nextSeason));
      expect(recent.first.files, [first, nextSeason]);
    },
  );

  test('an exact automatic match may group, an ambiguous candidate remains independent', () {
    const subject = AnimeSubject(
      id: 1,
      name: 'Show',
      nameCn: '',
      platform: 'TV',
    );
    const other = AnimeSubject(id: 2, name: 'Show', nameCn: '', platform: 'TV');
    final first = file('Show - 01', 1);
    final second = file('Show - 02', 2);
    final third = file('Show - 03', 3);
    final groups = buildRecentWorks(
      [first, second, third],
      added: {},
      matchFor: (media) => AnimeMatch(
        query: 'Show',
        status: AnimeMatchStatus.matched,
        updatedAt: DateTime.utc(2026, 11, 1),
        subject: subject,
        candidates: [subject, if (media == third) other],
      ),
      identify: identifySeries,
    );
    expect(groups.first.representative, third);
    expect(groups.first.subject, isNull);
    expect(groups.last.files, [first, second]);
  });

  test('arrival index retains its upgrade baseline and first observation after restart', () async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    final preferences = SharedPreferencesAsync();
    var now = DateTime.utc(2026, 11, 8);
    RecentArrivalIndex index() =>
        RecentArrivalIndex(preferences, clock: () => now);
    final old = file('old', 1, imported: true);
    final oldFolder = file('indexed folder', 2);
    final baseline = index();
    expect(await baseline.observe([old, oldFolder]), isEmpty);
    final imported = file('new copy', 9, imported: true);
    final indexed = file('new external file', 3);
    now = DateTime.utc(2026, 11, 10);
    final restarted = index();
    final arrivals = await restarted.observe([old, imported, indexed]);
    expect(arrivals, {
      imported.resumeKey: DateTime.utc(2026, 11, 9),
      indexed.resumeKey: now,
    });
    now = DateTime.utc(2026, 11, 11);
    expect(
      await index().observe([old, oldFolder, imported, indexed]),
      arrivals,
    );
  });
}
