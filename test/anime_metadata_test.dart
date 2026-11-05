import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/features/anime_metadata/application/anime_metadata_controller.dart';
import 'package:orvex/features/anime_metadata/domain/anime_filename.dart';
import 'package:orvex/features/anime_metadata/domain/anime_subject.dart';
import 'package:orvex/features/anime_metadata/infrastructure/metadata_store.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';

import 'support/fake_metadata.dart';

const frieren = AnimeSubject(
  id: 400602,
  name: '葬送のフリーレン',
  nameCn: '葬送的芙莉莲',
  date: '2023-09-29',
  episodes: 28,
  aliases: ['Sousou no Frieren', '葬送的芙莉蓮'],
);
const seasonTwo = AnimeSubject(
  id: 515759,
  name: '葬送のフリーレン 第2期',
  nameCn: '葬送的芙莉莲 第二季',
  date: '2026-01-16',
  episodes: 10,
);

LocalMedia media(String name, {String container = 'one'}) => LocalMedia(
  uri: Uri.file('/$container/Documents/Imports/media-a/$name'),
  name: name,
);

Future<void> idle(AnimeMetadataController controller) async {
  for (var i = 0; i < 100 && controller.busy; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(controller.busy, isFalse);
}

void main() {
  test('reported four-digit Conan episode is removed without treating release years as episodes', () {
    final parsed = AnimeFilename.parse(
      '[Fabre–RAW] Detective Conan 0615 [NetflixJP] [1080p].mkv',
    );
    expect(parsed.title, 'Detective Conan');
    expect(parsed.query, 'Detective Conan');
    expect(parsed.episode, 615);
    expect(parsed.year, isNull);
    expect(AnimeFilename.parse('Detective Conan [0615].mkv').episode, 615);
    expect(AnimeFilename.parse('Detective Conan S01E1234.mkv').episode, 1234);
    expect(AnimeFilename.parse('Detective Conan E2023.mkv').episode, 2023);
    expect(AnimeFilename.parse('Detective Conan E2023.mkv').year, isNull);
    expect(AnimeFilename.parse('Movie 2023.mkv').episode, isNull);
    expect(AnimeFilename.parse('Movie [2023].mkv').year, 2023);
  });

  test('main-story evidence requires two sources, a TV series and an episodic file', () {
    const root = AnimeSubject(
      id: 899,
      name: '名探偵コナン',
      nameCn: '名侦探柯南',
      platform: 'TV',
    );
    final proven = root.withRelatedSearchName('Detective Conan', [10, 20]);
    expect(
      confidentAnimeMatch(AnimeFilename.parse('Detective Conan 0615.mkv'), [
        proven,
      ])?.id,
      899,
    );
    expect(
      confidentAnimeMatch(AnimeFilename.parse('Detective Conan.mkv'), [proven]),
      isNull,
    );
    expect(
      confidentAnimeMatch(AnimeFilename.parse('Detective Conan 01.mkv'), [
        proven,
      ]),
      isNull,
    );
    expect(
      confidentAnimeMatch(AnimeFilename.parse('Detective Conan 0615.mkv'), [
        root.withRelatedSearchName('Detective Conan', [10]),
      ]),
      isNull,
    );
    expect(
      confidentAnimeMatch(AnimeFilename.parse('Detective Conan S02E03.mkv'), [
        proven,
      ]),
      isNull,
    );
    final restored = AnimeSubject.fromJson(proven.toJson());
    expect(
      restored.aliases,
      isEmpty,
      reason: 'inferred franchise names are not presented as official aliases',
    );
    expect(restored.relatedSourceIds, [10, 20]);
  });

  test('old automatic review cache is retried after update while manual selections survive', () async {
    final video = media(
      '[Fabre-RAW] Detective Conan 0615 [NetflixJP] [1080p].mkv',
    );
    final manualVideo = media('Manual - 01.mp4');
    final pendingVideo = media('Pending - 01.mp4');
    final previouslyMatched = media('葬送的芙莉莲 - 03.mp4');
    final store = MemoryMetadataStore()
      ..entries = {
        animeMediaKey(video): AnimeMatch(
          query: 'Detective Conan 0615',
          status: AnimeMatchStatus.needsReview,
          updatedAt: DateTime.now(),
          matcherVersion: 0,
        ),
        animeMediaKey(manualVideo): AnimeMatch(
          query: 'Manual',
          status: AnimeMatchStatus.matched,
          updatedAt: DateTime.now(),
          subject: frieren,
          manual: true,
          matcherVersion: 0,
        ),
        animeMediaKey(pendingVideo): AnimeMatch(
          query: 'Pending',
          status: AnimeMatchStatus.queued,
          updatedAt: DateTime.now(),
        ),
        animeMediaKey(previouslyMatched): AnimeMatch(
          query: '葬送的芙莉莲',
          status: AnimeMatchStatus.matched,
          updatedAt: DateTime.now(),
          subject: frieren,
          matcherVersion: 0,
        ),
      };
    final root = const AnimeSubject(
      id: 899,
      name: '名探偵コナン',
      nameCn: '名侦探柯南',
      platform: 'TV',
    ).withRelatedSearchName('Detective Conan', [10, 20]);
    final client = FakeBangumiClient()..results = [root];
    final controller = AnimeMetadataController(client: client, store: store);
    await controller.scan([
      video,
      manualVideo,
      pendingVideo,
      previouslyMatched,
    ]);
    await idle(controller);
    expect(controller.subjectFor(video)?.id, 899);
    expect(client.queries, ['Detective Conan', 'Pending']);
    expect(controller.subjectFor(manualVideo)?.id, frieren.id);
    expect(
      controller.subjectFor(previouslyMatched)?.id,
      frieren.id,
      reason: 'an existing valid match stays available even if a rule update cannot reach the network',
    );
    expect(
      store.entries[animeMediaKey(video)]?.matcherVersion,
      animeMatcherVersion,
    );
    controller.dispose();
  });

  test(
    'release names keep title and episode while stripping group and quality',
    () {
      final parsed = AnimeFilename.parse(
        '[ANi] 葬送的芙莉蓮 - 01 [1080P][Baha][WEB-DL][AAC AVC][CHT].mkv',
      );
      expect(parsed.title, '葬送的芙莉蓮');
      expect(parsed.episode, 1);
      final bracketed = AnimeFilename.parse('[字幕组][葬送的芙莉莲][02][1080p].mp4');
      expect(bracketed.title, '葬送的芙莉莲');
      expect(bracketed.episode, 2);
      final english = AnimeFilename.parse(
        '[SubsPlease] Sousou.no.Frieren.S02E03.1080p.mkv',
      );
      expect(english.title, 'Sousou no Frieren');
      expect(english.season, 2);
      expect(english.episode, 3);
      expect(AnimeFilename.parse('葬送的芙莉莲 (2023) - 04.mp4').year, 2023);
    },
  );

  test('exact aliases match; alternate seasons, years, ambiguity and partial names do not', () {
    expect(
      confidentAnimeMatch(AnimeFilename.parse('Sousou no Frieren - 01.mkv'), [
        seasonTwo,
        frieren,
      ])?.id,
      400602,
    );
    expect(
      confidentAnimeMatch(AnimeFilename.parse('葬送的芙莉莲 S02E03.mkv'), [
        frieren,
        seasonTwo,
      ])?.id,
      515759,
    );
    expect(
      confidentAnimeMatch(AnimeFilename.parse('葬送的芙莉莲 S02E03.mkv'), [frieren]),
      isNull,
    );
    expect(
      confidentAnimeMatch(AnimeFilename.parse('葬送的芙莉莲 (2024) - 01.mkv'), [
        frieren,
      ]),
      isNull,
    );
    expect(
      confidentAnimeMatch(AnimeFilename.parse('葬送的芙莉莲 - 29.mkv'), [frieren]),
      isNull,
    );
    expect(
      confidentAnimeMatch(AnimeFilename.parse('芙莉莲 - 01.mkv'), [frieren]),
      isNull,
    );
    expect(
      confidentAnimeMatch(AnimeFilename.parse('葬送的芙莉莲 - 01.mkv'), [
        frieren,
        frieren,
      ]),
      isNull,
    );
  });

  test('episodes share a query and cached matches survive app container relocation', () async {
    final client = FakeBangumiClient()..results = [frieren];
    final store = MemoryMetadataStore();
    final controller = AnimeMetadataController(client: client, store: store);
    final first = media('葬送的芙莉莲 - 01.mp4');
    final second = media('葬送的芙莉莲 - 02.mp4');
    await controller.scan([first, second]);
    await idle(controller);
    expect(client.queries, ['葬送的芙莉莲']);
    expect(controller.subjectFor(second)?.id, 400602);
    controller.dispose();
    final offline = FakeBangumiClient()..fail = true;
    final reopened = AnimeMetadataController(client: offline, store: store);
    await reopened.scan([media(first.name, container: 'relocated')]);
    await idle(reopened);
    expect(
      reopened.subjectFor(media(first.name, container: 'relocated'))?.id,
      400602,
    );
    expect(offline.queries, isEmpty);
    reopened.dispose();
  });

  test(
    'manual correction and ignore win over an in-flight automatic result',
    () async {
      final client = FakeBangumiClient()
        ..results = [frieren]
        ..gate = Completer<void>();
      final store = MemoryMetadataStore();
      final controller = AnimeMetadataController(client: client, store: store);
      final video = media('葬送的芙莉莲 - 01.mp4');
      await controller.scan([video]);
      await Future<void>.delayed(Duration.zero);
      await controller.select(video, seasonTwo);
      client.gate!.complete();
      await idle(controller);
      expect(controller.subjectFor(video)?.id, seasonTwo.id);
      await controller.select(video, null);
      await controller.scan([video]);
      expect(controller.matchFor(video)?.status, AnimeMatchStatus.ignored);
      expect(client.queries.length, 1);
      controller.dispose();
      final reopened = AnimeMetadataController(
        client: FakeBangumiClient(),
        store: store,
      );
      await reopened.scan([video]);
      expect(reopened.matchFor(video)?.status, AnimeMatchStatus.ignored);
      reopened.dispose();
    },
  );

  test(
    'network failure stays retryable and is not retried on every tab switch',
    () async {
      final client = FakeBangumiClient()..fail = true;
      final controller = AnimeMetadataController(
        client: client,
        store: MemoryMetadataStore(),
      );
      final video = media('葬送的芙莉莲 - 01.mp4');
      await controller.scan([video]);
      await idle(controller);
      expect(controller.matchFor(video)?.status, AnimeMatchStatus.failed);
      await controller.scan([video]);
      await controller.scan([video]);
      expect(client.queries.length, 1);
      client.fail = false;
      client.results = [frieren];
      await controller.retry(video);
      await idle(controller);
      expect(controller.subjectFor(video)?.id, 400602);
      controller.dispose();
    },
  );

  test(
    'automatic toggle persists and does not replace a manual association',
    () async {
      final client = FakeBangumiClient()..results = [frieren];
      final store = MemoryMetadataStore();
      final controller = AnimeMetadataController(client: client, store: store);
      final video = media('葬送的芙莉莲 - 01.mp4');
      await controller.initialize();
      await controller.setAutomatic(false);
      await controller.scan([video]);
      expect(client.queries, isEmpty);
      await controller.select(video, seasonTwo);
      await controller.setAutomatic(true);
      await idle(controller);
      expect(controller.subjectFor(video)?.id, 515759);
      expect(client.queries, isEmpty);
      controller.dispose();
      final reopened = AnimeMetadataController(
        client: FakeBangumiClient(),
        store: store,
      );
      await reopened.initialize();
      expect(reopened.automatic, isTrue);
      expect(reopened.subjectFor(video)?.id, 515759);
      reopened.dispose();
    },
  );

  test(
    'file cache retains independent records after serialized writes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'orvex-metadata-',
      );
      try {
        final store = MetadataStore(directoryProvider: () async => directory);
        final entry = AnimeMatch(
          query: '葬送的芙莉莲',
          status: AnimeMatchStatus.matched,
          updatedAt: DateTime.now(),
          subject: frieren,
          candidates: [frieren],
          manual: true,
        );
        await Future.wait([
          store.write(true, {'a': entry}),
          store.write(false, {'a': entry, 'b': entry}),
        ]);
        final restored = await MetadataStore(
          directoryProvider: () async => directory,
        ).read();
        expect(restored.automatic, isFalse);
        expect(restored.entries.length, 2);
        expect(
          restored.entries['a']?.subject?.aliases,
          contains('Sousou no Frieren'),
        );
        expect(
          await File('${directory.path}/bangumi-metadata-v1.json.part')
              .exists(),
          isFalse,
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
  test(
    'cover bytes persist per subject and a restarted library needs no network',
    () async {
      final directory = await Directory.systemTemp.createTemp('orvex-poster-');
      final store = MetadataStore(directoryProvider: () async => directory);
      final client = FakeBangumiClient()
        ..results = [
          const AnimeSubject(
            id: 400602,
            name: '葬送のフリーレン',
            nameCn: '葬送的芙莉莲',
            episodes: 28,
            posterUrl: 'https://lain.bgm.tv/cover.jpg',
          ),
        ];
      final controller = AnimeMetadataController(client: client, store: store);
      final video = media('葬送的芙莉莲 - 01.mp4');
      try {
        await controller.scan([video, media('葬送的芙莉莲 - 02.mp4')]);
        await idle(controller);
        expect(client.posterRequests, 1);
        expect(
          await File(controller.posterPath(400602)!).readAsBytes(),
          client.posterBytes,
        );
        controller.dispose();
        final offline = FakeBangumiClient()..fail = true;
        final reopened = AnimeMetadataController(client: offline, store: store);
        await reopened.scan([video]);
        expect(reopened.subjectFor(video)?.id, 400602);
        expect(reopened.posterPath(400602), isNotNull);
        expect(offline.posterRequests, 0);
        expect(offline.queries, isEmpty);
        reopened.dispose();
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
