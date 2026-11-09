import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/features/anime_metadata/infrastructure/bangumi_client.dart';

void main() {
  test(
    'server failure and authorization carry distinct fallback policy',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = BangumiClient(
        baseUrl: 'http://127.0.0.1:${server.port}',
        minimumInterval: Duration.zero,
      );
      var status = 503;
      final subscription = server.listen((request) async {
        await request.drain<void>();
        request.response.statusCode = status;
        await request.response.close();
      });
      try {
        await expectLater(
          client.search('Example'),
          throwsA(
            isA<BangumiException>().having(
              (error) => error.kind,
              'kind',
              BangumiFailure.unavailable,
            ),
          ),
        );
        status = 403;
        await expectLater(
          client.search('Example'),
          throwsA(
            isA<BangumiException>()
                .having(
                  (error) => error.kind,
                  'kind',
                  BangumiFailure.authorization,
                )
                .having((error) => error.message, 'message', contains('403')),
          ),
        );
      } finally {
        client.close();
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test(
    'episode catalog follows pagination and validates subject and type',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = BangumiClient(
        baseUrl: 'http://127.0.0.1:${server.port}',
        minimumInterval: Duration.zero,
      );
      final offsets = <String?>[];
      final subscription = server.listen((request) async {
        final query = request.uri.queryParameters;
        offsets.add(query['offset']);
        expect(request.uri.path, '/v0/episodes');
        expect(query['subject_id'], '899');
        expect(query['type'], '0');
        request.response.write(
          jsonEncode({
            'total': 3,
            'data': query['offset'] == '0'
                ? [
                    {'id': 1, 'subject_id': 899, 'type': 0, 'sort': 652},
                    {'id': 2, 'subject_id': 899, 'type': 1, 'sort': 653},
                  ]
                : [
                    {
                      'id': 150925,
                      'subject_id': 899,
                      'type': 0,
                      'sort': 653,
                      'ep': 653,
                      'name_cn': '毒与幻的设计（S）',
                      'desc': '',
                    },
                  ],
          }),
        );
        await request.response.close();
      });
      try {
        final episodes = await client.episodes(899);
        expect(offsets, ['0', '2']);
        expect(episodes.map((episode) => episode.id), [1, 150925]);
        expect(episodes.last.matches(653), isTrue);
        expect(episodes.last.title, '毒与幻的设计（S）');
        expect(episodes.last.description, isEmpty);
      } finally {
        client.close();
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );

  for (final ambiguous in [false, true]) {
    test(
      'franchise fallback requires two independent main-story links (ambiguous=$ambiguous)',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final client = BangumiClient(
          baseUrl: 'http://127.0.0.1:${server.port}',
          minimumInterval: Duration.zero,
        );
        final calls = <String>[];
        final subscription = server.listen((request) async {
          calls.add(request.uri.path);
          await request.drain<void>();
          request.response.headers.contentType = ContentType.json;
          Object response;
          if (request.uri.path == '/v0/search/subjects') {
            response = {
              'data': [
                for (final id in [10, 20])
                  {
                    'id': id,
                    'type': 2,
                    'platform': '剧场版',
                    'eps': 1,
                    'name': '作品 映画$id',
                    'name_cn': '作品 剧场版$id',
                    'aliases': ['Example Series: Film $id'],
                  },
              ],
            };
          } else if (request.uri.path.endsWith('/subjects')) {
            response = [
              {'id': 30, 'type': 2, 'relation': '主线故事'},
              if (ambiguous) {'id': 40, 'type': 2, 'relation': '主线故事'},
              {'id': 50, 'type': 3, 'relation': '原声集'},
            ];
          } else {
            response = {
              'id': 30,
              'type': 2,
              'platform': 'TV',
              'eps': 0,
              'name': '作品',
              'name_cn': '示例番剧',
            };
          }
          request.response.write(jsonEncode(response));
          await request.response.close();
        });
        try {
          final results = await client.search('Example Series');
          if (ambiguous) {
            expect(results.length, 2);
            expect(results.every((s) => s.relatedSearchNames.isEmpty), isTrue);
            expect(calls, isNot(contains('/v0/subjects/30')));
          } else {
            expect(results.first.id, 30);
            expect(results.first.platform, 'TV');
            expect(results.first.relatedSourceIds.toSet(), {10, 20});
            expect(results.first.relatedSearchNames, ['Example Series']);
            expect(results.first.aliases, isEmpty);
          }
          expect(
            calls
                .where(
                  (path) =>
                      path.endsWith('/subjects') &&
                      path.startsWith('/v0/subjects/'),
                )
                .length,
            2,
          );
        } finally {
          client.close();
          await subscription.cancel();
          await server.close(force: true);
        }
      },
    );
  }

  test('public search sends anime filter, versioned agent and only the cleaned query', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = BangumiClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
      minimumInterval: Duration.zero,
    );
    final request = server.first.then((request) async {
      expect(request.uri.path, '/v0/search/subjects');
      expect(request.method, 'POST');
      expect(request.headers.value('user-agent'), BangumiClient.userAgent);
      expect(request.headers.value('authorization'), isNull);
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      expect(body, {
        'keyword': '葬送的芙莉莲',
        'sort': 'match',
        'filter': {
          'type': [2],
        },
      });
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'data': [
            {
              'id': 400602,
              'type': 2,
              'name': '葬送のフリーレン',
              'name_cn': '葬送的芙莉莲',
              'date': null,
              'rating': {'score': 8.5},
              'images': {'common': 'https://lain.bgm.tv/cover.jpg'},
              'infobox': [
                {
                  'key': '别名',
                  'value': [
                    {'v': 'Sousou no Frieren'},
                  ],
                },
              ],
            },
          ],
        }),
      );
      await request.response.close();
    });
    try {
      final result = await client.search('葬送的芙莉莲');
      expect(result.single.aliases, contains('Sousou no Frieren'));
      expect(result.single.score, 8.5);
      expect(result.single.date, isEmpty);
      await request;
    } finally {
      client.close();
      await server.close(force: true);
    }
  });

  test('rate limit cooldown prevents repeated HTTP calls', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = BangumiClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
      minimumInterval: Duration.zero,
    );
    var calls = 0;
    final subscription = server.listen((request) async {
      calls++;
      await request.drain<void>();
      request.response.statusCode = 429;
      request.response.headers.set('retry-after', '60');
      await request.response.close();
    });
    try {
      await expectLater(
        client.search('葬送的芙莉莲'),
        throwsA(isA<BangumiException>()),
      );
      await expectLater(
        client.search('另一部番剧'),
        throwsA(isA<BangumiException>()),
      );
      expect(calls, 1);
    } finally {
      client.close();
      await subscription.cancel();
      await server.close(force: true);
    }
  });
}
