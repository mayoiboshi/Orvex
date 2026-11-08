import '../../anime_metadata/domain/anime_filename.dart';
import '../../anime_metadata/domain/anime_subject.dart';
import '../../player/domain/playback_engine.dart';
import 'media_series.dart';

class RecentWork {
  const RecentWork({
    required this.key,
    required this.representative,
    required this.files,
    this.subject,
  });

  final String key;
  final LocalMedia representative;
  final List<LocalMedia> files;
  final AnimeSubject? subject;
}

List<RecentWork> buildRecentWorks(
  List<LocalMedia> media, {
  required Map<String, DateTime> added,
  required AnimeMatch? Function(LocalMedia) matchFor,
  required SeriesIdentity Function(LocalMedia) identify,
}) {
  final groups = <String, List<LocalMedia>>{};
  final subjects = <String, AnimeSubject>{};
  final latest = <String, DateTime>{};
  final representatives = <String, LocalMedia>{};
  final identities = <String, SeriesIdentity>{};
  final positions = <String, int>{};
  final unknownDate = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  for (final (index, file) in media.indexed) {
    if (positions.containsKey(file.resumeKey)) continue;
    positions[file.resumeKey] = index;
    final match = matchFor(file);
    final identity = identify(file);
    identities[file.resumeKey] = identity;
    final subject = _confirmedSeries(file, match, identity);
    final key = subject == null
        ? 'file:${file.resumeKey}'
        : 'bangumi:${subject.id}';
    if (subject != null) subjects[key] = subject;
    (groups[key] ??= []).add(file);
    final date = added[file.resumeKey] ?? file.modifiedAt ?? unknownDate;
    final previous = latest[key];
    if (previous == null || date.isAfter(previous)) {
      latest[key] = date;
      representatives[key] = file;
    }
  }

  final keys = groups.keys.toList()
    ..sort((a, b) {
      final date = latest[b]!.compareTo(latest[a]!);
      return date != 0
          ? date
          : positions[representatives[a]!.resumeKey]!.compareTo(
              positions[representatives[b]!.resumeKey]!,
            );
    });

  return [
    for (final key in keys)
      RecentWork(
        key: key,
        representative: representatives[key]!,
        subject: subjects[key],
        files: List.unmodifiable(
          groups[key]!..sort((a, b) {
            final first = identities[a.resumeKey]!;
            final second = identities[b.resumeKey]!;
            final season = (first.season ?? 1).compareTo(second.season ?? 1);
            if (season != 0) return season;
            final episode = (first.episode ?? 100000).compareTo(
              second.episode ?? 100000,
            );
            return episode == 0
                ? positions[a.resumeKey]!.compareTo(positions[b.resumeKey]!)
                : episode;
          }),
        ),
      ),
  ];
}

AnimeSubject? _confirmedSeries(
  LocalMedia file,
  AnimeMatch? match,
  SeriesIdentity identity,
) {
  final subject = match?.subject;
  if (match?.status != AnimeMatchStatus.matched ||
      subject == null ||
      subject.type != 2 ||
      subject.platform == '剧场版' ||
      (subject.platform != 'TV' && subject.episodes <= 1)) {
    return null;
  }
  if (match!.manual) return subject;
  if (!identity.episodic) return null;
  final filename = AnimeFilename.parse(file.name);
  final candidates = match.candidates;
  final query = AnimeFilename(
    title: filename.title.isEmpty ? identity.title : filename.title,
    episode: identity.episode,
    season: identity.season,
    year: filename.year,
  );
  return confidentAnimeMatch(query, candidates)?.id == subject.id
      ? subject
      : null;
}
