import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';

import '../player/domain/playback_engine.dart';
import '../subtitles/domain/subtitle_models.dart' show isSubtitleName;

/// Mobile document pickers return temporary copies. Keep a durable app-owned
/// copy rather than retaining a transient or security-scoped picker path.
class ImportedFileStore {
  ImportedFileStore({
    this.directoryProvider = getApplicationDocumentsDirectory,
  });
  final Future<Directory> Function() directoryProvider;

  Future<void> _imports = Future.value();

  Future<LocalMedia> import(XFile source) {
    final result = _imports.then((_) => _import(source));
    _imports = result.then<void>((_) {}).catchError((Object _) {});
    return result;
  }

  Future<LocalMedia> _import(XFile source) async {
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
      final digestSink = _DigestSink();
      final hasher = sha256.startChunkedConversion(digestSink);
      final sink = partial.openWrite();
      try {
        await sink.addStream(
          source.openRead().map((chunk) {
            hasher.add(chunk);
            return chunk;
          }),
        );
        await sink.flush();
      } finally {
        await sink.close();
        hasher.close();
      }
      if (await partial.length() != await source.length()) {
        throw const FileSystemException('文件未完整导入，请重试');
      }
      final digest = digestSink.value!;
      Map<String, dynamic>? hashes;
      if (isVideoName(source.name)) {
        hashes = await _readHashes(imports);
        final existing = await _matchingVideo(
          digest.toString(),
          await partial.length(),
          root,
          hashes,
        );
        if (existing != null) {
          await targetDirectory.delete(recursive: true);
          await _saveHashes(imports, hashes);
          return existing;
        }
      }
      // The same subtitle selected twice must retain its identity, so the
      // playback adapter can select the existing track instead of duplicating it.
      if (!isVideoName(source.name)) {
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
      final media = _media(target, root, name: source.name);
      if (hashes != null) {
        hashes[media.relativeImportPath!] = _hashRecord(
          await target.stat(),
          digest.toString(),
        );
        await _saveHashes(imports, hashes);
      }
      return media;
    } catch (_) {
      // Only this import's new directory is removed; existing imports survive.
      if (await targetDirectory.exists()) {
        await targetDirectory.delete(recursive: true);
      }
      rethrow;
    }
  }

  Map<String, dynamic> _hashRecord(FileStat stat, String digest) => {
    'size': stat.size,
    'modified': stat.modified.microsecondsSinceEpoch,
    'changed': stat.changed.microsecondsSinceEpoch,
    'sha256': digest,
  };

  Future<Map<String, dynamic>> _readHashes(Directory imports) async {
    try {
      return jsonDecode(
        await File('${imports.path}/.video-hashes-v1.json').readAsString(),
      ) as Map<String, dynamic>;
    } on FileSystemException {
      return {};
    } on FormatException {
      return {};
    } on TypeError {
      return {};
    }
  }

  Future<void> _saveHashes(
    Directory imports,
    Map<String, dynamic> hashes,
  ) async {
    // This is a rebuildable accelerator, not the media/history source of truth.
    try {
      final file = File('${imports.path}/.video-hashes-v1.json');
      final partial = File('${file.path}.part');
      await partial.writeAsString(jsonEncode(hashes), flush: true);
      await partial.rename(file.path);
    } on FileSystemException {
      // Successful imports remain playable; a later attempt can rebuild hashes.
    }
  }

  Future<LocalMedia?> _matchingVideo(
    String digest,
    int length,
    Directory root,
    Map<String, dynamic> hashes,
  ) async {
    final videos = await listVideos();
    final live = videos.map((e) => e.relativeImportPath!).toSet();
    hashes.removeWhere((path, _) => !live.contains(path));
    for (final media in videos) {
      try {
        final file = File.fromUri(media.uri);
        final stat = await file.stat();
        if (stat.size != length) continue;
        final key = media.relativeImportPath!;
        final cached = hashes[key];
        String candidate;
        if (cached is Map &&
            cached['size'] == stat.size &&
            cached['modified'] == stat.modified.microsecondsSinceEpoch &&
            cached['changed'] == stat.changed.microsecondsSinceEpoch &&
            cached['sha256'] is String &&
            RegExp(r'^[a-f0-9]{64}$').hasMatch(cached['sha256'] as String)) {
          candidate = cached['sha256'] as String;
        } else {
          candidate = (await sha256.bind(file.openRead()).first).toString();
          final after = await file.stat();
          if (after.size != stat.size ||
              after.modified != stat.modified ||
              after.changed != stat.changed) {
            continue;
          }
          hashes[key] = _hashRecord(after, candidate);
        }
        if (candidate == digest) return _media(file, root, name: media.name);
      } on FileSystemException {
        // A missing/damaged old copy must not prevent importing another file.
      }
    }
    return null;
  }

  Future<List<LocalMedia>> listVideos() async {
    final root = await directoryProvider();
    final imports = Directory('${root.path}/Imports');
    if (!await imports.exists()) return [];
    final found = <({File file, DateTime modified})>[];
    await for (final entity in imports.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File || !isVideoName(entity.path)) continue;
      try {
        final stat = await entity.stat();
        if (stat.type == FileSystemEntityType.file) {
          found.add((file: entity, modified: stat.modified));
        }
      } on FileSystemException {
        // A file can disappear or become inaccessible during enumeration.
      }
    }
    found.sort((a, b) => b.modified.compareTo(a.modified));
    return [for (final entry in found) _media(entry.file, root)];
  }

  Future<List<LocalMedia>> listSubtitles() async {
    final root = await directoryProvider();
    final imports = Directory('${root.path}/Imports');
    if (!await imports.exists()) return [];
    final found = <LocalMedia>[];
    await for (final file in imports.list(
      recursive: true,
      followLinks: false,
    )) {
      if (file is File && isSubtitleName(file.path)) {
        found.add(_media(file, root));
      }
    }
    return found;
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

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}
