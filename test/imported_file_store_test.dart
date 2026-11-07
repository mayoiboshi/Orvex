import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/features/media_sources/imported_file_store.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';

void main() {
  late Directory directory;
  late ImportedFileStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('orvex-import-test-');
    store = ImportedFileStore(directoryProvider: () async => directory);
  });
  tearDown(() async => directory.delete(recursive: true));

  test(
    'import survives source deletion and remains discoverable after restart',
    () async {
      final source = await File('${directory.path}/original.mp4')
          .writeAsBytes([1, 2, 3]);
      final imported = await store.import(XFile(source.path));
      await source.delete();
      expect(await File.fromUri(imported.uri).readAsBytes(), [1, 2, 3]);
      final reopened = ImportedFileStore(
        directoryProvider: () async => directory,
      );
      expect((await reopened.listVideos()).single.uri, imported.uri);
    },
  );

  test('same-name imports preserve both files without overwrite', () async {
    final folderA = await Directory('${directory.path}/a').create();
    final folderB = await Directory('${directory.path}/b').create();
    final fileA = await File('${folderA.path}/same.mp4').writeAsBytes([1]);
    final fileB = await File('${folderB.path}/same.mp4').writeAsBytes([2]);
    final a = await store.import(XFile(fileA.path));
    final b = await store.import(XFile(fileB.path));
    expect(a.uri, isNot(b.uri));
    expect(await File.fromUri(a.uri).readAsBytes(), [1]);
    expect(await File.fromUri(b.uri).readAsBytes(), [2]);
  });

  test('failed import cleans only its own partial directory', () async {
    final keep = await File('${directory.path}/keep.mp4').writeAsBytes([1]);
    final imported = await store.import(XFile(keep.path));
    await expectLater(
      store.import(XFile('${directory.path}/missing.mp4')),
      throwsA(isA<FileSystemException>()),
    );
    expect(await File.fromUri(imported.uri).exists(), isTrue);
    final folders = (await Directory(
      '${directory.path}/Imports',
    ).list().toList()).whereType<Directory>().toList();
    expect(folders.length, 1);
  });

  test(
    'identical videos reuse an existing import across rename and store restart',
    () async {
      final source = await File('${directory.path}/episode.mp4')
          .writeAsBytes([1, 2, 3]);
      final first = await store.import(XFile(source.path));
      final renamed = await File('${directory.path}/renamed.mp4')
          .writeAsBytes([1, 2, 3]);
      final reopened = ImportedFileStore(
        directoryProvider: () async => directory,
      );
      final again = await reopened.import(XFile(renamed.path));
      expect(again.uri, first.uri);
      expect(again.resumeKey, first.resumeKey);
      expect(again.name, first.name);
      expect((await store.listVideos()).length, 1);
    },
  );

  test('concurrent identical imports only create one video', () async {
    final source = await File('${directory.path}/episode.mp4')
        .writeAsBytes([7, 8, 9]);
    final results = await Future.wait([
      store.import(XFile(source.path)),
      store.import(XFile(source.path)),
    ]);
    expect(results[0].resumeKey, results[1].resumeKey);
    expect((await store.listVideos()).length, 1);
  });

  test(
    'pre-hash legacy imports are reused without moving or deleting the file',
    () async {
      final legacy = File('${directory.path}/Imports/media-old/episode.mp4');
      await legacy.parent.create(recursive: true);
      await legacy.writeAsBytes([4, 5, 6]);
      final source = await File('${directory.path}/episode.mp4')
          .writeAsBytes([4, 5, 6]);
      final result = await store.import(XFile(source.path));
      expect(result.uri, legacy.uri);
      expect(result.relativeImportPath, 'Imports/media-old/episode.mp4');
      expect((await store.listVideos()).length, 1);
      await File('${directory.path}/Imports/.video-hashes-v1.json')
          .writeAsString('{broken');
      expect(
        (await store.import(XFile(source.path))).resumeKey,
        result.resumeKey,
      );
    },
  );

  test('changing an existing file invalidates its cached digest', () async {
    final source = await File('${directory.path}/episode.mp4')
        .writeAsBytes([1]);
    final first = await store.import(XFile(source.path));
    final existing = File.fromUri(first.uri);
    await existing.writeAsBytes([2]);
    await existing.setLastModified(DateTime(2020));
    final next = await store.import(XFile(source.path));
    expect(next.resumeKey, isNot(first.resumeKey));
    expect(await existing.readAsBytes(), [2]);
    expect(await File.fromUri(next.uri).readAsBytes(), [1]);
    expect((await store.listVideos()).length, 2);
  });

  test('repeated subtitle import keeps one stable identity', () async {
    final subtitle = await File('${directory.path}/sample.ass')
        .writeAsString('[Script Info]');
    final first = await store.import(XFile(subtitle.path));
    final second = await store.import(XFile(subtitle.path));
    expect(second.uri, first.uri);
    expect(await File.fromUri(first.uri).readAsString(), '[Script Info]');
  });

  test('moving the Documents directory preserves identity and resolves an old record to the live file', () async {
    final documents = await Directory('${directory.path}/old/Documents')
        .create(recursive: true);
    final oldStore = ImportedFileStore(
      directoryProvider: () async => documents,
    );
    final input = await File('${directory.path}/615 space 中文.mp4')
        .writeAsBytes([1, 2, 3]);
    final old = await oldStore.import(XFile(input.path));
    final moved = Directory('${directory.path}/new/Documents');
    await moved.parent.create(recursive: true);
    await documents.rename(moved.path);
    final relocated = ImportedFileStore(directoryProvider: () async => moved);
    final found = (await relocated.listVideos()).single;
    final resolved = await relocated.resolve(old);
    expect(await File.fromUri(old.uri).exists(), isFalse);
    expect(found.resumeKey, old.resumeKey);
    expect(resolved.uri, found.uri);
    expect(await File.fromUri(resolved.uri).readAsBytes(), [1, 2, 3]);
    await expectLater(
      relocated.resolve(
        LocalMedia(
          uri: old.uri,
          name: old.name,
          importPath: 'Imports/../outside.mp4',
        ),
      ),
      throwsFormatException,
    );
    await File.fromUri(found.uri).delete();
    await expectLater(
      relocated.resolve(old),
      throwsA(isA<FileSystemException>()),
    );
  });
}
