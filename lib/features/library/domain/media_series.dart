import '../../anime_metadata/domain/anime_filename.dart';
import '../../player/domain/playback_engine.dart';
import '../../folder_library/folder_models.dart' show naturalCompare;

/// A derived display group, never a replacement for the underlying media IDs.
class SeriesIdentity {
  const SeriesIdentity({
    required this.key,
    required this.title,
    required this.query,
    required this.episodic,
    this.episode,
  });
  final String key, title, query;
  final bool episodic;
  final int? episode;
}

SeriesIdentity identifySeries(
  LocalMedia media, {
  String? folderTitle,
  int? folderSeason,
}) {
  final parsed = AnimeFilename.parse(media.name);
  final stem = media.name.replaceFirst(RegExp(r'\.[^.]+$'), '');
  final numeric = RegExp(r'^\d{1,4}$').hasMatch(stem)
      ? int.tryParse(stem)
      : null;
  final episode = parsed.episode ?? (folderTitle == null ? null : numeric);
  final knownTitle = parsed.title.isNotEmpty ? parsed.title : folderTitle;
  final title = knownTitle == null || knownTitle.isEmpty ? stem : knownTitle;
  final season = parsed.season ?? folderSeason;
  final hasNamedSeason = RegExp(
    r'第[一二三四五六七八九十\d]+[季期]|\bseason\s*\d+|\b\d+(?:st|nd|rd|th)\s*season',
    caseSensitive: false,
  ).hasMatch(knownTitle ?? '');
  final baseQuery = parsed.title.isNotEmpty ? parsed.title : folderTitle ?? '';
  final query = baseQuery.isEmpty
      ? ''
      : season != null && season > 1 && !hasNamedSeason
      ? '$baseQuery 第$season季'
      : baseQuery;
  final episodic =
      episode != null && knownTitle != null && knownTitle.isNotEmpty;
  final scope = media.folderRoot ?? 'imports';
  return SeriesIdentity(
    key: episodic
        ? '$scope:series:${normalizedAnimeTitle(query)}:${parsed.year ?? ''}'
        : '$scope:file:${media.resumeKey}',
    title: episodic && season != null && season > 1 ? query : title,
    query: query,
    episodic: episodic,
    episode: episode,
  );
}

class MediaSeries {
  MediaSeries(this.identity, this.media);
  final SeriesIdentity identity;
  final List<LocalMedia> media;
  String get key => identity.key;
  LocalMedia get representative => media.first;
}

List<MediaSeries> groupSeries(
  Iterable<LocalMedia> files, {
  SeriesIdentity Function(LocalMedia)? identify,
}) {
  final resolver = identify ?? identifySeries;
  final groups = <String, MediaSeries>{};
  final identities = <String, SeriesIdentity>{};
  for (final media in files) {
    final identity = resolver(media);
    identities[media.resumeKey] = identity;
    groups
        .putIfAbsent(identity.key, () => MediaSeries(identity, []))
        .media
        .add(media);
  }
  for (final group in groups.values) {
    group.media.sort((a, b) {
      final aa = identities[a.resumeKey]!.episode,
          bb = identities[b.resumeKey]!.episode;
      if (aa != null && bb != null && aa != bb) return aa.compareTo(bb);
      final names = naturalCompare(a.name, b.name);
      return names == 0 ? a.resumeKey.compareTo(b.resumeKey) : names;
    });
  }
  return groups.values.toList()..sort((a, b) {
    final title = naturalCompare(a.identity.title, b.identity.title);
    return title == 0 ? a.key.compareTo(b.key) : title;
  });
}
