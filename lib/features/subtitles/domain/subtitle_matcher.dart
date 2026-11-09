import '../../anime_metadata/domain/anime_filename.dart';
import 'subtitle_models.dart';

String _stem(String name) =>
    name.replaceFirst(RegExp(r'\.[^.]+$'), '').trim().toLowerCase();
String _withoutLanguage(String value) {
  final suffix = RegExp(
    r'(?:[. _-](?:zh(?:[-_](?:hans|hant|cn|tw))?|chs|cht|sc|tc|en|eng|ja|jpn|简体|繁体|简中|繁中|双语|中文字幕)|\[(?:chs|cht|sc|tc|zh-hans|zh-hant|简体|繁体|简中|繁中|双语)\])$',
    caseSensitive: false,
  );
  var previous = '';
  while (previous != value) {
    previous = value;
    value = value.replaceFirst(suffix, '').trim();
  }
  return value;
}

({int? season, int? episode}) _episode(
  String name, {
  bool subtitleHeading = false,
}) {
  final value = _withoutLanguage(_stem(name));
  final parsed = AnimeFilename.parse('$value.mkv');
  // Subtitle releases also use "615集 Title.ass", without a leading 第.
  // Keep this local to subtitle matching; media grouping/search is unchanged.
  final heading = RegExp(r'^(\d{1,4})\s*(?:集|话|話)(?=\D|$)').firstMatch(value);
  // Some subtitle collections use "647 中文标题.ass". Restrict this
  // additional form to subtitle names and avoid treating years as episodes.
  final spacedHeading = subtitleHeading
      ? RegExp(r'^(\d{1,4})\s+(?=[\u3400-\u9fff])').firstMatch(value)
      : null;
  final spacedNumber = spacedHeading?[1];
  final spacedEpisode =
      spacedNumber != null &&
          !RegExp(r'^(?:19|20)\d{2}$').hasMatch(spacedNumber)
      ? int.tryParse(spacedNumber)
      : null;
  // A conflicting explicit episode label makes this heading ambiguous.
  final explicitLabels = <int>[
    for (final match in RegExp(
      r'(?:\bs\d{1,2}\s*e|\bep?\s*|第\s*)(\d{1,4})(?:v\d)?(?:\s*[集话話])?(?=\s|$|[-(\]])',
      caseSensitive: false,
    ).allMatches(value))
      int.parse(match[1]!),
    for (final match in RegExp(r'\[(\d{1,4})(?:v\d+)?\]').allMatches(value))
      if (!RegExp(r'^(?:19|20)\d{2}$').hasMatch(match[1]!))
        int.parse(match[1]!),
  ];
  final conflictingHeading =
      spacedEpisode != null &&
      explicitLabels.any((episode) => episode != spacedEpisode);
  final pure = RegExp(r'^\d{1,4}$').hasMatch(value)
      ? int.tryParse(value)
      : null;
  return (
    season: parsed.season,
    episode: conflictingHeading
        ? null
        : int.tryParse(heading?[1] ?? '') ??
              (parsed.season != null ? parsed.episode : null) ??
              spacedEpisode ??
              parsed.episode ??
              pure,
  );
}

SubtitleMatch matchSubtitleName(String video, String subtitle) {
  if (!isSubtitleName(subtitle)) return SubtitleMatch.none;
  final a = _stem(video), b = _stem(subtitle);
  if (a.isNotEmpty && a == b) return SubtitleMatch.exact;
  final aa = _withoutLanguage(a), bb = _withoutLanguage(b);
  if (aa.isNotEmpty && aa == bb) return SubtitleMatch.languageName;
  final av = _episode(video), bv = _episode(subtitle, subtitleHeading: true);
  if (av.episode == null || av.episode != bv.episode) return SubtitleMatch.none;
  if (av.season != null && bv.season != null && av.season != bv.season) {
    return SubtitleMatch.none;
  }
  return SubtitleMatch.episode;
}
