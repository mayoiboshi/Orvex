import '../../player/domain/playback_engine.dart';
import 'anime_filename.dart';

class AnimeSubject {
  const AnimeSubject({
    required this.id,
    required this.name,
    required this.nameCn,
    this.summary = '',
    this.date = '',
    this.episodes = 0,
    this.score = 0,
    this.posterUrl,
    this.aliases = const [],
    this.type = 2,
    this.platform = '',
    this.relatedSearchNames = const [],
    this.relatedSourceIds = const [],
    this.localKey,
    this.externalIds = const {},
  });

  /// Positive IDs are exclusively Bangumi IDs. A local-only subject has ID 0.
  final int id;
  final String? localKey;
  final Map<String, String> externalIds;
  int? get bangumiId => id > 0 ? id : null;
  bool get fromLocalIndex => localKey != null;
  String get workKey =>
      bangumiId == null ? 'bangumi-data:$localKey' : 'bangumi:$id';
  final int type;
  final String platform;
  final List<String> relatedSearchNames;
  final List<int> relatedSourceIds;
  final String name;
  final String nameCn;
  final String summary;
  final String date;
  final int episodes;
  final double score;
  final String? posterUrl;
  final List<String> aliases;
  String get title => nameCn.isEmpty ? name : nameCn;
  String get sourceUrl => 'https://bgm.tv/subject/$id';
  Iterable<String> get allNames =>
      [name, nameCn, ...aliases].where((s) => s.isNotEmpty);

  AnimeSubject withRelatedSearchName(String query, List<int> sources) =>
      AnimeSubject(
        id: id,
        type: type,
        platform: platform,
        name: name,
        nameCn: nameCn,
        summary: summary,
        date: date,
        episodes: episodes,
        score: score,
        posterUrl: posterUrl,
        localKey: localKey,
        externalIds: externalIds,
        aliases: aliases,
        relatedSearchNames: {...relatedSearchNames, query}.toList(),
        relatedSourceIds: {...relatedSourceIds, ...sources}.toList(),
      );

  AnimeSubject withBangumiDetails(
    AnimeSubject online, {
    bool preserveNames = false,
  }) => AnimeSubject(
    id: id,
    type: online.type,
    name: !preserveNames && online.name.isNotEmpty ? online.name : name,
    nameCn: !preserveNames && online.nameCn.isNotEmpty ? online.nameCn : nameCn,
    summary: online.summary.isNotEmpty ? online.summary : summary,
    date: online.date.isNotEmpty ? online.date : date,
    episodes: online.episodes > 0 ? online.episodes : episodes,
    score: online.score > 0 ? online.score : score,
    posterUrl: online.posterUrl ?? posterUrl,
    platform: online.platform.isNotEmpty ? online.platform : platform,
    aliases: {...aliases, ...online.aliases}.toList(),
    externalIds: {...externalIds, ...online.externalIds},
    relatedSearchNames: online.relatedSearchNames,
    relatedSourceIds: online.relatedSourceIds,
  );

  factory AnimeSubject.fromJson(Map<String, dynamic> data) {
    final images = data['images'] as Map<String, dynamic>? ?? {};
    final rating = data['rating'] as Map<String, dynamic>? ?? {};
    final aliases = <String>[
      ...?((data['aliases'] as List?)?.whereType<String>()),
    ];
    for (final item in data['infobox'] as List? ?? []) {
      if (item is! Map || item['key'] != '别名') continue;
      final value = item['value'];
      if (value is String) aliases.add(value);
      if (value is List) {
        for (final alias in value) {
          if (alias is Map && alias['v'] is String) aliases.add(alias['v']);
        }
      }
    }
    final image =
        (data['posterUrl'] ?? images['common'] ?? images['large']) as String?;
    final url = image == null ? null : Uri.tryParse(image);
    return AnimeSubject(
      id: data['id'] as int,
      localKey: data['localKey'] as String?,
      externalIds:
          (data['externalIds'] as Map?)?.cast<String, String>() ?? const {},
      type: (data['type'] as num?)?.toInt() ?? 2,
      platform: data['platform'] as String? ?? '',
      relatedSearchNames: (data['relatedSearchNames'] as List? ?? [])
          .whereType<String>()
          .toList(),
      relatedSourceIds: (data['relatedSourceIds'] as List? ?? [])
          .whereType<int>()
          .toList(),
      name: (data['name'] as String?) ?? '',
      nameCn: (data['name_cn'] as String?) ?? '',
      summary: (data['summary'] as String?) ?? '',
      date: (data['date'] as String?) ?? '',
      episodes: ((data['eps'] ?? data['total_episodes']) as num?)?.toInt() ?? 0,
      score: ((data['score'] ?? rating['score']) as num?)?.toDouble() ?? 0,
      posterUrl: url?.scheme == 'https' && url!.host.isNotEmpty
          ? url.toString()
          : null,
      aliases: aliases,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'platform': platform,
    'relatedSearchNames': relatedSearchNames,
    'relatedSourceIds': relatedSourceIds,
    'name': name,
    'name_cn': nameCn,
    'summary': summary,
    'date': date,
    if (!fromLocalIndex || episodes > 0) 'eps': episodes,
    if (!fromLocalIndex || score > 0) 'score': score,
    if (localKey != null) 'localKey': localKey,
    if (externalIds.isNotEmpty) 'externalIds': externalIds,
    'posterUrl': posterUrl,
    'aliases': aliases,
  };
}

enum AnimeMatchStatus {
  queued,
  matched,
  needsReview,
  notFound,
  failed,
  ignored,
}

const animeMatcherVersion = 3;

class AnimeMatch {
  const AnimeMatch({
    required this.query,
    required this.status,
    required this.updatedAt,
    this.subject,
    this.candidates = const [],
    this.manual = false,
    this.error,
    this.matcherVersion = animeMatcherVersion,
    this.usedLocalIndex = false,
  });
  final String query;
  final AnimeMatchStatus status;
  final DateTime updatedAt;
  final AnimeSubject? subject;
  final List<AnimeSubject> candidates;
  final bool manual;
  final String? error;
  final int matcherVersion;
  final bool usedLocalIndex;

  Map<String, dynamic> toJson() => {
    'query': query,
    'status': status.name,
    'updatedAt': updatedAt.toIso8601String(),
    'subject': subject?.toJson(),
    'candidates': candidates.map((s) => s.toJson()).toList(),
    'manual': manual,
    if (error != null) 'error': error,
    if (usedLocalIndex) 'usedLocalIndex': true,
    'matcherVersion': matcherVersion,
  };
  factory AnimeMatch.fromJson(Map<String, dynamic> data) => AnimeMatch(
    query: data['query'] as String,
    status: AnimeMatchStatus.values.byName(data['status'] as String),
    updatedAt: DateTime.parse(data['updatedAt'] as String),
    subject: data['subject'] == null
        ? null
        : AnimeSubject.fromJson(data['subject'] as Map<String, dynamic>),
    candidates: (data['candidates'] as List? ?? [])
        .map((v) => AnimeSubject.fromJson(v as Map<String, dynamic>))
        .toList(),
    manual: data['manual'] as bool? ?? false,
    usedLocalIndex: data['usedLocalIndex'] as bool? ?? false,
    error: data['error'] as String?,
    matcherVersion: (data['matcherVersion'] as num?)?.toInt() ?? 0,
  );
}

String animeMediaKey(LocalMedia media) {
  if (media.folderRoot != null) return media.resumeKey;
  final marker = media.uri.path.lastIndexOf('/Imports/');
  return media.uri.scheme == 'file' && marker >= 0
      ? media.uri.path.substring(marker + 1)
      : media.uri.toString();
}

/// Only one exact normalized title/alias can be committed automatically.
/// Season/edition differences and similarly named results remain reviewable.
AnimeSubject? confidentAnimeMatch(
  AnimeFilename query,
  List<AnimeSubject> subjects,
) {
  final normalized = normalizedAnimeTitle(query.title);
  if (normalized.length < 2) return null;
  final exact = subjects.where((subject) {
    if (subject.type != 2) return false;
    if (query.episode != null &&
        subject.episodes > 0 &&
        query.episode! > subject.episodes) {
      return false;
    }
    if (query.year != null &&
        subject.date.isNotEmpty &&
        !subject.date.startsWith('${query.year}-')) {
      return false;
    }
    final names = [
      ...subject.allNames,
      if (query.episode != null &&
          query.episode! > 1 &&
          subject.platform == 'TV' &&
          subject.relatedSourceIds.toSet().length >= 2)
        ...subject.relatedSearchNames,
    ];
    return names.any(
      (name) =>
          normalizedAnimeTitle(name) == normalized ||
          normalizedAnimeTitle(name) == normalizedAnimeTitle(query.query),
    );
  }).toList();
  // A numbered season must match its season-bearing name, never the base title.
  if (query.season != null && query.season! > 1) {
    exact.removeWhere(
      (subject) => !subject.allNames.any(
        (name) =>
            normalizedAnimeTitle(name) == normalizedAnimeTitle(query.query),
      ),
    );
  }
  return exact.length == 1 ? exact.single : null;
}
