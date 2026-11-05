class AnimeFilename {
  const AnimeFilename({
    required this.title,
    this.episode,
    this.season,
    this.year,
  });

  final String title;
  final int? episode;
  final int? season;
  final int? year;
  String get episodeLabel => episode == null ? '' : '第 $episode 集';
  String get query =>
      season != null && season! > 1 ? '$title 第$season季' : title;

  static AnimeFilename parse(String filename) {
    var text = filename.replaceFirst(
      RegExp(r'\.[a-z0-9]{2,5}$', caseSensitive: false),
      '',
    );
    text = text.replaceAll('【', '[').replaceAll('】', ']');
    final bracketTitles = <String>[];
    int? bracketEpisode;
    int? bracketSeason;
    int? bracketYear;
    text = text.replaceAllMapped(RegExp(r'\[([^\]]+)\]'), (match) {
      final value = match[1]!.trim();
      if (RegExp(r'^(19|20)\d{2}$').hasMatch(value)) {
        bracketYear = int.parse(value);
        return ' ';
      }
      final se = RegExp(
        r'^S(\d{1,2})E(\d{1,4})$',
        caseSensitive: false,
      ).firstMatch(value);
      if (se != null) {
        bracketSeason = int.parse(se[1]!);
        bracketEpisode = int.parse(se[2]!);
        return ' ';
      }
      if (RegExp(r'^\d{1,4}(?:v\d+)?$').hasMatch(value)) {
        bracketEpisode = int.parse(value.split('v').first);
      }
      if (!_technical.hasMatch(value) &&
          !RegExp(r'^\d+(?:v\d+)?$').hasMatch(value)) {
        bracketTitles.add(value);
      }
      return ' ';
    });
    // Bracket-only releases often put a group before the title. Prefer a CJK
    // title, otherwise the longest meaningful bracket after the group.
    if (text.trim().isEmpty || RegExp(r'^[-\s\d.v]+$').hasMatch(text)) {
      final possible = bracketTitles.where((v) => !_group.hasMatch(v)).toList();
      if (possible.isNotEmpty) {
        text = possible.firstWhere(
          (v) => RegExp(r'[\u3040-\u30ff\u3400-\u9fff]').hasMatch(v),
          orElse: () => possible.last,
        );
      }
    }
    text = text
        .replaceAll('_', ' ')
        .replaceAll(RegExp(r'(?<=[a-zA-Z])\.(?=[a-zA-Z])'), ' ');
    final seasonEpisode = RegExp(
      r'\bS(\d{1,2})\s*E(\d{1,4})(?:v\d)?\b',
      caseSensitive: false,
    ).firstMatch(text);
    final episodeMatch = RegExp(
      r'(?:\s+-\s*|\bEP?\s*|第\s*)(\d{1,4})(?:v\d)?(?:\s*[集话話])?(?=\s|$|[-(])',
      caseSensitive: false,
    ).firstMatch(text);
    final trailingCandidate = RegExp(r'\s+(\d{1,4})(?:v\d)?\s*$')
        .firstMatch(text);
    final trailingEpisode =
        trailingCandidate != null &&
            !RegExp(r'^(?:19|20)\d{2}$').hasMatch(trailingCandidate[1]!)
        ? trailingCandidate
        : null;
    int? episode =
        int.tryParse(
          seasonEpisode?[2] ?? episodeMatch?[1] ?? trailingEpisode?[1] ?? '',
        ) ??
        bracketEpisode;
    int? season = int.tryParse(seasonEpisode?[1] ?? '') ?? bracketSeason;
    final titlePortion = text.substring(
      0,
      seasonEpisode?.start ??
          episodeMatch?.start ??
          trailingEpisode?.start ??
          text.length,
    );
    final yearMatch = RegExp(r'\b((?:19|20)\d{2})\b').firstMatch(titlePortion);
    final year = int.tryParse(yearMatch?[1] ?? '') ?? bracketYear;
    if (seasonEpisode != null) {
      text = text.substring(0, seasonEpisode.start);
    } else if (episodeMatch != null) {
      text = text.substring(0, episodeMatch.start);
    } else if (trailingEpisode != null) {
      text = text.substring(0, trailingEpisode.start);
    }
    text = text.replaceAll(RegExp(r'\((?:19|20)\d{2}\)'), ' ');
    text = text.replaceAll(_technical, ' ');
    text = text
        .replaceAll(RegExp(r'^[\s\-]+|[\s\-]+$'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.length < 2 || RegExp(r'^\d+$').hasMatch(text)) text = '';
    return AnimeFilename(
      title: text,
      episode: episode,
      season: season,
      year: year,
    );
  }

  static final _group = RegExp(
    r'raws|subs?|字幕|汉化|漢化|^ani$|^vcb|^ember$|^baha$',
    caseSensitive: false,
  );
  static final _technical = RegExp(
    r'\b(?:\d{3,4}[pi]|4k|8k|web[ .-]?dl|webrip|bluray|bdrip|bd|hdr10?|dv|hevc|avc|x26[45]|h[ .]?26[45]|aac|flac|opus|10bit|8bit|chs|cht|jpn|eng|multi|baha|bilibili|netflix|v2|v3)\b|简繁|簡繁|简中|繁中|内封|內封|字幕',
    caseSensitive: false,
  );
}

String normalizedAnimeTitle(String value) {
  const numerals = {
    '一': '1',
    '二': '2',
    '三': '3',
    '四': '4',
    '五': '5',
    '六': '6',
    '七': '7',
    '八': '8',
    '九': '9',
    '十': '10',
  };
  return value
      .toLowerCase()
      .replaceAllMapped(
        RegExp(r'第([一二三四五六七八九十\d]+)[季期]'),
        (match) => 'season${numerals[match[1]] ?? match[1]}',
      )
      .replaceAllMapped(
        RegExp(r'(\d+)(?:st|nd|rd|th)\s*season'),
        (match) => 'season${match[1]}',
      )
      .replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '');
}
