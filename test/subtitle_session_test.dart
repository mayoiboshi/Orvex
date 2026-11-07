import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:orvex/design/orvex_theme.dart';
import 'package:orvex/features/player/presentation/playback_surface.dart';
import 'package:orvex/features/player/application/playback_session.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:orvex/features/subtitles/domain/subtitle_models.dart';

import 'support/fakes.dart';

final _one = LocalMedia(
  uri: Uri(scheme: 'file', path: '/one.mp4'),
  name: 'Show - 01.mp4',
);
final _two = LocalMedia(
  uri: Uri(scheme: 'file', path: '/two.mp4'),
  name: 'Show - 02.mp4',
);
const _a = SubtitleReference(
  kind: 'import',
  path: 'Imports/a/same.ass',
  name: 'same.ass',
);
const _b = SubtitleReference(
  kind: 'import',
  path: 'Imports/b/same.ass',
  name: 'same.ass',
);

class _Subtitles extends SubtitleSupport {
  final choices = <String, SubtitleChoice>{};
  final scans = <String, Completer<List<SubtitleCandidate>>>{};
  final matches = <String, List<SubtitleCandidate>>{};
  final events = <String>[];
  Completer<PreparedSubtitle>? preparing;
  bool automatic = true, failPrepare = false, failRemember = false;
  int discoveries = 0;
  @override
  Future<SubtitleChoice> readChoice(LocalMedia video) async =>
      choices[video.resumeKey] ?? const SubtitleChoice.automatic();
  @override
  Future<void> remember(LocalMedia video, SubtitleChoice choice) async {
    if (failRemember) throw StateError('cannot write');
    choices[video.resumeKey] = choice;
  }

  @override
  Future<bool> automaticMatching() async => automatic;
  @override
  Future<void> setAutomaticMatching(bool value) async {
    automatic = value;
  }

  @override
  Future<List<SubtitleCandidate>> discover(LocalMedia video) async {
    discoveries++;
    return scans[video.resumeKey]?.future ?? matches[video.resumeKey] ?? [];
  }

  PreparedSubtitle prepared(SubtitleReference reference) => PreparedSubtitle(
    LocalMedia(uri: Uri.file('/${reference.path}'), name: reference.name),
    () async => events.add('release:${reference.path}'),
  );
  @override
  Future<PreparedSubtitle> prepare(SubtitleReference reference) async {
    if (failPrepare) throw StateError('missing subtitle');
    return preparing?.future ?? prepared(reference);
  }
}

class _SubtitleEngine extends FakeEngine {
  _SubtitleEngine(this.events, {this.embedded = const []});
  final List<String> events;
  final List<MediaTrack> embedded;
  final loaded = <Uri>[];
  final selected = <String>[];
  final tracks = <MediaTrack>[];
  final ids = <Uri, String>{};
  String current = 'auto';
  void emit() => frameController.add(
    PlaybackFrame(
      duration: const Duration(minutes: 20),
      position: const Duration(seconds: 30),
      playing: true,
      subtitleTracks: List.unmodifiable(tracks),
      subtitleTrackId: current,
    ),
  );
  @override
  Future<void> open(LocalMedia media, {required Duration start}) async {
    await super.open(media, start: start);
    tracks.addAll(embedded);
    emit();
  }

  @override
  Future<void> loadSubtitle(Uri uri, String name) async {
    if (failSubtitle) throw StateError('bad subtitle');
    loaded.add(uri);
    final id = ids.putIfAbsent(uri, () {
      final id = 's${ids.length + 1}';
      tracks.add(MediaTrack(id, name));
      return id;
    });
    current = id;
    emit();
  }

  @override
  Future<void> selectSubtitle(String id) async {
    selected.add(id);
    current = id;
    emit();
  }

  @override
  Future<void> dispose() async {
    events.add('engine-dispose');
    await super.dispose();
  }
}

void main() {
  late _Subtitles support;
  late List<_SubtitleEngine> engines;
  late List<PlaybackSession> sessions;
  setUp(() {
    support = _Subtitles();
    engines = [];
    sessions = [];
  });
  PlaybackSession create({List<MediaTrack> embedded = const []}) {
    final session = PlaybackSession(
      createEngine: () {
        final engine = _SubtitleEngine(support.events, embedded: embedded);
        engines.add(engine);
        return engine;
      },
      resumeStore: MemoryResumeStore(),
      subtitleSupport: support,
      prepare: (media) async => PreparedPlayback(
        media,
        () async => support.events.add('video-release'),
      ),
    );
    sessions.add(session);
    return session;
  }

  tearDown(() async {
    for (final session in sessions) {
      await session.shutdown();
      session.dispose();
    }
    for (final engine in engines) {
      await engine.cleanUp();
    }
  });
  test('unique automatic match loads without converting it into a manual preference', () async {
    support.matches[_one.resumeKey] = [
      const SubtitleCandidate(_a, SubtitleMatch.episode),
    ];
    final session = create();
    await session.open(_one);
    await session.subtitlesReady;
    expect(engines.single.loaded.single.path, '/${_a.path}');
    expect(session.selectedLocalSubtitle, _a.key);
    expect(support.choices, isEmpty);
    expect(session.subtitleStatus, contains('集数匹配'));
  });
  test(
    'multiple best candidates are displayed without automatic selection',
    () async {
      support.matches[_one.resumeKey] = [
        const SubtitleCandidate(_a, SubtitleMatch.exact),
        const SubtitleCandidate(_b, SubtitleMatch.exact),
      ];
      final session = create();
      await session.open(_one);
      await session.subtitlesReady;
      expect(engines.single.loaded, isEmpty);
      expect(session.localSubtitles.length, 2);
      expect(session.subtitleStatus, contains('多个'));
      await session.chooseLocalSubtitle(_b);
      expect(support.choices[_one.resumeKey]!.reference!.key, _b.key);
    },
  );
  test('manual external choice survives new sessions and different same-name files stay distinct', () async {
    final session = create();
    await session.open(_one);
    await session.subtitlesReady;
    await session.chooseLocalSubtitle(_a);
    await session.chooseLocalSubtitle(_b);
    expect(engines.single.loaded.length, 2);
    await session.selectSubtitle('s1');
    expect(support.choices[_one.resumeKey]!.reference!.key, _a.key);
    await session.close();
    final restored = create();
    await restored.open(_one);
    await restored.subtitlesReady;
    expect(engines.last.loaded.single.path, '/${_a.path}');
    expect(restored.subtitleStatus, contains('已恢复'));
    expect(support.choices[_two.resumeKey], isNull);
  });
  test('explicit off is restored ahead of matching files and automatic can be restored explicitly', () async {
    support.choices[_one.resumeKey] = const SubtitleChoice.off();
    support.matches[_one.resumeKey] = [
      const SubtitleCandidate(_a, SubtitleMatch.exact),
    ];
    final session = create();
    await session.open(_one);
    await session.subtitlesReady;
    expect(engines.single.selected, ['no']);
    expect(engines.single.loaded, isEmpty);
    expect(support.discoveries, 0);
    await session.selectSubtitle('auto');
    await session.subtitlesReady;
    expect(engines.single.loaded.single.path, '/${_a.path}');
    expect(support.choices[_one.resumeKey]!.mode, SubtitleChoiceMode.automatic);
  });
  test(
    'remembered embedded tracks take priority over local auto matching',
    () async {
      support.choices[_one.resumeKey] = const SubtitleChoice.embedded(
        MediaTrack('1', '日本語'),
      );
      support.matches[_one.resumeKey] = [
        const SubtitleCandidate(_a, SubtitleMatch.exact),
      ];
      final session = create(embedded: const [MediaTrack('1', '日本語')]);
      await session.open(_one);
      await session.subtitlesReady;
      expect(engines.single.selected, ['1']);
      expect(engines.single.loaded, isEmpty);
    },
  );
  test('disabling smart matching still permits manual choice and remembered reload', () async {
    support.automatic = false;
    final session = create();
    await session.open(_one);
    await session.subtitlesReady;
    expect(support.discoveries, 0);
    await session.chooseLocalSubtitle(_a);
    await session.close();
    await session.open(_one);
    await session.subtitlesReady;
    expect(engines.last.loaded.single.path, '/${_a.path}');
  });
  test(
    'late scan from an old video cannot affect the new video or its candidates',
    () async {
      final gate = Completer<List<SubtitleCandidate>>();
      support.scans[_one.resumeKey] = gate;
      support.matches[_two.resumeKey] = [
        const SubtitleCandidate(_b, SubtitleMatch.episode),
      ];
      final session = create();
      await session.open(_one);
      await Future<void>.delayed(Duration.zero);
      final old = session.subtitlesReady;
      await session.open(_two);
      await session.subtitlesReady;
      gate.complete([const SubtitleCandidate(_a, SubtitleMatch.exact)]);
      await old;
      expect(engines.first.loaded, isEmpty);
      expect(engines.last.loaded.single.path, '/${_b.path}');
      expect(session.localSubtitles.single.reference.key, _b.key);
    },
  );
  test('manual off cancels an in-flight automatic discovery', () async {
    final gate = Completer<List<SubtitleCandidate>>();
    support.scans[_one.resumeKey] = gate;
    final session = create();
    await session.open(_one);
    await Future<void>.delayed(Duration.zero);
    await session.selectSubtitle('no');
    gate.complete([const SubtitleCandidate(_a, SubtitleMatch.exact)]);
    await session.subtitlesReady;
    expect(engines.single.loaded, isEmpty);
    expect(session.subtitleChoice.mode, SubtitleChoiceMode.off);
    expect(session.subtitleBusy, isFalse);
  });
  test(
    'stale prepared leases are released instead of attaching to another video',
    () async {
      support.automatic = false;
      final gate = Completer<PreparedSubtitle>();
      support.preparing = gate;
      final session = create();
      await session.open(_one);
      await session.subtitlesReady;
      final picking = session.chooseLocalSubtitle(_a);
      await session.open(_two);
      await session.subtitlesReady;
      gate.complete(support.prepared(_a));
      await picking;
      expect(engines.last.loaded, isEmpty);
      expect(support.events, contains('release:${_a.path}'));
    },
  );
  test('missing remembered files retain the preference but do not select another subtitle', () async {
    support.choices[_one.resumeKey] = const SubtitleChoice.external(_a);
    support.failPrepare = true;
    final session = create();
    await session.open(_one);
    await session.subtitlesReady;
    expect(session.ready, isTrue);
    expect(session.error, isNull);
    expect(session.subtitleIssue, contains('加载'));
    expect(engines.single.selected.last, 'no');
    expect(support.choices[_one.resumeKey]!.reference!.key, _a.key);
  });
  test(
    'failed manual load never overwrites the last successful preference',
    () async {
      final session = create();
      await session.open(_one);
      await session.subtitlesReady;
      await session.chooseLocalSubtitle(_a);
      engines.single.failSubtitle = true;
      await session.chooseLocalSubtitle(_b);
      expect(support.choices[_one.resumeKey]!.reference!.key, _a.key);
      expect(session.subtitleIssue, contains('加载'));
      expect(session.ready, isTrue);
    },
  );
  test('write failures report unsaved memory while current subtitles remain usable', () async {
    final session = create();
    await session.open(_one);
    await session.subtitlesReady;
    support.failRemember = true;
    await session.chooseLocalSubtitle(_a);
    expect(engines.single.loaded.length, 1);
    expect(session.subtitleIssue, contains('保存'));
  });
  test(
    'failed saving of automatic mode remains visible after a successful match',
    () async {
      support.choices[_one.resumeKey] = const SubtitleChoice.off();
      support.matches[_one.resumeKey] = [
        const SubtitleCandidate(_a, SubtitleMatch.exact),
      ];
      final session = create();
      await session.open(_one);
      await session.subtitlesReady;
      support.failRemember = true;
      await session.selectSubtitle('auto');
      await session.subtitlesReady;
      expect(engines.single.loaded.single.path, '/${_a.path}');
      expect(session.subtitleIssue, contains('保存'));
      expect(support.choices[_one.resumeKey]!.mode, SubtitleChoiceMode.off);
    },
  );
  test('an unavailable remembered embedded track is reported without falling back to another', () async {
    support.choices[_one.resumeKey] = const SubtitleChoice.embedded(
      MediaTrack('9', 'Missing'),
    );
    final session = create(embedded: const [MediaTrack('1', '日本語')]);
    await session.open(_one);
    await session.subtitlesReady;
    expect(engines.single.selected.last, 'no');
    expect(session.subtitleIssue, contains('不可用'));
    expect(session.ready, isTrue);
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'subtitle settings allow choosing, disabling and resetting on small screens $brightness',
      (tester) async {
        const a = SubtitleReference(
          kind: 'import',
          path: 'Imports/a/Show - 01.chs.srt',
          name: 'Show - 01.chs.srt',
        );
        const b = SubtitleReference(
          kind: 'import',
          path: 'Imports/b/Show - 01.cht.srt',
          name: 'Show - 01.cht.srt',
        );
        support.matches[_one.resumeKey] = [
          const SubtitleCandidate(a, SubtitleMatch.languageName),
          const SubtitleCandidate(b, SubtitleMatch.languageName),
        ];
        final session = create();
        var cleaned = false;
        Future<void> cleanWidgetSession() async {
          if (cleaned) return;
          cleaned = true;
          sessions.remove(session);
          final owned = List<_SubtitleEngine>.of(engines);
          engines.clear();
          await tester.pumpWidget(const SizedBox.shrink());
          var closed = false;
          final closing = session.shutdown().then((_) => closed = true);
          // Let widget frames and real stream-cancellation callbacks both finish.
          for (var turn = 0; turn < 30 && !closed; turn++) {
            await tester.pump(const Duration(milliseconds: 100));
            await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          }
          expect(
            closed,
            isTrue,
            reason: 'Subtitle work must not block disposal',
          );
          await closing;
          session.dispose();
          for (final engine in owned) {
            await engine.cleanUp();
          }
        }

        addTearDown(cleanWidgetSession);
        await session.open(_one);
        await session.subtitlesReady;
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: OrvexTheme.create(brightness),
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 360,
                  height: 220,
                  child: PlaybackSurface(
                    session: session,
                    fullscreen: false,
                    onFullscreen: () {},
                    onSubtitle: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('播放设置'));
        await tester.pumpAndSettle();
        final candidate = find.text(b.name);
        await tester.ensureVisible(candidate);
        await tester.pumpAndSettle();
        await tester.tap(candidate);
        await tester.pumpAndSettle();
        expect(session.subtitleChoice.reference!.key, b.key);
        expect(session.selectedLocalSubtitle, b.key);
        final toggle = find.widgetWithText(SwitchListTile, '智能匹配本地字幕');
        await tester.ensureVisible(toggle);
        await tester.pumpAndSettle();
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(support.automatic, isFalse);
        expect(session.subtitleChoice.reference!.key, b.key);
        final reset = find.text('清除本集记忆，恢复自动选择');
        await tester.ensureVisible(reset);
        await tester.pumpAndSettle();
        await tester.tap(reset);
        await tester.pumpAndSettle();
        expect(session.subtitleChoice.mode, SubtitleChoiceMode.automatic);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await cleanWidgetSession();
      },
    );
  }

  test('all subtitle leases outlive their engine and release before the video scope', () async {
    final session = create();
    await session.open(_one);
    await session.subtitlesReady;
    await session.chooseLocalSubtitle(_a);
    await session.chooseLocalSubtitle(_b);
    await session.close();
    expect(support.events, [
      'engine-dispose',
      'release:${_a.path}',
      'release:${_b.path}',
      'video-release',
    ]);
  });
}
