import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/anime_filename.dart';
import '../domain/anime_subject.dart';

const bangumiDataSource = 'https://github.com/bangumi-data/bangumi-data';
const bangumiDataLicense = 'https://creativecommons.org/licenses/by/4.0/';

// Reviewed Romanizations absent from the upstream snapshot. Match by the
// Bangumi work ID so editions and sequels keep their own identities.
const _romanizedAliases = <int, List<String>>{
  // https://anilist.co/anime/154587/Sousou-no-Frieren/
  400602: ['Sousou no Frieren', 'Sōsō no Furīren'],
};

class BangumiDataAsset {
  BangumiDataAsset({Future<BangumiDataIndex> Function()? loader})
    : _loader = loader ?? _loadBundle;

  final Future<BangumiDataIndex> Function() _loader;
  late final Future<BangumiDataIndex> index = Future.sync(_loader);

  static Future<BangumiDataIndex> _loadBundle() async {
    final bytes = await rootBundle.load('assets/metadata/bangumi-data.json');
    final manifest = await rootBundle.loadString(
      'assets/metadata/bangumi-data-manifest.json',
    );
    return compute(_verifyAndDecode, (
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      manifest,
    ));
  }

  static BangumiDataIndex _verifyAndDecode((Uint8List, String) input) {
    final (bytes, manifest) = input;
    final expected = jsonDecode(manifest) as Map<String, dynamic>;
    if (sha256.convert(bytes).toString() != expected['assetSha256']) {
      throw const FormatException('本地索引校验失败');
    }
    final index = BangumiDataIndex.decode(utf8.decode(bytes));
    if (index.length != expected['entries']) {
      throw const FormatException('本地索引条目数量不符');
    }
    return index;
  }
}

/// No remote probe. An interface alone never proves Internet reachability.
Future<bool> definitelyOffline() async {
  try {
    return (await NetworkInterface.list().timeout(const Duration(seconds: 1)))
        .isEmpty;
  } catch (_) {
    return false;
  }
}

class BangumiDataIndex {
  BangumiDataIndex._(this._names, this._prefixes, this.length);

  final Map<String, List<AnimeSubject>> _names;
  final Map<String, List<String>> _prefixes;
  final int length;

  factory BangumiDataIndex.decode(String source) {
    final data = jsonDecode(source) as Map<String, dynamic>;
    final items = data['items'] as List;
    if (data['schema'] != 1 || items.isEmpty) {
      throw const FormatException('本地索引格式不受支持');
    }
    final names = <String, List<AnimeSubject>>{};
    for (final item in items.cast<List>()) {
      final title = item[0] as String;
      final translations = (item[1] as Map).cast<String, List>();
      final kind = item[2] as String;
      final begin = item[3] as String;
      final ids = (item[4] as Map).cast<String, String>();
      final date = DateTime.tryParse(begin) == null || begin.length < 10
          ? ''
          : begin.substring(0, 10);
      final platform = switch (kind) {
        'tv' => 'TV',
        'movie' => '剧场版',
        'ova' => 'OVA',
        'web' => 'WEB',
        _ => throw const FormatException('本地索引含未知作品类型'),
      };
      if (title.trim().isEmpty) throw const FormatException('本地作品缺少名称');
      final id = int.tryParse(ids['bangumi'] ?? '') ?? 0;
      final localKey = id > 0
          ? 'subject:$id'
          : sha256
                .convert(
                  utf8.encode(
                    jsonEncode([
                      title,
                      kind,
                      begin,
                      for (final entry in ids.entries) [entry.key, entry.value],
                    ]),
                  ),
                )
                .toString();
      final subject = AnimeSubject(
        id: id,
        localKey: localKey,
        externalIds: Map.unmodifiable(ids),
        name: title,
        nameCn: translations['zh-Hans']?.whereType<String>().firstOrNull ?? '',
        aliases: [
          for (final aliases in translations.values) ...aliases.cast<String>(),
          ...?_romanizedAliases[id],
        ],
        date: date,
        platform: platform,
      );
      for (final name in subject.allNames.map(_normalize).toSet()) {
        if (name.length >= 2) (names[name] ??= []).add(subject);
      }
    }
    final prefixes = <String, List<String>>{};
    for (final name in names.keys) {
      (prefixes[name.substring(0, 2)] ??= []).add(name);
    }
    return BangumiDataIndex._(names, prefixes, items.length);
  }

  List<AnimeSubject> search(String input) {
    final key = _normalize(input);
    if (key.length < 2) return const [];
    final exact = _names[key];
    if (exact != null) return List.unmodifiable(exact);
    final matches = <AnimeSubject>{};
    for (final name in _prefixes[key.substring(0, 2)] ?? const <String>[]) {
      if (name.startsWith(key) || key.startsWith(name)) {
        matches.addAll(_names[name]!);
        if (matches.length >= 12) break;
      }
    }
    return matches.take(12).toList();
  }

  ({AnimeSubject? subject, List<AnimeSubject> candidates}) match(
    String query,
    String filename,
  ) {
    final hints = AnimeFilename.parse(filename);
    final stem = filename.replaceFirst(
      RegExp(r'\.[a-z0-9]{2,5}$', caseSensitive: false),
      '',
    );
    final rawKey = _normalize(stem);
    final key = _normalize(query);
    final raw = _names[rawKey];
    final candidates = raw ?? _names[key] ?? search(query);
    if (candidates.isEmpty) return (subject: null, candidates: const []);
    final exact = raw ?? _names[key] ?? const <AnimeSubject>[];
    final explicitType = _edition(stem);
    final editions = RegExp(r'(?:season|part)\d+|第\d+[部篇]');
    final editionTokens = editions
        .allMatches(rawKey)
        .map((match) => match[0]!)
        .toSet();
    final ambiguousNumber =
        raw == null &&
        RegExp(r'\s+[1-9]\d{0,2}$').hasMatch(stem) &&
        !RegExp(
          r'(?:\s-\s|\bEP?\s*|第\s*)\d',
          caseSensitive: false,
        ).hasMatch(stem);
    final eligible = exact.where((subject) {
      if (ambiguousNumber) return false;
      if (editionTokens.isNotEmpty &&
          !subject.allNames
              .map(_normalize)
              .any(
                (name) => editions
                    .allMatches(name)
                    .map((match) => match[0]!)
                    .toSet()
                    .containsAll(editionTokens),
              )) {
        return false;
      }
      if (explicitType != null && subject.platform != explicitType) {
        return false;
      }
      if (hints.year != null && !subject.date.startsWith('${hints.year}-')) {
        return false;
      }
      if ((hints.season ?? 1) > 1 && !key.contains('season${hints.season}')) {
        return false;
      }
      return true;
    }).toList();
    return (
      subject: eligible.length == 1 ? eligible.single : null,
      candidates: List.unmodifiable(candidates),
    );
  }

  static String? _edition(String title) {
    if (RegExp(r'剧场版|劇場版|\bmovie\b', caseSensitive: false).hasMatch(title)) {
      return '剧场版';
    }
    if (RegExp(r'\bova\b', caseSensitive: false).hasMatch(title)) return 'OVA';
    return null;
  }

  static String _normalize(String title) => normalizedAnimeTitle(
    String.fromCharCodes(
      title.runes.map(
        (rune) => rune >= 0xFF01 && rune <= 0xFF5E ? rune - 0xFEE0 : rune,
      ),
    ),
  );
}
