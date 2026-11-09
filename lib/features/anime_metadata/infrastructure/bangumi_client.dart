import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../domain/anime_episode.dart';
import '../domain/anime_subject.dart';
import '../domain/anime_filename.dart';

enum BangumiFailure {
  unavailable,
  rateLimited,
  authorization,
  cancelled,
  other,
}

class BangumiException implements Exception {
  const BangumiException(this.message, {this.kind = BangumiFailure.other});
  final BangumiFailure kind;
  final String message;
  @override
  String toString() => message;
}

class BangumiClient {
  BangumiClient({
    this.httpClient,
    this.baseUrl = 'https://api.bgm.tv',
    this.minimumInterval = const Duration(milliseconds: 600),
  });
  HttpClient? httpClient;
  final String baseUrl;
  final Duration minimumInterval;
  static const userAgent =
      'wanzhenyu/Orvex/0.1.0 (iOS/iPadOS; dev.orvex.orvex)';
  Future<void> _requests = Future.value();
  DateTime _lastRequest = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _cooldown;
  bool _closed = false;

  Future<List<AnimeEpisode>> episodes(int subjectId) async {
    const pageSize = 200;
    final episodes = <int, AnimeEpisode>{};
    try {
      for (var offset = 0; offset < 10000;) {
        final page = await _request(
          '/v0/episodes?subject_id=$subjectId&type=0&limit=$pageSize&offset=$offset',
        );
        final items = page['data'] as List;
        final total = page['total'] as int;
        for (final item in items.cast<Map<String, dynamic>>()) {
          if (item['subject_id'] != subjectId || item['type'] != 0) continue;
          final episode = AnimeEpisode.fromJson(item);
          episodes[episode.id] = episode;
        }
        offset += items.length;
        if (offset >= total) return List.unmodifiable(episodes.values);
        if (items.isEmpty) break;
      }
    } on TypeError {
      throw const BangumiException('Bangumi 单集资料格式异常');
    }
    throw const BangumiException('Bangumi 单集列表未能完整读取');
  }

  Future<AnimeSubject> subject(int id) async {
    final subject = AnimeSubject.fromJson(await _request('/v0/subjects/$id'));
    if (subject.id != id || subject.type != 2) {
      throw const BangumiException('Bangumi 返回了不同的作品');
    }
    return subject;
  }

  Future<List<AnimeSubject>> search(String keyword) async {
    if (keyword.trim().length < 2) return [];
    final data = await _request(
      '/v0/search/subjects?limit=10&offset=0',
      body: {
        'keyword': keyword.trim(),
        'sort': 'match',
        'filter': {
          'type': [2],
        },
      },
    );
    final subjects = (data['data'] as List? ?? [])
        .map((v) => AnimeSubject.fromJson(v as Map<String, dynamic>))
        .where((subject) => subject.type == 2)
        .toList();
    final normalized = normalizedAnimeTitle(keyword);
    if (subjects.any(
      (subject) => subject.allNames.any(
        (name) => normalizedAnimeTitle(name) == normalized,
      ),
    )) {
      return subjects;
    }
    // An English franchise name can be absent from its TV entry, while the
    // films have translated aliases. Require two explicit main-story links;
    // never guess the TV entry from shared title prefixes alone.
    final films = subjects
        .where(
          (subject) =>
              subject.platform == '剧场版' &&
              subject.episodes == 1 &&
              subject.allNames.any((name) {
                final parts = name.split(RegExp(r'[:：]'));
                return parts.length > 1 &&
                    normalizedAnimeTitle(parts.first) == normalized;
              }),
        )
        .take(3)
        .toList();
    if (films.length < 2) return subjects;
    try {
      final votes = <int, List<AnimeSubject>>{};
      final visited = <int>{};
      for (final film in films) {
        if (!visited.add(film.id)) continue;
        for (final root in await _mainStoryIds(film.id)) {
          votes.putIfAbsent(root, () => []).add(film);
        }
      }
      final common = votes.entries
          .where(
            (entry) =>
                entry.value.map((source) => source.id).toSet().length >= 2,
          )
          .toList();
      if (common.length != 1) return subjects;
      final root = AnimeSubject.fromJson(
        await _request('/v0/subjects/${common.single.key}'),
      );
      if (root.type != 2 || root.platform != 'TV') return subjects;
      final sourceFilms = common.single.value
          .where(
            (film) =>
                normalizedAnimeTitle(film.name)
                    .startsWith(normalizedAnimeTitle(root.name)) &&
                root.name.isNotEmpty,
          )
          .toList();
      if (sourceFilms.map((source) => source.id).toSet().length < 2) {
        return subjects;
      }
      return [
        root.withRelatedSearchName(
          keyword,
          sourceFilms.map((source) => source.id).toList(),
        ),
        ...subjects.where((subject) => subject.id != root.id),
      ];
    } on BangumiException {
      // A failed optional lookup leaves the original candidates reviewable.
      return subjects;
    }
  }

  Future<Set<int>> _mainStoryIds(int subjectId) async {
    final bytes = await _bytes('/v0/subjects/$subjectId/subjects');
    try {
      final data = jsonDecode(utf8.decode(bytes)) as List;
      return data
          .whereType<Map>()
          .where((entry) => entry['type'] == 2 && entry['relation'] == '主线故事')
          .map((entry) => entry['id'] as int)
          .toSet();
    } on FormatException {
      throw const BangumiException('Bangumi 关联数据格式异常');
    } on TypeError {
      throw const BangumiException('Bangumi 关联数据格式异常');
    }
  }

  Future<Map<String, dynamic>> _request(
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final bytes = await _bytes(path, body: body);
    try {
      return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } on FormatException {
      throw const BangumiException('Bangumi 数据格式异常，可稍后重试');
    } on TypeError {
      throw const BangumiException('Bangumi 数据格式异常，可稍后重试');
    }
  }

  Future<List<int>> fetchPoster(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        !(uri.host == 'bgm.tv' || uri.host.endsWith('.bgm.tv'))) {
      throw const BangumiException('Bangumi 封面地址无效');
    }
    return _bytes(url, image: true);
  }

  Future<List<int>> _bytes(
    String path, {
    Map<String, dynamic>? body,
    bool image = false,
  }) {
    final result = _requests.then((_) async {
      if (_closed) {
        throw const BangumiException(
          '元数据连接已关闭',
          kind: BangumiFailure.cancelled,
        );
      }
      if (_cooldown != null && DateTime.now().isBefore(_cooldown!)) {
        throw const BangumiException(
          'Bangumi 请求频繁，请稍后重试',
          kind: BangumiFailure.rateLimited,
        );
      }
      final wait = minimumInterval - DateTime.now().difference(_lastRequest);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      _lastRequest = DateTime.now();
      try {
        final client = httpClient ??= HttpClient()
          ..connectionTimeout = const Duration(seconds: 10);
        final request = await client
            .openUrl(
              body == null ? 'GET' : 'POST',
              Uri.parse(path.startsWith('/') ? '$baseUrl$path' : path),
            )
            .timeout(const Duration(seconds: 12));
        request.headers.set(HttpHeaders.userAgentHeader, userAgent);
        request.headers.set(
          HttpHeaders.acceptHeader,
          image ? 'image/*' : 'application/json',
        );
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(body));
        }
        final response = await request.close().timeout(
          const Duration(seconds: 15),
        );
        if (response.statusCode == 429) {
          final raw = response.headers.value('retry-after');
          final seconds = int.tryParse(raw ?? '');
          DateTime? deadline;
          if (raw != null && seconds == null) {
            try {
              deadline = HttpDate.parse(raw);
            } on FormatException {
              /* Use the default cooldown below. */
            }
          }
          _cooldown =
              deadline ?? DateTime.now().add(Duration(seconds: seconds ?? 60));
          await response
              .drain<void>()
              .timeout(const Duration(seconds: 5))
              .catchError((Object _) {});
          throw const BangumiException(
            'Bangumi 请求频繁，请稍后重试',
            kind: BangumiFailure.rateLimited,
          );
        }
        if (response.statusCode != 200) {
          await response
              .drain<void>()
              .timeout(const Duration(seconds: 5))
              .catchError((Object _) {});
          final status = response.statusCode;
          final kind = status == 401 || status == 403
              ? BangumiFailure.authorization
              : status >= 500 || status == 408
              ? BangumiFailure.unavailable
              : BangumiFailure.other;
          throw BangumiException(
            kind == BangumiFailure.authorization
                ? 'Bangumi 拒绝访问（$status）'
                : 'Bangumi 暂不可用（$status），请稍后重试',
            kind: kind,
          );
        }
        if (image &&
            !(response.headers.contentType?.mimeType.startsWith('image/') ??
                false)) {
          await response
              .drain<void>()
              .timeout(const Duration(seconds: 5))
              .catchError((Object _) {});
          throw const BangumiException('Bangumi 封面格式无效');
        }
        var size = 0;
        final bytes = <int>[];
        await for (final chunk in response.timeout(
          const Duration(seconds: 15),
        )) {
          size += chunk.length;
          if (size > (image ? 5 : 2) * 1024 * 1024) {
            throw const BangumiException('Bangumi 响应过大，请稍后重试');
          }
          bytes.addAll(chunk);
        }
        return bytes;
      } on BangumiException {
        rethrow;
      } on TimeoutException {
        throw const BangumiException(
          'Bangumi 连接超时，可稍后重试',
          kind: BangumiFailure.unavailable,
        );
      } on SocketException {
        throw const BangumiException(
          '无法连接 Bangumi，请检查网络后重试',
          kind: BangumiFailure.unavailable,
        );
      } on HttpException {
        throw const BangumiException(
          'Bangumi 连接中断，可稍后重试',
          kind: BangumiFailure.unavailable,
        );
      } on FormatException {
        throw const BangumiException('Bangumi 数据格式异常，可稍后重试');
      } on TypeError {
        throw const BangumiException('Bangumi 数据格式异常，可稍后重试');
      }
    });
    _requests = result.then<void>((_) {}).catchError((Object _) {});
    return result;
  }

  void close() {
    _closed = true;
    httpClient?.close(force: true);
  }
}
