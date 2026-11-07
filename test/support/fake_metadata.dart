import 'dart:async';

import 'package:orvex/features/anime_metadata/domain/anime_episode.dart';
import 'package:orvex/features/anime_metadata/domain/anime_subject.dart';
import 'package:orvex/features/anime_metadata/infrastructure/bangumi_client.dart';
import 'package:orvex/features/anime_metadata/infrastructure/metadata_store.dart';

class MemoryMetadataStore extends MetadataStore {
  bool automatic = true;
  Map<String, AnimeMatch> entries = {};
  bool failWrites = false;

  @override
  Future<Map<int, String>> posters() async => {};

  @override
  Future<({bool automatic, Map<String, AnimeMatch> entries})> read() async =>
      (automatic: automatic, entries: Map.of(entries));

  @override
  Future<void> write(bool automatic, Map<String, AnimeMatch> entries) async {
    if (failWrites) throw StateError('disk full');
    this.automatic = automatic;
    this.entries = entries.map(
      (key, value) => MapEntry(key, AnimeMatch.fromJson(value.toJson())),
    );
  }
}

class FakeBangumiClient extends BangumiClient {
  List<AnimeSubject> results = [];
  final List<String> queries = [];
  Completer<void>? gate;
  bool fail = false;
  List<int> posterBytes = [1, 2, 3];
  int posterRequests = 0;
  final episodeResults = <int, List<AnimeEpisode>>{};
  final episodeRequests = <int>[];

  @override
  Future<List<AnimeEpisode>> episodes(int subjectId) async {
    episodeRequests.add(subjectId);
    if (fail) throw const BangumiException('单集资料暂时无法连接');
    return episodeResults[subjectId] ?? [];
  }

  @override
  Future<List<int>> fetchPoster(String url) async {
    posterRequests++;
    if (fail) throw const BangumiException('封面无法连接');
    return posterBytes;
  }

  @override
  Future<List<AnimeSubject>> search(String keyword) async {
    queries.add(keyword);
    await gate?.future;
    if (fail) throw const BangumiException('无法连接 Bangumi，请检查网络后重试');
    return results;
  }
}
