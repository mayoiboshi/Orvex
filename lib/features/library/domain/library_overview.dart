import '../../anime_metadata/domain/anime_filename.dart';
import '../../anime_metadata/domain/anime_subject.dart';
import '../../folder_library/folder_models.dart';
import '../../player/domain/playback_engine.dart';
import 'media_series.dart';

enum LibraryKind { all, movie, series, unknown }

enum LibrarySortField { added, name, year, score }

typedef LibrarySort = ({LibrarySortField field, bool descending});

const defaultLibrarySort = (field: LibrarySortField.added, descending: true);

class LibraryEntry {
  LibraryEntry({
    required this.group,
    required this.subject,
    required this.kind,
    required this.added,
    required this.searchText,
  });

  final MediaSeries group;
  final AnimeSubject? subject;
  final LibraryKind kind;
  final DateTime? added;
  final String searchText;
  String get title =>
      subject?.title.isNotEmpty == true ? subject!.title : group.identity.title;
  int? get year {
    final date = subject?.date ?? '';
    if (date.length < 4) return null;
    final parsed = int.tryParse(date.substring(0, 4));
    return parsed != null && parsed > 0 ? parsed : null;
  }

  double? get score {
    final value = subject?.score;
    return value != null && value.isFinite && value > 0 ? value : null;
  }
}

List<LibraryEntry> libraryEntries(
  Iterable<MediaSeries> groups, {
  required Map<String, DateTime> arrivals,
  required AnimeMatch? Function(LocalMedia) matchFor,
  required SeriesIdentity Function(LocalMedia) identify,
}) => [
  for (final group in groups)
    _entry(group, arrivals: arrivals, matchFor: matchFor, identify: identify),
];

LibraryEntry _entry(
  MediaSeries group, {
  required Map<String, DateTime> arrivals,
  required AnimeMatch? Function(LocalMedia) matchFor,
  required SeriesIdentity Function(LocalMedia) identify,
}) {
  final subjects = <int, AnimeSubject>{};
  final confirmed = <int>{};
  DateTime? added;
  for (final media in group.media) {
    final date = arrivals[media.resumeKey] ?? media.modifiedAt;
    if (date != null && (added == null || date.isAfter(added))) added = date;
    final match = matchFor(media);
    final subject = match?.subject;
    if (match == null ||
        match.status != AnimeMatchStatus.matched ||
        subject == null ||
        subject.type != 2) {
      continue;
    }
    subjects.putIfAbsent(subject.id, () => subject);
    if (match.manual) {
      confirmed.add(subject.id);
      continue;
    }
    final filename = AnimeFilename.parse(media.name);
    final identity = identify(media);
    final query = AnimeFilename(
      title: filename.title.isEmpty ? identity.title : filename.title,
      episode: identity.episode,
      season: identity.season,
      year: filename.year,
    );
    if (confidentAnimeMatch(query, match.candidates)?.id == subject.id) {
      confirmed.add(subject.id);
    }
  }
  final subject = subjects.length == 1 ? subjects.values.single : null;
  final platform = subject?.platform.trim() ?? '';
  final kind = !confirmed.contains(subject?.id)
      ? LibraryKind.unknown
      : platform == '剧场版'
      ? LibraryKind.movie
      : platform == 'TV' || subject!.episodes > 1
      ? LibraryKind.series
      : LibraryKind.unknown;
  return LibraryEntry(
    group: group,
    subject: subject,
    kind: kind,
    added: added,
    searchText: [
      group.identity.title,
      for (final item in subjects.values) ...item.allNames,
      for (final media in group.media) media.name,
    ].join(' ').toLowerCase(),
  );
}

List<LibraryEntry> browseLibrary(
  Iterable<LibraryEntry> entries, {
  required String query,
  required LibraryKind filter,
  required LibrarySort sort,
}) {
  final search = query.trim().toLowerCase();
  final results = entries
      .where(
        (entry) =>
            (filter == LibraryKind.all || entry.kind == filter) &&
            entry.searchText.contains(search),
      )
      .toList();
  int compareValues<T extends Comparable<Object>>(T? a, T? b) {
    if (a == null) return b == null ? 0 : 1;
    if (b == null) return -1;
    return sort.descending ? b.compareTo(a) : a.compareTo(b);
  }

  return results..sort((a, b) {
    final primary = switch (sort.field) {
      LibrarySortField.added => compareValues(a.added, b.added),
      LibrarySortField.name =>
        sort.descending
            ? naturalCompare(b.title, a.title)
            : naturalCompare(a.title, b.title),
      LibrarySortField.year => compareValues(a.year, b.year),
      LibrarySortField.score => compareValues(a.score, b.score),
    };
    if (primary != 0) return primary;
    final name = naturalCompare(a.title, b.title);
    return name == 0 ? a.group.key.compareTo(b.group.key) : name;
  });
}
