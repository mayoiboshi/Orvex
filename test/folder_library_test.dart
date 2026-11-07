import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:orvex/features/media_sources/imported_file_store.dart';
import 'package:orvex/features/anime_metadata/domain/anime_filename.dart';
import 'package:orvex/features/anime_metadata/domain/anime_subject.dart';
import 'package:orvex/features/folder_library/folder_access.dart';
import 'package:orvex/features/folder_library/folder_library.dart';
import 'package:orvex/features/folder_library/folder_models.dart';
import 'package:orvex/features/folder_library/thumbnail_cache.dart';
import 'package:orvex/features/library/infrastructure/playback_history_store.dart';
import 'package:orvex/features/player/application/playback_session.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'support/fakes.dart';

class DiskAccess extends FolderAccess {
  @override
  bool get native => false;
  String? failPath;
  String? importedFailureCode;
  int releases = 0, extractions = 0, live = 0, maxLive = 0;
  Completer<void>? thumbnailGate;
  bool failPreview = false;
  @override
  Future<({Uint8List bytes, int duration})> thumbnailImported(
    String path,
  ) async {
    extractions++;
    if (importedFailureCode != null) {
      throw PlatformException(code: importedFailureCode!);
    }
    return (bytes: Uint8List.fromList([1, 2, 3, 4]), duration: 18000);
  }

  @override
  Future<FolderLease> acquire(FolderRoot root) async {
    final lease = await super.acquire(root);
    return FolderLease(lease.handle, lease.location, () async {
      releases++;
      await lease.release();
    });
  }

  @override
  Future<List<Map<String, dynamic>>> list(FolderLease lease, String path) {
    if (failPath == path) throw const FileSystemException('Revoked provider');
    return super.list(lease, path);
  }

  @override
  Future<({Uint8List bytes, int duration})> thumbnail(
    FolderLease lease,
    String path,
  ) async {
    extractions++;
    if (failPreview) {
      throw const FileSystemException('Preview permission unavailable');
    }
    live++;
    if (live > maxLive) maxLive = live;
    await thumbnailGate?.future;
    live--;
    return (bytes: Uint8List.fromList([1, 2, 3, 4]), duration: 60000);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary, source, store;
  late DiskAccess access;
  late FolderLibrary library;
  late FolderRoot root;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('orvex-folder-test-');
    source = await Directory('${temporary.path}/名侦探柯南').create();
    store = Directory('${temporary.path}/index');
    access = DiskAccess();
    library = FolderLibrary(access: access, directory: () async => store);
    await library.initialize();
    root = FolderRoot(
      id: 'root',
      name: '名侦探柯南',
      grant: source.path,
      location: source.uri.toString(),
    );
    library.roots.add(root);
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });
  tearDown(() async {
    library.dispose();
    await temporary.delete(recursive: true);
  });
  Future<File> file(String path) async {
    final result = File('${source.path}/$path');
    await result.parent.create(recursive: true);
    return result.writeAsString('only index test; not a playable video');
  }

  test('natural order, long numbers, bracket releases and safe paths', () {
    final names = ['第100集.mp4', '第10集.mp4', '第2集.mp4', '第9集.mp4']
      ..sort(naturalCompare);
    expect(names, ['第2集.mp4', '第9集.mp4', '第10集.mp4', '第100集.mp4']);
    final brackets = [
      '[SBSUB][CONAN][10][WEBRIP][1080P].mp4',
      '[SBSUB][CONAN][1][WEBRIP][1080P].mp4',
    ]..sort(naturalCompare);
    expect(AnimeFilename.parse(brackets.first).episode, 1);
    expect(
      naturalCompare(
        'x99999999999999999999999999',
        'x100000000000000000000000000',
      ),
      lessThan(0),
    );
    for (final path in ['../x', '/x', 'a//b', 'a/../b', r'a\b']) {
      expect(validRelativePath(path), isFalse);
    }
    expect(validRelativePath('TV/0001-0123/第2集.mp4'), isTrue);
  });

  test(
    'actual recursive tree, unsupported files and symlink loop, persistence',
    () async {
      for (final path in [
        'TV/0001-0123/第1集.mp4',
        'TV/0001-0123/第2集.mp4',
        'TV/0001-0123/第10集.mp4',
        'TV/0124-0173/第124集.mkv',
        'TV/0124-0173/第125集.mkv',
        '剧场版/剧场版1.mp4',
        '剧场版/剧场版2.mkv',
        'TV/readme.txt',
      ]) {
        await file(path);
      }
      await Link('${source.path}/TV/loop').create(source.path);
      await library.scan(root);
      expect(library.discovered, 7);
      expect(
        library
            .children(root.id, 'TV/0001-0123', directories: false)
            .map((e) => e.name),
        ['第1集.mp4', '第2集.mp4', '第10集.mp4'],
      );
      final current = library
          .children(root.id, 'TV/0124-0173', directories: false)
          .first;
      expect(library.playlist(current.media).map((e) => e.name), [
        '第124集.mkv',
        '第125集.mkv',
      ]);
      final prepared = await library.prepare(current.media);
      expect(prepared.media.uri.toFilePath(), '${source.path}/${current.path}');
      expect(prepared.media.resumeKey, current.media.resumeKey);
      expect(animeMediaKey(prepared.media), animeMediaKey(current.media));
      await prepared.release();
      final restored = FolderLibrary(
        access: access,
        directory: () async => store,
      );
      await restored.initialize();
      expect(
        restored.entries.map((e) => e.toJson()),
        library.entries.map((e) => e.toJson()),
      );
      expect(restored.roots.single.id, root.id);
      expect(access.releases, 2);
      restored.dispose();
    },
  );

  test('scan update retains unchanged ID, marks deleted unavailable, adds independently', () async {
    final a = await file('a/第1集.mp4');
    await library.scan(root);
    final before = library.children(root.id, 'a', directories: false).single;
    final history = PlaybackHistoryStore();
    await history.record(
      before.media,
      const PlaybackFrame(
        position: Duration(seconds: 20),
        duration: Duration(minutes: 1),
      ),
    );
    await library.scan(root);
    expect(
      library.children(root.id, 'a', directories: false).single.id,
      before.id,
    );
    await a.rename('${source.path}/a/第2集.mp4');
    await library.scan(root);
    final after = library.children(root.id, 'a', directories: false).single;
    expect(
      after.id,
      isNot(before.id),
      reason: 'No stable provider ID: do not guess a rename by size/name',
    );
    expect(
      library.entries.singleWhere((e) => e.id == before.id).available,
      isFalse,
    );
    expect(
      (await history.list()).single.media.resumeKey,
      before.media.resumeKey,
    );
  });

  test('reliable provider identity preserves progress on rename, ambiguous identities never merge', () {
    final old = FolderEntry(
      id: 'stable',
      rootId: root.id,
      path: 'old.mp4',
      directory: false,
      identity: 'volume:doc',
      size: 100,
      modified: 50,
      duration: 1000,
    );
    final renamed = reconcileEntry(
      root.id,
      'new/place.mp4',
      {'identity': 'volume:doc', 'size': 100, 'modified': 50},
      [old],
      {},
    );
    expect(renamed.id, old.id);
    expect(renamed.media.resumeKey, old.media.resumeKey);
    expect(renamed.duration, 1000);
    final duplicate = FolderEntry(
      id: 'other',
      rootId: root.id,
      path: 'copy.mp4',
      directory: false,
      identity: old.identity,
    );
    expect(
      reconcileEntry(
        root.id,
        'new.mp4',
        {'identity': old.identity},
        [old, duplicate],
        {},
      ).id,
      isNot(old.id),
    );
    expect(
      thumbnailKey(renamed),
      thumbnailKey(old),
      reason: 'Same file and fingerprint can reuse preview after rename',
    );
    expect(
      thumbnailKey(
        FolderEntry(
          id: old.id,
          rootId: root.id,
          path: old.path,
          directory: false,
          size: 101,
          modified: 50,
        ),
      ),
      isNot(thumbnailKey(old)),
    );
  });

  test('cancel and failed child directory preserve unseen records and release access', () async {
    await file('a/one.mp4');
    await file('b/two.mp4');
    await library.scan(root);
    final originalIds = library.entries.map((e) => e.id).toSet();
    var cancelled = false;
    void cancel() {
      if (!cancelled && library.scanning && library.foldersScanned == 1) {
        cancelled = true;
        library.cancelScan();
      }
    }

    library.addListener(cancel);
    await library.scan(root);
    library.removeListener(cancel);
    expect(library.entries.map((e) => e.id).toSet(), containsAll(originalIds));
    expect(library.entries.every((e) => e.available), isTrue);
    expect(root.issue, contains('取消'));
    access.failPath = 'b';
    await library.scan(root);
    expect(
      library.entries.singleWhere((e) => e.path == 'b/two.mp4').available,
      isFalse,
    );
    expect(
      library.entries.singleWhere((e) => e.path == 'a/one.mp4').available,
      isTrue,
    );
    expect(root.issue, contains('无法访问'));
    expect(access.releases, 3);
  });

  test('lost root retains index, bad traversal is refused and missing video has recovery error', () async {
    await file('one.mp4');
    await library.scan(root);
    final media = library.entries.single.media;
    await source.delete(recursive: true);
    await library.scan(root);
    expect(library.entries.single.media.resumeKey, media.resumeKey);
    expect(root.issue, contains('重新授权'));
    await expectLater(
      library.prepare(media),
      throwsA(isA<FileSystemException>()),
    );
    final lease = FolderLease(
      temporary.path,
      temporary.uri.toString(),
      () async {},
    );
    await expectLater(
      access.resolve(lease, '../secret.mp4'),
      throwsFormatException,
    );
  });

  test('cache serializes extraction, reuses disk, drops cancelled UI result and limits quota', () async {
    await file('one.mp4');
    await file('two.mp4');
    await library.scan(root);
    final videos = library.entries.where((e) => !e.directory).toList();
    final cache = ThumbnailCache(library, maxFiles: 1);
    access.thumbnailGate = Completer<void>();
    final first = cache.request(videos.first);
    while (access.extractions == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    first.cancel();
    final cancelled = cache.request(videos.last)..cancel();
    access.thumbnailGate!.complete();
    expect(await first.result, isNull);
    expect(await cancelled.result, isNull);
    expect(access.extractions, 1);
    final reused = await cache.request(videos.first).result;
    expect(await reused!.exists(), isTrue);
    expect(access.extractions, 1);
    final second = await cache.request(videos.last).result;
    expect(await second!.exists(), isTrue);
    expect(access.maxLive, 1);
    expect(await reused.exists(), isFalse);
    expect(
      (await second.parent.list().toList())
          .whereType<File>()
          .where((f) => f.path.endsWith('.jpg'))
          .length,
      1,
    );
    cache.dispose();
  });

  test('imported thumbnails use stable keys, persist duration, invalidate edited files and handle missing files', () async {
    final documents = Directory('${temporary.path}/documents');
    final imports = ImportedFileStore(directoryProvider: () async => documents);
    final source = await file('preview.mp4');
    final media = await imports.import(XFile(source.path));
    final cache = ThumbnailCache(library, imports: imports);
    final first = cache.requestImported(media);
    final firstFile = await first.result;
    expect(firstFile, isNotNull);
    expect(first.duration, 18000);
    final cached = cache.requestImported(media);
    expect((await cached.result)?.path, firstFile!.path);
    expect(cached.duration, 18000);
    expect(access.extractions, 1);
    final moved = LocalMedia(
      uri: Uri.file('/another-container/preview.mp4'),
      name: media.name,
      importPath: media.relativeImportPath,
    );
    expect(
      importedThumbnailKey(moved, 100, 200),
      importedThumbnailKey(media, 100, 200),
    );
    final target = File.fromUri(media.uri);
    await target.setLastModified(DateTime(2020));
    expect(
      (await cache.requestImported(media).result)?.path,
      isNot(firstFile.path),
    );
    expect(access.extractions, 2);
    await target.delete();
    final missing = cache.requestImported(media);
    expect(await missing.result, isNull);
    expect(missing.issue, isNotNull);
    expect(access.extractions, 2);
    cache.dispose();
  });

  test('thumbnail retry after permission recovery', () async {
    await file('one.mp4');
    await library.scan(root);
    final entry = library.entries.single;
    final cache = ThumbnailCache(library);
    access.failPreview = true;
    expect(await cache.request(entry).result, isNull);
    expect(await cache.request(entry).result, isNull);
    expect(access.extractions, 1);
    access.failPreview = false;
    await library.scan(root);
    expect(await cache.request(library.entries.single).result, isNotNull);
    expect(access.extractions, 2);
    cache.dispose();
  });

  test('playlist next, auto-next intent, stable history and resource release order', () async {
    final engines = <FakeEngine>[];
    final events = <String>[];
    final media = [
      for (final n in [1, 2, 10])
        LocalMedia(
          uri: Uri.file('/$n.mp4'),
          name: '$n.mp4',
          folderRoot: root.id,
          folderFile: '$n',
        ),
    ];
    final history = PlaybackHistoryStore();
    final session = PlaybackSession(
      createEngine: () {
        final engine = FakeEngine();
        engines.add(engine);
        return engine;
      },
      resumeStore: MemoryResumeStore(),
      onCheckpoint: history.record,
      prepare: (m) async => PreparedPlayback(m, () async {
        expect(engines.last.disposed, isTrue);
        events.add(m.name);
      }),
    );
    await session.open(media.first, queue: media);
    expect(session.hasPrevious, isFalse);
    expect(session.hasNext, isTrue);
    engines.last.frameController.add(
      const PlaybackFrame(
        position: Duration(seconds: 20),
        duration: Duration(minutes: 1),
      ),
    );
    await session.next();
    expect(session.playlistIndex, 1);
    expect(events, ['1.mp4']);
    session.autoNext = true;
    session.allowAutoNext = false;
    engines.last.frameController.add(
      const PlaybackFrame(duration: Duration(minutes: 1), completed: true),
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      session.playlistIndex,
      1,
      reason: 'Background/hidden page cannot auto-start next',
    );
    engines.last.frameController.add(
      const PlaybackFrame(duration: Duration(minutes: 1)),
    );
    session.allowAutoNext = true;
    engines.last.frameController.add(
      const PlaybackFrame(duration: Duration(minutes: 1), completed: true),
    );
    while (session.loading) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(session.media?.resumeKey, media.last.resumeKey);
    expect(session.hasNext, isFalse);
    await session.shutdown();
    expect(events, ['1.mp4', '2.mp4', '10.mp4']);
    final saved = await history.list();
    expect(saved.first.media.folderRoot, root.id);
    expect(saved.last.media.resumeKey, media.first.resumeKey);
    for (final engine in engines) {
      await engine.cleanUp();
    }
  });

  test('closing during permission resolution releases stale lease without creating engine', () async {
    final gate = Completer<PreparedPlayback>();
    var released = 0, created = 0;
    final session = PlaybackSession(
      createEngine: () {
        created++;
        return FakeEngine();
      },
      resumeStore: MemoryResumeStore(),
      prepare: (_) => gate.future,
    );
    final media = LocalMedia(
      uri: Uri(scheme: 'file', path: '/video.mp4'),
      name: 'video',
    );
    final opening = session.open(media);
    await Future<void>.delayed(Duration.zero);
    final closing = session.close();
    gate.complete(
      PreparedPlayback(media, () async {
        released++;
      }),
    );
    await opening;
    await closing;
    expect(released, 1);
    expect(created, 0);
    expect(session.media, isNull);
    await session.shutdown();
  });
  test('preview fallback respects permission errors', () async {
    final imports = ImportedFileStore(
      directoryProvider: () async => Directory('${temporary.path}/documents'),
    );
    final source = await file('preview.mkv');
    final media = await imports.import(XFile(source.path));
    var calls = 0;
    Future<({List<int> bytes, int duration})> fallback(Uri uri) async {
      expect(uri, media.uri);
      calls++;
      return (bytes: [1, 2, 3], duration: 10000);
    }

    access.importedFailureCode = 'thumbnail_unavailable';
    final cache = ThumbnailCache(library, imports: imports, fallback: fallback);
    final request = cache.requestImported(media);
    final image = await request.result;
    expect(image, isNotNull);
    expect(request.backend, 'libmpv');
    expect(calls, 1);
    cache.dispose();
    await image!.delete();
    access.importedFailureCode = 'folder_access';
    final forbidden = ThumbnailCache(
      library,
      imports: imports,
      fallback: fallback,
    );
    final denied = forbidden.requestImported(media);
    expect(await denied.result, isNull);
    expect(calls, 1);
    expect(denied.nativeFailure, 'folder_access');
    forbidden.dispose();
  });
}
