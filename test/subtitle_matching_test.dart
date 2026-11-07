import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/features/folder_library/folder_access.dart';
import 'package:orvex/features/folder_library/folder_library.dart';
import 'package:orvex/features/folder_library/folder_models.dart';
import 'package:orvex/features/media_sources/imported_file_store.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:orvex/features/subtitles/domain/subtitle_models.dart';
import 'package:orvex/features/subtitles/domain/subtitle_matcher.dart';
import 'package:orvex/features/subtitles/infrastructure/local_subtitles.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _FileAccess extends FolderAccess {
  @override
  bool get native => false;
}

class _LatePreferences extends SharedPreferencesAsync {
  final reading = Completer<bool?>();
  @override
  Future<bool?> getBool(String key) => reading.future;
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });
  test(
    'complete names and language suffix outrank episode-only candidates',
    () {
      const refs = [
        SubtitleReference(kind: 'file', path: 'a', name: '番剧 - 01.ass'),
        SubtitleReference(kind: 'file', path: 'b', name: '番剧 - 01.zh-Hans.srt'),
        SubtitleReference(
          kind: 'file',
          path: 'c',
          name: 'Other Title - 001.ass',
        ),
      ];
      final candidates = [
        for (final r in refs)
          SubtitleCandidate(r, matchSubtitleName('番剧 - 01.mkv', r.name)),
      ];
      expect(candidates.map((c) => c.match), [
        SubtitleMatch.exact,
        SubtitleMatch.languageName,
        SubtitleMatch.episode,
      ]);
      expect(uniqueSubtitleMatch(candidates)?.reference.path, 'a');
      expect(
        uniqueSubtitleMatch(candidates.skip(1).toList())?.reference.path,
        'b',
      );
    },
  );
  test(
    'four-digit, bracketed, numeric episodes and explicit season conflicts',
    () {
      expect(
        matchSubtitleName(
          '[Fabre-RAW] Detective Conan 0608 [1080p].mkv',
          '名侦探柯南 - 608.sc.ass',
        ),
        SubtitleMatch.episode,
      );
      expect(
        matchSubtitleName('0608.mkv', '另一名字 第608集.srt'),
        SubtitleMatch.episode,
      );
      expect(
        matchSubtitleName('Show S02E01.mkv', 'Show S01E01.srt'),
        SubtitleMatch.none,
      );
      expect(
        matchSubtitleName('Show 1080p.mkv', 'Other 1080p.srt'),
        SubtitleMatch.none,
      );
      expect(
        matchSubtitleName('Show - 01.mkv', 'Show - 02.ass'),
        SubtitleMatch.none,
      );
      expect(matchSubtitleName('Movie.mkv', 'Movie.srt'), SubtitleMatch.exact);
      expect(
        matchSubtitleName('Show - 01.mp4', 'Show - 01.txt'),
        SubtitleMatch.none,
      );
    },
  );
  test('multiple best candidates require a choice instead of format/language guessing', () {
    final candidates = [
      for (final name in ['Show - 01.ass', 'Show - 01.srt', 'Other - 01.ass'])
        SubtitleCandidate(
          SubtitleReference(kind: 'file', path: name, name: name),
          matchSubtitleName('Show - 01.mkv', name),
        ),
    ];
    expect(uniqueSubtitleMatch(candidates), isNull);
    expect(uniqueSubtitleMatch([]), isNull);
  });
  test('Conan subtitles headed by a bare episode label match zero-padded video episodes', () {
    for (final pair in [
      ('0608', '608集 背叛的白色情人节（上集）.ass'),
      ('0609', '609集 背叛的白色情人节（下集）.ass'),
      ('0615', '615集 日志奏出的秘密（下集）.ass'),
    ]) {
      expect(
        matchSubtitleName(
          '[Fabre-RAW] Detective Conan ${pair.$1} [NetflixJP] [1080p].mkv',
          pair.$2,
        ),
        SubtitleMatch.episode,
      );
    }
    expect(
      matchSubtitleName('Show - 0615.mkv', '0615 话 字幕.srt'),
      SubtitleMatch.episode,
    );
    expect(
      matchSubtitleName('Show - 0615.mkv', '615話 字幕.vtt'),
      SubtitleMatch.episode,
    );
  });
  test(
    'bare labels do not truncate longer numbers or mix neighbouring episodes',
    () {
      expect(
        matchSubtitleName('Show - 0615.mkv', '1615集 字幕.ass'),
        SubtitleMatch.none,
      );
      expect(
        matchSubtitleName('Show - 0615.mkv', '10615集 字幕.ass'),
        SubtitleMatch.none,
      );
      expect(
        matchSubtitleName('Show - 0615.mkv', '614集 字幕.ass'),
        SubtitleMatch.none,
      );
      expect(
        matchSubtitleName('615集 日志奏出的秘密（下集）.mkv', '615集 日志奏出的秘密（下集）.ass'),
        SubtitleMatch.exact,
      );
      final candidates = [
        for (final name in ['615集 简体.ass', '615集 繁体.ass'])
          SubtitleCandidate(
            SubtitleReference(kind: 'file', path: name, name: name),
            matchSubtitleName('Show - 0615.mkv', name),
          ),
      ];
      expect(uniqueSubtitleMatch(candidates), isNull);
    },
  );
  test(
    'folder discovery reads only siblings and leaves the video index unchanged',
    () async {
      final base = await Directory.systemTemp.createTemp('orvex-subtitles-');
      final root = Directory('${base.path}/source');
      await root.create();
      await Directory('${root.path}/nested').create();
      for (final path in [
        'Show - 01.mkv',
        'Show - 01.srt',
        'Other - 01.ass',
        'Show - 02.vtt',
        'ignore.txt',
        'nested/Show - 01.ssa',
      ]) {
        await File('${root.path}/$path').writeAsString('fixture');
      }
      await Link('${root.path}/linked.ass')
          .create('${root.path}/Other - 01.ass');
      final library = FolderLibrary(
        access: _FileAccess(),
        directory: () async => Directory('${base.path}/index'),
      );
      await library.initialize();
      library.roots.add(
        FolderRoot(
          id: 'root',
          name: '测试',
          grant: root.path,
          location: root.uri.toString(),
        ),
      );
      library.entries.add(
        FolderEntry(
          id: 'video',
          rootId: 'root',
          path: 'Show - 01.mkv',
          directory: false,
        ),
      );
      library.changed();
      final service = LocalSubtitles(
        folders: library,
        imports: ImportedFileStore(directoryProvider: () async => base),
      );
      final matches = await service.discover(library.entries.single.media);
      expect(matches.map((c) => c.reference.name).toSet(), {
        'Show - 01.srt',
        'Other - 01.ass',
        'Show - 02.vtt',
      });
      expect(uniqueSubtitleMatch(matches)?.reference.name, 'Show - 01.srt');
      final prepared = await service.prepare(matches.first.reference);
      expect(await File.fromUri(prepared.media.uri).readAsString(), 'fixture');
      await prepared.release!();
      expect(library.entries.length, 1);
      library.dispose();
      await base.delete(recursive: true);
    },
  );
  test('legacy imported subtitle names are discoverable and memory survives a Documents move', () async {
    final base = await Directory.systemTemp.createTemp(
      'orvex-subtitle-memory-',
    );
    final docs = Directory('${base.path}/old');
    await docs.create();
    final subtitle = File('${docs.path}/Imports/subtitle-old/柯南 0608.ass');
    await subtitle.parent.create(recursive: true);
    await subtitle.writeAsString('fixture');
    final library = FolderLibrary(
      access: _FileAccess(),
      directory: () async => Directory('${base.path}/index'),
    );
    await library.initialize();
    final service = LocalSubtitles(
      folders: library,
      imports: ImportedFileStore(directoryProvider: () async => docs),
    );
    final video = LocalMedia(
      uri: Uri.file('/old-container/Documents/Imports/video/Conan 0608.mkv'),
      importPath: 'Imports/video/Conan 0608.mkv',
      name: 'Conan 0608.mkv',
    );
    final candidate = uniqueSubtitleMatch(await service.discover(video))!;
    await service.remember(video, SubtitleChoice.external(candidate.reference));
    final moved = await docs.rename('${base.path}/new');
    final restarted = LocalSubtitles(
      folders: library,
      imports: ImportedFileStore(directoryProvider: () async => moved),
    );
    final reopened = LocalMedia(
      uri: Uri.file('/new-container/Documents/Imports/video/Conan 0608.mkv'),
      importPath: video.importPath,
      name: video.name,
    );
    final saved = await restarted.readChoice(reopened);
    expect(saved.reference!.path, 'Imports/subtitle-old/柯南 0608.ass');
    expect(
      (await restarted.prepare(saved.reference!)).media.uri.path,
      contains('/new/Imports/'),
    );
    final otherCopy = LocalMedia(
      uri: Uri.file('/other'),
      importPath: 'Imports/another-copy/Conan 0608.mkv',
      name: video.name,
    );
    expect(
      (await restarted.readChoice(otherCopy)).mode,
      SubtitleChoiceMode.automatic,
    );
    await restarted.remember(reopened, const SubtitleChoice.off());
    expect((await service.readChoice(video)).mode, SubtitleChoiceMode.off);
    library.dispose();
    await base.delete(recursive: true);
  });
  test('global automatic matching persists and late reads cannot overwrite a user change', () async {
    final library = FolderLibrary(access: _FileAccess());
    final imports = ImportedFileStore();
    final preferences = _LatePreferences();
    final service = LocalSubtitles(
      folders: library,
      imports: imports,
      preferences: preferences,
    );
    final loading = service.automaticMatching();
    await service.setAutomaticMatching(false);
    preferences.reading.complete(true);
    expect(await loading, isFalse);
    expect(
      await LocalSubtitles(
        folders: library,
        imports: imports,
      ).automaticMatching(),
      isFalse,
    );
    library.dispose();
  });
  test('malformed memory is reported and unsafe relative subtitle paths are refused', () async {
    final library = FolderLibrary(access: _FileAccess());
    final service = LocalSubtitles(
      folders: library,
      imports: ImportedFileStore(),
    );
    final video = LocalMedia(uri: Uri.file('/a.mp4'), name: 'a.mp4');
    await SharedPreferencesAsync().setString(
      'orvex.subtitles.choice.v1.${video.resumeKey}',
      '{broken',
    );
    expect(() => service.readChoice(video), throwsFormatException);
    expect(
      () => service.prepare(
        const SubtitleReference(
          kind: 'import',
          path: 'Imports/../outside.ass',
          name: 'outside.ass',
        ),
      ),
      throwsFormatException,
    );
    library.dispose();
  });
}
