import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/features/anime_metadata/domain/anime_subject.dart';
import 'package:orvex/features/library/domain/library_overview.dart';
import 'package:orvex/features/library/domain/media_series.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';

void main() {
  LocalMedia video(String name, {DateTime? modified}) => LocalMedia(
    uri: Uri.file('/media/$name'),
    name: name,
    modifiedAt: modified,
  );
  final episode1 = video('Example - 01.mp4');
  final episode2 = video('Example - 02.mp4');
  final movie = video('Movie.mp4');
  final uncertain = video('Ambiguous.mp4');
  final unidentified = video('Local.mp4', modified: DateTime.utc(2024));
  final matches = <String, AnimeMatch>{};
  void match(LocalMedia media, AnimeSubject subject, {bool manual = true}) {
    matches[media.resumeKey] = AnimeMatch(
      query: subject.title,
      status: AnimeMatchStatus.matched,
      updatedAt: DateTime.utc(2026),
      subject: subject,
      candidates: [subject],
      manual: manual,
    );
  }

  setUp(() {
    matches.clear();
    match(
      episode1,
      const AnimeSubject(
        id: 1,
        name: 'Example',
        nameCn: '',
        platform: 'TV',
        date: '2025',
        score: 8,
      ),
      manual: false,
    );
    match(
      movie,
      const AnimeSubject(
        id: 2,
        name: 'Movie',
        nameCn: '',
        platform: '剧场版',
        date: '2020',
        score: 7,
      ),
    );
    match(
      uncertain,
      const AnimeSubject(id: 3, name: 'Different', nameCn: '', platform: '剧场版'),
      manual: false,
    );
  });

  List<LibraryEntry> entries() => libraryEntries(
    groupSeries([episode1, episode2, movie, uncertain, unidentified]),
    arrivals: {
      episode1.resumeKey: DateTime.utc(2023),
      episode2.resumeKey: DateTime.utc(2026),
      movie.resumeKey: DateTime.utc(2025),
    },
    matchFor: (media) => matches[media.resumeKey],
    identify: identifySeries,
  );

  List<LibraryEntry> browse({
    LibrarySort sort = defaultLibrarySort,
    LibraryKind filter = LibraryKind.all,
    String query = '',
  }) => browseLibrary(entries(), query: query, filter: filter, sort: sort);

  test('uses newest arrival in each group and falls back to file date', () {
    final results = browse();
    expect(results.map((entry) => entry.title), [
      'Example',
      'Movie',
      'Local',
      'Different',
    ]);
    expect(results.first.group.media, [episode1, episode2]);
  });

  test('searches filenames together with reliable type filters', () {
    expect(
      browse(filter: LibraryKind.movie, query: ' movie ').single.title,
      'Movie',
    );
    expect(
      browse(filter: LibraryKind.series, query: '02.mp4').single.title,
      'Example',
    );
    expect(browse(filter: LibraryKind.unknown).map((entry) => entry.title), [
      'Local',
      'Different',
    ]);
  });

  test('conflicting subject IDs never classify an existing group', () {
    match(
      episode2,
      const AnimeSubject(id: 4, name: 'Example', nameCn: '', platform: 'TV'),
    );
    expect(browse(filter: LibraryKind.series), isEmpty);
    expect(browse().first.kind, LibraryKind.unknown);
    expect(browse().first.group.media.length, 2);
  });

  test('year and score put missing values last in both directions', () {
    for (final field in [LibrarySortField.year, LibrarySortField.score]) {
      final ascending = browse(sort: (field: field, descending: false));
      final descending = browse(sort: (field: field, descending: true));
      expect(ascending.map((entry) => entry.title), [
        'Movie',
        'Example',
        'Different',
        'Local',
      ]);
      expect(descending.map((entry) => entry.title), [
        'Example',
        'Movie',
        'Different',
        'Local',
      ]);
    }
  });
}
