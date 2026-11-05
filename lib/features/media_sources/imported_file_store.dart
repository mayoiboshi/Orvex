import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';

import '../player/domain/playback_engine.dart';

/// Mobile document pickers return temporary copies. Keep a durable app-owned
/// copy rather than retaining a transient or security-scoped picker path.
class ImportedFileStore {
  ImportedFileStore({
    this.directoryProvider = getApplicationDocumentsDirectory,
  });
  final Future<Directory> Function() directoryProvider;

  Future<LocalMedia> import(XFile source) async {
    if (source.name.isEmpty || source.name == '.' || source.name == '..') {
      throw const FormatException('文件名为空，无法导入');
    }
    final root = await directoryProvider();
    final imports = Directory('${root.path}/Imports');
    await imports.create(recursive: true);
    final safeName = source.name.replaceAll(RegExp(r'[/\\:\x00-\x1F]'), '_');
    final targetDirectory = await imports.createTemp('media-');
    final partial = File('${targetDirectory.path}/$safeName.part');
    final target = File('${targetDirectory.path}/$safeName');
    try {
      final sink = partial.openWrite();
      try {
        await sink.addStream(source.openRead());
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (await partial.length() != await source.length()) {
        throw const FileSystemException('文件未完整导入，请重试');
      }
      // The same subtitle selected twice must retain its identity, so the
      // playback adapter can select the existing track instead of duplicating it.
      if (!isVideoName(source.name)) {
        final digest = await sha256.bind(partial.openRead()).first;
        final stableDirectory = Directory('${imports.path}/subtitle-$digest');
        await stableDirectory.create(recursive: true);
        final stable = File('${stableDirectory.path}/$safeName');
        if (!await stable.exists()) {
          await partial.rename(stable.path);
          await targetDirectory.delete(recursive: true);
          return _media(stable, root, name: source.name);
        }
        if (await sha256.bind(stable.openRead()).first == digest) {
          await targetDirectory.delete(recursive: true);
          return _media(stable, root, name: source.name);
        }
      }
      await partial.rename(target.path);
      return _media(target, root, name: source.name);
    } catch (_) {
      // Only this import's new directory is removed; existing imports survive.
      if (await targetDirectory.exists()) {
        await targetDirectory.delete(recursive: true);
      }
      rethrow;
    }
  }

  Future<List<LocalMedia>> listVideos() async {
    final root = await directoryProvider();
    final imports = Directory('${root.path}/Imports');
    if (!await imports.exists()) return [];
    final found = <File>[];
    await for (final entity in imports.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File && isVideoName(entity.path)) found.add(entity);
    }
    found.sort(
      (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
    );
    return [for (final file in found) _media(file, root)];
  }

  LocalMedia _media(File file, Directory root, {String? name}) => LocalMedia(
    uri: file.uri,
    name: name ?? file.uri.pathSegments.last,
    importPath: file.uri.pathSegments
        .skip(root.uri.pathSegments.where((part) => part.isNotEmpty).length)
        .join('/'),
  );

  Future<LocalMedia> resolve(LocalMedia media) async {
    final relative = media.relativeImportPath;
    if (relative == null) return media;
    if (!validImportPath(relative)) throw const FormatException('视频记录的文件位置无效');
    final root = await directoryProvider();
    final file = File.fromUri(root.uri.resolveUri(Uri(path: relative)));
    if (!await file.exists()) {
      throw const FileSystemException('视频文件已不在媒体库中，请重新导入');
    }
    return _media(file, root, name: media.name);
  }

  static bool isVideoName(String name) => const [
    'mp4',
    'mkv',
    'mov',
    'm4v',
    'webm',
    'avi',
    'ts',
  ].contains(name.split('.').last.toLowerCase());
}
