import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../media_sources/imported_file_store.dart';
import '../player/domain/playback_engine.dart';
import 'folder_library.dart';
import 'folder_models.dart';

String thumbnailKey(FolderEntry entry) => sha256
    .convert(utf8.encode('v1:${entry.rootId}:${entry.cacheVersion}'))
    .toString();
String importedThumbnailKey(LocalMedia media, int size, int modified) => sha256
    .convert(utf8.encode('import-v1:${media.resumeKey}:$size:$modified'))
    .toString();

typedef PreviewExtractor = Future<({List<int> bytes, int duration})> Function(
  Uri uri,
);

class ThumbnailRequest {
  ThumbnailRequest(this.entry) : imported = null;
  ThumbnailRequest.imported(this.imported) : entry = null;
  final FolderEntry? entry;
  final LocalMedia? imported;
  final completer = Completer<File?>();
  int duration = 0;
  String? issue;
  String backend = 'native';
  String? nativeFailure;
  bool cancelled = false;
  Future<File?> get result => completer.future;
  void cancel() {
    cancelled = true;
  }
}

/// Visible folder and imported rows share one extraction queue and disk quota.
/// A cancelled running request may fill a valid cache, but never its old row.
class ThumbnailCache {
  ThumbnailCache(
    this.library, {
    ImportedFileStore? imports,
    this.fallback,
    this.maxBytes = 128 * 1024 * 1024,
    this.maxFiles = 2000,
  }) : imports = imports ?? ImportedFileStore();
  final FolderLibrary library;
  final ImportedFileStore imports;
  final PreviewExtractor? fallback;
  final _results = <String, Map<String, dynamic>>{};
  final int maxBytes, maxFiles;
  final _pending = Queue<ThumbnailRequest>();
  final _failures = <String>{};
  bool _working = false, _disposed = false;
  int _failureRevision = -1;
  Timer? _saveTimer;

  ThumbnailRequest request(FolderEntry entry) =>
      _enqueue(ThumbnailRequest(entry));
  ThumbnailRequest requestImported(LocalMedia media) =>
      _enqueue(ThumbnailRequest.imported(media));
  ThumbnailRequest _enqueue(ThumbnailRequest request) {
    if (_failureRevision != library.revision) {
      _failureRevision = library.revision;
      _failures.clear();
    }
    if (_disposed) {
      request.completer.complete(null);
      return request;
    }
    _pending.addFirst(request);
    unawaited(_drain());
    return request;
  }

  Future<Directory> _directory() async =>
      Directory('${(await library.directory()).path}/thumbnails-v1')
          .create(recursive: true);

  Future<({List<int> bytes, int duration})> _extract(
    ThumbnailRequest request,
    FolderEntry? entry,
    LocalMedia? imported,
  ) async {
    Future<({List<int> bytes, int duration})> attempt(
      Future<({List<int> bytes, int duration})> Function() native,
      Future<Uri> Function() resolve,
    ) async {
      try {
        return await native();
      } on PlatformException catch (error) {
        request.nativeFailure = error.code;
        if (error.code != 'thumbnail_unavailable' || fallback == null) rethrow;
        request.backend = 'libmpv';
        return fallback!(await resolve());
      }
    }

    if (entry == null) {
      return attempt(
        () => library.access.thumbnailImported(imported!.relativeImportPath!),
        () async => imported!.uri,
      );
    }
    final root = library.root(entry.rootId);
    if (root == null || !entry.available) throw StateError('Media unavailable');
    final lease = await library.access.acquire(root);
    try {
      return await attempt(
        () => library.access.thumbnail(lease, entry.path),
        () =>
            library.access.resolve(lease, entry.path, identity: entry.identity),
      );
    } finally {
      await lease.release();
    }
  }

  Future<void> _record(
    String key,
    ThumbnailRequest request,
    bool success,
  ) async {
    _results[key] = {
      'status': success ? 'ready' : 'unavailable',
      'backend': request.backend,
      if (request.nativeFailure != null) 'nativeFailure': request.nativeFailure,
      'time': DateTime.now().toUtc().toIso8601String(),
    };
    if (_results.length > 100) _results.remove(_results.keys.first);
    try {
      final root = await library.directory();
      final file = File('${root.path}/thumbnail-results-v1.json');
      final partial = File('${file.path}.part');
      await partial.writeAsString(jsonEncode(_results), flush: true);
      await partial.rename(file.path);
    } catch (_) {
      // Optional diagnostics must not leave a preview request unfinished.
    }
  }

  Future<void> _drain() async {
    if (_working) return;
    _working = true;
    try {
      while (_pending.isNotEmpty && !_disposed) {
        final request = _pending.removeFirst();
        if (request.cancelled) {
          request.completer.complete(null);
          continue;
        }
        File? output;
        String? key;
        final entry = request.entry;
        try {
          LocalMedia? imported;
          FileStat? fingerprint;
          if (entry != null) {
            key = thumbnailKey(entry);
            request.duration = entry.duration;
          } else {
            imported = await imports.resolve(request.imported!);
            if (imported.relativeImportPath == null) {
              throw StateError('Not an app-owned import');
            }
            fingerprint = await File.fromUri(imported.uri).stat();
            if (fingerprint.type != FileSystemEntityType.file) {
              throw const FileSystemException('Missing imported video');
            }
            key = importedThumbnailKey(
              imported,
              fingerprint.size,
              fingerprint.modified.microsecondsSinceEpoch,
            );
          }
          final directory = await _directory();
          final file = File('${directory.path}/$key.jpg');
          final durationFile = File('${file.path}.duration');
          if (await file.exists()) {
            request.backend = 'cache';
            await file.setLastModified(DateTime.now());
            if (await durationFile.exists()) {
              request.duration =
                  int.tryParse(await durationFile.readAsString()) ??
                  request.duration;
            }
            output = file;
          } else if (!_failures.contains(key)) {
            final result = await _extract(request, entry, imported);
            var valid = !_disposed;
            if (entry != null) {
              valid =
                  valid &&
                  library.entries.any(
                    (e) =>
                        e.id == entry.id &&
                        e.cacheVersion == entry.cacheVersion,
                  );
            } else {
              final after = await File.fromUri(imported!.uri).stat();
              valid =
                  valid &&
                  after.size == fingerprint!.size &&
                  after.modified == fingerprint.modified;
            }
            if (valid) {
              final temporary = File('${file.path}.part');
              await temporary.writeAsBytes(result.bytes, flush: true);
              await temporary.rename(file.path);
              request.duration = result.duration;
              try {
                await durationFile.writeAsString(
                  '${result.duration}',
                  flush: true,
                );
              } on FileSystemException {
                /* Rebuildable metadata; keep the valid image. */
              }
              if (entry != null) {
                entry.duration = result.duration;
                _saveTimer?.cancel();
                _saveTimer = Timer(
                  const Duration(seconds: 1),
                  () => unawaited(library.save()),
                );
              }
              output = file;
              await trim(directory);
            }
          }
          if (output == null) request.issue = '暂时无法提取预览，仍可播放';
        } catch (_) {
          request.issue = '暂时无法提取预览，仍可播放';
          if (key != null) _failures.add(key);
          if (_failures.length > 256) _failures.remove(_failures.first);
        }
        if (key != null) await _record(key, request, output != null);
        request.completer.complete(request.cancelled ? null : output);
      }
    } finally {
      _working = false;
    }
  }

  Future<void> trim(Directory directory) async {
    final files = <({File file, FileStat stat})>[];
    await for (final item in directory.list(followLinks: false)) {
      if (item is File && item.path.endsWith('.jpg')) {
        files.add((file: item, stat: await item.stat()));
      }
    }
    files.sort((a, b) => b.stat.modified.compareTo(a.stat.modified));
    var bytes = 0;
    for (var i = 0; i < files.length; i++) {
      final metadata = File('${files[i].file.path}.duration');
      final hasMetadata = await metadata.exists();
      bytes += files[i].stat.size + (hasMetadata ? await metadata.length() : 0);
      if (i >= maxFiles || bytes > maxBytes) {
        await files[i].file.delete();
        if (hasMetadata) await metadata.delete();
      }
    }
  }

  void dispose() {
    _disposed = true;
    _saveTimer?.cancel();
    for (final request in _pending) {
      request.cancel();
      request.completer.complete(null);
    }
    _pending.clear();
  }
}
