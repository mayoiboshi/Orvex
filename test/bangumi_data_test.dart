import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/features/anime_metadata/application/anime_metadata_controller.dart';
import 'package:orvex/features/anime_metadata/domain/anime_subject.dart';
import 'package:orvex/features/anime_metadata/infrastructure/bangumi_client.dart';
import 'package:orvex/features/anime_metadata/infrastructure/bangumi_data_index.dart';
import 'package:orvex/features/library/domain/media_series.dart';
import 'package:orvex/features/library/domain/recent_work.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'support/fake_metadata.dart';

final fixture = jsonEncode({
  'schema': 1,
  'items': [
    [
      'Example',
      {
        'zh-Hans': ['示例动画'],
      },
      'tv',
      '2000-01-01T00:00:00Z',
      {'bangumi': '1'},
    ],
    [
      'Example Season 2',
      {},
      'tv',
      '2002-01-01T00:00:00Z',
      {'bangumi': '2'},
    ],
    [
      'Example Movie',
      {},
      'movie',
      '2003-01-01T00:00:00Z',
      {'bangumi': '3'},
    ],
    [
      'Example OVA',
      {},
      'ova',
      '2004-01-01T00:00:00Z',
      {'bangumi': '4'},
    ],
    [
      'Same Name',
      {},
      'web',
      '2020-01-01T00:00:00Z',
      {'mal': '1'},
    ],
    [
      'Same Name',
      {},
      'tv',
      '2021-01-01T00:00:00Z',
      {'bangumi': '5'},
    ],
    ['Mob Psycho 100', {}, 'tv', '2016-01-01T00:00:00Z', {}],
    [
      'Web Original',
      {},
      'web',
      '',
      {'anidb': '1'},
    ],
  ],
});

LocalMedia video(String name) =>
    LocalMedia(uri: Uri.file('/Imports/fixture/$name'), name: name);

class _Online extends FakeBangumiClient {
  Object? failure;
  final details = <int>[];
  Completer<AnimeSubject>? pendingDetails;

  @override
  Future<List<AnimeSubject>> search(String keyword) async {
    final values = await super.search(keyword);
    if (failure != null) throw failure!;
    return values;
  }

  @override
  Future<AnimeSubject> subject(int id) async {
    details.add(id);
    if (failure != null) throw failure!;
    return pendingDetails?.future ??
        const AnimeSubject(
          id: 1,
          name: 'Example online',
          nameCn: '',
          score: 8.1,
          summary: 'Online details',
        );
  }
}

Future<void> settled(AnimeMetadataController controller) async {
  final timer = Stopwatch()..start();
  while (controller.busy && timer.elapsed < const Duration(seconds: 5)) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(controller.busy, isFalse);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Online online;
  late MemoryMetadataStore store;
  late int loads;
  late bool offline;

  AnimeMetadataController create({BangumiDataAsset? asset}) {
    final controller = AnimeMetadataController(
      client: online,
      store: store,
      isOffline: () async => offline,
      localIndex:
          asset ??
          BangumiDataAsset(
            loader: () async {
              loads++;
              return BangumiDataIndex.decode(fixture);
            },
          ),
    );
    addTearDown(controller.dispose);
    return controller;
  }

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    online = _Online();
    store = MemoryMetadataStore();
    loads = 0;
    offline = false;
  });

  test('pinned real asset loads once and resolves raw titles and aliases', () async {
    final asset = BangumiDataAsset();
    final rssBefore = ProcessInfo.currentRss;
    final start = Stopwatch()..start();
    final (index, again) = await (asset.index, asset.index).wait;
    final coldMicros = start.elapsedMicroseconds;
    final rssDelta = ProcessInfo.currentRss - rssBefore;
    expect(index, same(again));
    expect(index.length, 8928);
    final conan = index
        .match(
          'Detective Conan',
          '[Fabre-RAW] Detective Conan 0644 [NetflixJP].mkv',
        )
        .subject!;
    expect(conan.bangumiId, 899);
    expect(conan.externalIds['tmdb'], 'tv/30983');
    expect(conan.title, '名侦探柯南');
    expect(conan.episodes, 0);
    expect(conan.toJson(), isNot(contains('score')));
    expect(index.search('葬送的芙莉莲').any((s) => s.bangumiId == 400602), isTrue);
    for (final title in ['Sousou no Frieren', 'Sōsō no Furīren']) {
      expect(index.search(title).single.bangumiId, 400602);
    }
    expect(
      index
          .match('Sousou no Frieren', 'Sousou no Frieren - 01.mkv')
          .subject
          ?.bangumiId,
      400602,
    );
    expect(
      index
          .match('Sousou no Frieren 第2季', 'Sousou no Frieren S02E01.mkv')
          .subject
          ?.bangumiId,
      isNot(400602),
    );
    start.reset();
    for (var i = 0; i < 1000; i++) {
      index.match('Detective Conan', 'Detective Conan 0644.mkv');
      index.search('葬送');
    }
    debugPrint(
      'BANGUMI_DATA_BENCH entries=${index.length} cold_us=$coldMicros warm_2000_us=${start.elapsedMicroseconds} rss_delta_bytes=$rssDelta',
    );
  });

  test('only exact evidence matches; seasons, editions, dates and numbers stay distinct', () {
    final index = BangumiDataIndex.decode(fixture);
    expect(index.match('示例动画', '示例动画 - 01.mkv').subject?.id, 1);
    expect(index.match('Example 第2季', 'Example S02E01.mkv').subject?.id, 2);
    expect(index.match('Example 第3季', 'Example S03E01.mkv').subject, isNull);
    expect(index.match('Example Movie', 'Example Movie.mkv').subject?.id, 3);
    expect(index.match('Example OVA', 'Example OVA.mkv').subject?.id, 4);
    expect(index.match('Same Name', 'Same Name.mkv').candidates.length, 2);
    expect(index.match('Same Name', 'Same Name.mkv').subject, isNull);
    final web = index.match('Same Name', 'Same Name (2020).mkv').subject!;
    expect(web.platform, 'WEB');
    expect(web.bangumiId, isNull);
    expect(web.workKey, startsWith('bangumi-data:'));
    expect(web.workKey, isNot(index.search('Web Original').single.workKey));
    expect(
      index.match('Mob Psycho', 'Mob Psycho 100.mkv').subject?.name,
      'Mob Psycho 100',
    );
    expect(index.match('Example', 'Example Part 2.mkv').subject, isNull);
    expect(index.match('Example', 'Example [Part 2].mkv').subject, isNull);
    expect(index.match('Examp', 'Examp.mkv').subject, isNull);
    expect(
      index.match('totally unknown', 'totally unknown.mkv').candidates,
      isEmpty,
    );
  });

  test('offline first use persists local matches, ambiguity and misses without network', () async {
    offline = true;
    final controller = create();
    final show = video('Example - 01.mkv');
    final ambiguous = video('Same Name.mkv');
    final miss = video('unknown.mkv');
    await controller.scan([show, ambiguous, miss]);
    await settled(controller);
    expect(online.queries, isEmpty);
    expect(online.posterRequests, 0);
    expect(loads, 1);
    expect(controller.matchFor(show)?.usedLocalIndex, isTrue);
    expect(
      controller.matchFor(ambiguous)?.status,
      AnimeMatchStatus.needsReview,
    );
    expect(controller.matchFor(miss)?.status, AnimeMatchStatus.notFound);
    final reopened = create();
    await reopened.initialize();
    expect(reopened.subjectFor(show)?.fromLocalIndex, isTrue);
    expect(reopened.matchFor(miss)?.usedLocalIndex, isTrue);
    expect(
      (await reopened.search('示例动画', localOnly: true)).subjects.single.id,
      1,
    );
  });

  test(
    'one timeout backs off the batch; explicit online retry can recover',
    () async {
      final controller = create();
      online.failure = TimeoutException('fixture timeout');
      final first = video('Example - 01.mkv');
      final second = video('Example S02E01.mkv');
      final third = video('Example Movie.mkv');
      await controller.scan([first, second, third]);
      await settled(controller);
      expect(online.queries, ['Example']);
      expect(loads, 1);
      expect(controller.subjectFor(second)?.id, 2);
      expect(controller.subjectFor(third)?.id, 3);
      online.failure = null;
      online.results = [const AnimeSubject(id: 17, name: 'Next', nameCn: '')];
      final recovered = await controller.search('Next');
      expect(recovered.local, isFalse);
      expect(recovered.subjects.single.id, 17);
      expect(controller.subjectFor(first)?.id, 1);
    },
  );

  test(
    'success, no results, rate limit and authorization do not use the index',
    () async {
      final controller = create();
      final first = video('Example - 01.mkv');
      final second = video('Example S02E01.mkv');
      online.results = [
        const AnimeSubject(id: 77, name: 'First', nameCn: ''),
        const AnimeSubject(id: 78, name: 'Second', nameCn: ''),
      ];
      await controller.scan([first]);
      await settled(controller);
      expect(controller.subjectFor(first)?.id, 77);
      online.results = [];
      await controller.scan([first, second]);
      await settled(controller);
      expect(controller.matchFor(second)?.status, AnimeMatchStatus.notFound);
      for (final kind in [
        BangumiFailure.rateLimited,
        BangumiFailure.authorization,
      ]) {
        online.failure = BangumiException('precise failure', kind: kind);
        await expectLater(
          controller.search('Example'),
          throwsA(isA<BangumiException>().having((e) => e.kind, 'kind', kind)),
        );
      }
      expect(loads, 0);
      expect(controller.matchFor(second)?.usedLocalIndex, isFalse);
    },
  );

  test('disabled fallback persists, manual local search remains available, automatic off stops scanning', () async {
    offline = true;
    final controller = create();
    await controller.setOfflineFallback(false);
    final reopened = create();
    await reopened.initialize();
    expect(reopened.offlineFallback, isFalse);
    final file = video('Example - 01.mkv');
    await reopened.scan([file]);
    await settled(reopened);
    expect(reopened.matchFor(file)?.status, AnimeMatchStatus.failed);
    expect(loads, 0);
    await reopened.setAutomatic(false);
    await reopened.setOfflineFallback(true);
    await reopened.scan([video('Example Movie.mkv')]);
    expect(loads, 0);
    expect(
      (await reopened.search('Example', localOnly: true)).subjects.single.id,
      1,
    );
    expect(loads, 1);
  });

  test('cancel during the online request never starts local lookup', () async {
    final controller = create();
    online.gate = Completer<void>();
    online.failure = const SocketException('test');
    final file = video('Example - 01.mkv');
    await controller.scan([file]);
    await Future<void>.delayed(Duration.zero);
    await controller.setAutomatic(false);
    online.gate!.complete();
    await settled(controller);
    expect(loads, 0);
    expect(controller.matchFor(file), isNull);
    var current = true;
    online.gate = Completer<void>();
    final request = controller.search('Example', isCurrent: () => current);
    await Future<void>.delayed(Duration.zero);
    current = false;
    online.gate!.complete();
    await expectLater(request, throwsA(isA<SocketException>()));
    expect(loads, 0);
  });

  test(
    'resource missing, invalid JSON and incompatible schema are failures',
    () async {
      offline = true;
      for (final loader in [
        () async => throw const FileSystemException('missing'),
        () async => BangumiDataIndex.decode('bad JSON'),
        () async => BangumiDataIndex.decode('{"schema":2,"items":[[]]}'),
      ]) {
        store = MemoryMetadataStore();
        final controller = create(asset: BangumiDataAsset(loader: loader));
        final file = video('Example - 01.mkv');
        await controller.scan([file]);
        await settled(controller);
        expect(controller.matchFor(file)?.status, AnimeMatchStatus.failed);
        expect(controller.matchFor(file)?.error, contains('本地番剧索引加载失败'));
        expect(controller.subjectFor(file), isNull);
        expect(online.queries, isEmpty);
      }
    },
  );

  test('enrichment uses ID, preserves local fields and cannot overwrite a newer correction', () async {
    offline = true;
    final controller = create();
    final first = video('Example - 01.mkv');
    final second = video('Example - 02.mkv');
    await controller.scan([first, second]);
    await settled(controller);
    final before = controller.subjectFor(first)!;
    await controller.select(second, before);
    expect(controller.matchFor(second)?.manual, isTrue);
    online.failure = const SocketException('test');
    await expectLater(
      controller.completeFromBangumi(first),
      throwsA(isA<SocketException>()),
    );
    expect(controller.subjectFor(first)?.fromLocalIndex, isTrue);
    online.failure = null;
    await controller.completeFromBangumi(first);
    final after = controller.subjectFor(first)!;
    expect(after.workKey, before.workKey);
    expect(after.score, 8.1);
    expect(after.date, before.date);
    expect(after.platform, 'TV');
    expect(controller.subjectFor(second)?.name, before.name);
    expect(controller.matchFor(second)?.manual, isTrue);
    expect(online.details, [1, 1]);
    expect(online.queries, isEmpty);
    final works = buildRecentWorks(
      [first, second],
      added: {},
      matchFor: controller.matchFor,
      identify: identifySeries,
    );
    expect(works.single.files.length, 2);

    final third = video('Example S02E01.mkv');
    await controller.scan([first, second, third]);
    await settled(controller);
    online.pendingDetails = Completer<AnimeSubject>();
    final pending = controller.completeFromBangumi(third);
    await Future<void>.delayed(Duration.zero);
    await controller.select(third, null);
    online.pendingDetails!.complete(
      const AnimeSubject(id: 2, name: 'Stale', nameCn: ''),
    );
    await pending;
    expect(controller.matchFor(third)?.status, AnimeMatchStatus.ignored);
  });

  test('fallback reuses saved online details and existing poster under the same ID', () async {
    final original = video('Example - 01.mkv');
    final newFile = video('示例动画 - 02.mkv');
    final cached = const AnimeSubject(
      id: 1,
      name: 'Example',
      nameCn: '示例动画',
      platform: 'TV',
      score: 9,
      posterUrl: 'https://lain.bgm.tv/cached.jpg',
    );
    store = _PosterStore()
      ..entries = {
        animeMediaKey(original): AnimeMatch(
          query: 'Example',
          status: AnimeMatchStatus.matched,
          updatedAt: DateTime.now(),
          subject: cached,
          manual: true,
        ),
      };
    offline = true;
    final controller = create();
    await controller.scan([original, newFile]);
    await settled(controller);
    expect(controller.subjectFor(newFile)?.score, 9);
    expect(controller.posterPath(1), '/cached.jpg');
    expect(online.posterRequests, 0);
    expect(controller.matchFor(original)?.manual, isTrue);
  });
}

class _PosterStore extends MemoryMetadataStore {
  @override
  Future<Map<int, String>> posters() async => {1: '/cached.jpg'};
}
