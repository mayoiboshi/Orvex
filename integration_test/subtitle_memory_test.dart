import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:orvex/design/orvex_theme.dart';
import 'package:orvex/features/folder_library/folder_access.dart';
import 'package:orvex/features/folder_library/folder_library.dart';
import 'package:orvex/features/folder_library/folder_models.dart';
import 'package:orvex/features/media_sources/imported_file_store.dart';
import 'package:orvex/features/player/application/playback_session.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:orvex/features/player/infrastructure/media_kit_engine.dart';
import 'package:orvex/features/player/presentation/playback_surface.dart';
import 'package:orvex/features/subtitles/domain/subtitle_models.dart';
import 'package:orvex/features/subtitles/infrastructure/local_subtitles.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Resume implements ResumeStore {
  final values = <String, Duration>{};
  @override
  Future<Duration> read(String key) async => values[key] ?? Duration.zero;
  @override
  Future<void> write(String key, Duration position) async {
    values[key] = position;
  }
}

class _Access extends FolderAccess {
  int live = 0;
  @override
  Future<FolderLease> acquire(FolderRoot root) async {
    final lease = await super.acquire(root);
    live++;
    return FolderLease(lease.handle, lease.location, () async {
      await lease.release();
      live--;
    });
  }
}

String _srt(String marker) => '1\n00:00:00,000 --> 00:00:18,000\n$marker\n';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  const phase = String.fromEnvironment(
    'ORVEX_SUBTITLE_TEST_PHASE',
    defaultValue: 'remember',
  );
  testWidgets('native local subtitle memory and matching: $phase', (
    tester,
  ) async {
    expect(Platform.isIOS, isTrue);
    expect(
      await const MethodChannel('dev.orvex/audio-session')
          .invokeMethod<bool>('isSimulator'),
      isTrue,
      reason: 'Generated fixture experiments are restricted to simulators',
    );
    MediaKit.ensureInitialized();
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    final documents = await getApplicationDocumentsDirectory();
    final descriptor = File('${documents.path}/orvex-subtitle-test-v1.json');
    final prefs = SharedPreferencesAsync();
    late Directory run;
    late Map<String, dynamic> metadata;
    if (phase == 'remember') {
      final base = await Directory('${documents.path}/OrvexSubtitleEvidence')
          .create();
      run = await base.createTemp('run-');
      metadata = {
        'run': run.uri.pathSegments.where((s) => s.isNotEmpty).last,
        'originalAutomatic': await prefs.getBool(LocalSubtitles.automaticKey),
        'firstDocuments': documents.path,
      };
    } else {
      metadata =
          jsonDecode(await descriptor.readAsString()) as Map<String, dynamic>;
      final name = metadata['run'] as String;
      expect(RegExp(r'^run-[a-zA-Z0-9_-]+$').hasMatch(name), isTrue);
      run = Directory('${documents.path}/OrvexSubtitleEvidence/$name');
    }
    final name = metadata['run'] as String;
    final store = ImportedFileStore(
      directoryProvider: () async => Directory('${run.path}/documents'),
    );
    if (phase == 'remember') {
      final video = await rootBundle.load('test/fixtures/generated.mp4');
      for (final episode in ['01', '02']) {
        // Explicit legacy independent-copy fixture, not a change to import deduplication.
        final file = File(
          '${run.path}/documents/Imports/$name/Orvex 字幕验证 - $episode.mp4',
        );
        await file.parent.create(recursive: true);
        await file.writeAsBytes(video.buffer.asUint8List());
      }
      final auto = await File(
        '${run.path}/Orvex 字幕验证 - 01.ass',
      ).writeAsString(await rootBundle.loadString('test/fixtures/sample.ass'));
      final manual = await File('${run.path}/手动字幕 - 01.srt')
          .writeAsString(_srt('ORVEX MEMORY RESTORE'));
      final autoMedia = await store.import(XFile(auto.path));
      final manualMedia = await store.import(XFile(manual.path));
      metadata['auto'] = SubtitleReference.imported(autoMedia).toJson();
      metadata['manual'] = SubtitleReference.imported(manualMedia).toJson();
      await descriptor.writeAsString(jsonEncode(metadata));
    }
    final video = (await store.listVideos()).singleWhere(
      (m) => m.name.endsWith('01.mp4'),
    );
    final manual = SubtitleReference.fromJson(
      Map<String, dynamic>.from(metadata['manual'] as Map),
    );
    final access = _Access();
    final folders = FolderLibrary(
      access: access,
      directory: () async => Directory('${run.path}/index'),
    );
    await folders.initialize();
    final support = LocalSubtitles(
      folders: folders,
      imports: store,
      preferences: prefs,
    );
    await support.setAutomaticMatching(true);
    final session = PlaybackSession(
      createEngine: () => MediaKitEngine(silentAudioForTesting: true),
      resumeStore: _Resume(),
      subtitleSupport: support,
      prepare: (m) async {
        if (m.folderRoot != null) {
          final resolved = await folders.prepare(m);
          return PreparedPlayback(resolved.media, resolved.release);
        }
        return PreparedPlayback(await store.resolve(m));
      },
    );
    final screen = GlobalKey();
    final observations = <String, Object?>{'phase': phase};
    Future<void> until(bool Function() ready, String reason) async {
      final deadline = DateTime.now().add(const Duration(seconds: 25));
      while (!ready() && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        ready(),
        isTrue,
        reason:
            '$reason; ${session.error}; ${session.subtitleIssue}; ${session.subtitleScanIssue}',
      );
    }

    Future<void> mount(Brightness brightness) async {
      await tester.pumpWidget(
        RepaintBoundary(
          key: screen,
          child: MaterialApp(
            theme: OrvexTheme.create(brightness),
            home: Scaffold(
              body: SafeArea(
                child: Column(
                  children: [
                    const Text('模拟器字幕验证 · 无声', style: TextStyle(fontSize: 11)),
                    Expanded(
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: 16 / 9,
                          child: PlaybackSurface(
                            session: session,
                            fullscreen: false,
                            onFullscreen: () {},
                            onSubtitle: () {},
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      // Native video textures may keep scheduling frames while paused.
      // Wait for the finite UI transition, not global frame quiescence.
      await tester.pump(const Duration(milliseconds: 450));
    }

    Future<void> open(LocalMedia media) async {
      final opening = session.open(media);
      await until(
        () => session.ready && session.frame.duration.inSeconds > 10,
        'native video is ready',
      );
      await opening;
      await until(() => !session.subtitleBusy, 'subtitle restoration finished');
      await session.subtitlesReady;
      await session.seek(const Duration(seconds: 4));
      await session.pauseForInterruption();
      await until(
        () => session.frame.position.inSeconds >= 3 && !session.frame.playing,
        'native frame is paused at the subtitle cue',
      );
    }

    Future<void> capture(String label) async {
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      final boundary =
          screen.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('${run.path}/$phase-$label.png')
          .writeAsBytes(png!.buffer.asUint8List());
      image.dispose();
    }

    Future<int> subtitlePixelDifference() async {
      final engine = session.engine! as MediaKitEngine;
      await tester.pump(const Duration(milliseconds: 350));
      final withSub = (await engine.captureFrame())!;
      await session.selectSubtitle('no');
      await until(
        () => session.frame.subtitleTrackId == 'no',
        'subtitle off reached the native engine',
      );
      await tester.pump(const Duration(milliseconds: 350));
      final withoutSub = (await engine.captureFrame())!;
      final c1 = await ui.instantiateImageCodec(withSub),
          c2 = await ui.instantiateImageCodec(withoutSub);
      final a = (await c1.getNextFrame()).image,
          b = (await c2.getNextFrame()).image;
      final av = (await a.toByteData(format: ui.ImageByteFormat.rawRgba))!,
          bv = (await b.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      var changed = 0;
      for (var y = a.height * 2 ~/ 3; y < a.height; y++) {
        for (var x = 0; x < a.width; x++) {
          final offset = (y * a.width + x) * 4;
          if ((av.getUint8(offset) - bv.getUint8(offset)).abs() +
                  (av.getUint8(offset + 1) - bv.getUint8(offset + 1)).abs() +
                  (av.getUint8(offset + 2) - bv.getUint8(offset + 2)).abs() >
              60) {
            changed++;
          }
        }
      }
      a.dispose();
      b.dispose();
      c1.dispose();
      c2.dispose();
      expect(
        changed,
        greaterThan(30),
        reason: 'A real libass subtitle must alter the paused native frame',
      );
      return changed;
    }

    var passed = false;
    try {
      await mount(Brightness.dark);
      await open(video);
      if (phase == 'remember') {
        expect(session.subtitleStatus, contains('完整名称匹配'));
        await tester.tap(find.byTooltip('播放设置'));
        await tester.pump(const Duration(milliseconds: 450));
        final candidate = find.text(manual.name);
        await tester.ensureVisible(candidate);
        await tester.pump(const Duration(milliseconds: 450));
        await tester.tap(candidate);
        await until(
          () =>
              !session.subtitleBusy &&
              session.subtitleChoice.mode == SubtitleChoiceMode.external,
          'manual candidate selected',
        );
        expect(session.subtitleChoice.reference!.key, manual.key);
        await capture('manual-settings-dark');
        Navigator.of(
          tester.element(find.text('播放设置')),
          rootNavigator: true,
        ).pop();
        await tester.pump(const Duration(milliseconds: 450));
        observations['manualSrtPixels'] = await subtitlePixelDifference();
        await session.loadSubtitle((await support.prepare(manual)).media);
        expect((await support.readChoice(video)).reference!.key, manual.key);
        final raw = await prefs.getString(
          'orvex.subtitles.choice.v1.${video.resumeKey}',
        );
        expect(raw, isNot(contains(documents.path)));
        await capture('manual-video-dark');
        final description = File(
          '${documents.path}/orvex-folder-native-test.json',
        );
        final root = FolderRoot.fromJson(
          jsonDecode(await description.readAsString()) as Map<String, dynamic>,
        );
        final lease = await access.acquire(root);
        try {
          expect(lease.location, contains('OrvexFolderTestFixture'));
          final parent = Directory.fromUri(
            Uri.parse(lease.location).resolve('TV/0001-0123/'),
          );
          await File('${parent.path}/第1集.srt')
              .writeAsString(_srt('ORVEX FOLDER EXACT'));
          await File('${parent.path}/另一名称 - 002.srt')
              .writeAsString(_srt('ORVEX EPISODE MATCH'));
          await File('${parent.path}/10集 数字集号解析验证.srt')
              .writeAsString(_srt('ORVEX BARE EPISODE MATCH'));
        } finally {
          await lease.release();
        }
        folders.roots.clear();
        folders.entries.clear();
        folders.roots.add(root);
        await folders.scan(root);
        final first = folders.entries
            .singleWhere((e) => e.path == 'TV/0001-0123/第1集.mp4')
            .media;
        final second = folders.entries
            .singleWhere((e) => e.path == 'TV/0001-0123/第2集.mp4')
            .media;
        await open(first);
        expect(session.subtitleStatus, contains('完整名称匹配'));
        expect(session.selectedLocalSubtitle, contains('第1集.srt'));
        observations['sameFolderSrtPixels'] = await subtitlePixelDifference();
        await open(second);
        expect(session.subtitleStatus, contains('集数匹配'));
        expect(session.selectedLocalSubtitle, contains('另一名称 - 002.srt'));
        expect(access.live, greaterThanOrEqualTo(2));
        await mount(Brightness.light);
        await capture('folder-episode-light');
        final tenth = folders.entries
            .singleWhere((e) => e.path == 'TV/0001-0123/第10集.mp4')
            .media;
        await open(tenth);
        expect(session.subtitleStatus, contains('集数匹配'));
        expect(session.selectedLocalSubtitle, contains('10集 数字集号解析验证.srt'));
        observations['bareEpisodeHeadingPixels'] =
            await subtitlePixelDifference();
        await session.selectSubtitle('auto');
        await until(() => !session.subtitleBusy, 'bare heading rematched');
        await session.subtitlesReady;
        await capture('bare-episode-heading-light');
        await session.close();
        expect(access.live, 0);
        observations['nativeFolderLeasesReleased'] = true;
        metadata['videoKey'] = video.resumeKey;
        await descriptor.writeAsString(jsonEncode(metadata));
      } else {
        expect(session.subtitleStatus, contains('已恢复'));
        expect(session.subtitleChoice.reference!.key, manual.key);
        expect(session.selectedLocalSubtitle, manual.key);
        observations['newDocumentsContainer'] =
            metadata['firstDocuments'] != documents.path;
        observations['restoredSrtPixels'] = await subtitlePixelDifference();
        await session.close();
        await open(video);
        expect(session.subtitleChoice.mode, SubtitleChoiceMode.off);
        expect(session.frame.subtitleTrackId, 'no');
        expect(session.selectedLocalSubtitle, isNull);
        await capture('remembered-off-dark');
        await mount(Brightness.light);
        await tester.tap(find.byTooltip('播放设置'));
        await tester.pump(const Duration(milliseconds: 450));
        await capture('remembered-off-settings-light');
        observations['offChoiceRestored'] = true;
      }
      expect(session.error, isNull);
      passed = true;
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await session.shutdown();
      session.dispose();
      folders.dispose();
      expect(access.live, 0);
      if (phase == 'restore' || !passed) {
        final original = metadata['originalAutomatic'];
        if (original == null) {
          await prefs.remove(LocalSubtitles.automaticKey);
        } else {
          await prefs.setBool(LocalSubtitles.automaticKey, original as bool);
        }
      }
      observations['passed'] = passed;
      await File(
        '${run.path}/$phase-results.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(observations));
      debugPrint('ORVEX_SUBTITLE_EVIDENCE=${run.path}');
      await SystemChrome.setPreferredOrientations([]);
    }
  });
}
