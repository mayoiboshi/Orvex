import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

import 'folder_models.dart';
import '../player/domain/playback_engine.dart';

class FolderLease {
  FolderLease(this.handle, this.location, this.release);
  final String handle, location;
  final Future<void> Function() release;
}

class FolderAccess {
  static const channel = MethodChannel('dev.orvex/folders');
  bool get native => Platform.isIOS || Platform.isMacOS || Platform.isAndroid;
  Future<Map<String, dynamic>?> pick() async {
    if (native) {
      return (await channel.invokeMapMethod<String, dynamic>('pick'));
    }
    final path = await getDirectoryPath(confirmButtonText: '添加媒体文件夹');
    return path == null
        ? null
        : {
            'name': Directory(path).uri.pathSegments
                .where((s) => s.isNotEmpty)
                .last,
            'grant': path,
            'location': Directory(path).uri.toString(),
          };
  }

  Future<FolderLease> acquire(FolderRoot root) async {
    if (native) {
      final result = (await channel.invokeMapMethod<String, dynamic>(
        'acquire',
        {'grant': root.grant},
      ))!;
      root.grant = result['grant'] as String? ?? root.grant;
      root.location = result['location'] as String;
      root.identity = result['identity'] as String? ?? root.identity;
      final handle = result['handle'] as String;
      return FolderLease(handle, root.location, () async {
        await channel.invokeMethod<void>('release', {'handle': handle});
      });
    }
    final directory = Directory(root.grant);
    if (!await directory.exists()) {
      throw const FileSystemException('目录不存在，请重新授权');
    }
    return FolderLease(root.grant, directory.uri.toString(), () async {});
  }

  String _path(FolderLease lease, String path) {
    if (!validRelativePath(path)) {
      throw const FormatException('Invalid relative path');
    }
    return Directory(lease.handle).uri.resolveUri(Uri(path: path)).toFilePath();
  }

  Future<List<Map<String, dynamic>>> list(
    FolderLease lease,
    String path,
  ) async {
    if (native) {
      final values = await channel.invokeListMethod<dynamic>('list', {
        'handle': lease.handle,
        'path': path,
      });
      return values!.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    final result = <Map<String, dynamic>>[];
    await for (final child in Directory(
      _path(lease, path),
    ).list(followLinks: false)) {
      if (child is Link) continue;
      try {
        final stat = await child.stat();
        final name = child.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (name.startsWith('.')) continue;
        result.add({
          'name': name,
          'directory': child is Directory,
          'size': stat.size,
          'modified': stat.modified.millisecondsSinceEpoch,
        });
      } catch (error) {
        result.add({'name': child.uri.pathSegments.last, 'error': '$error'});
      }
    }
    return result;
  }

  Future<Uri> resolve(
    FolderLease lease,
    String path, {
    String? identity,
  }) async {
    if (native) {
      return Uri.parse(
        (await channel.invokeMethod<String>('resolve', {
          'handle': lease.handle,
          'path': path,
          'identity': ?identity,
        }))!,
      );
    }
    final file = File(_path(lease, path));
    final root = await Directory(lease.handle).resolveSymbolicLinks();
    final target = await file.resolveSymbolicLinks();
    if (!target.startsWith('$root${Platform.pathSeparator}')) {
      throw const FileSystemException('文件超出授权目录');
    }
    return file.uri;
  }

  Future<({Uint8List bytes, int duration})> thumbnailImported(
    String path,
  ) async {
    if (!validImportPath(path)) {
      throw const FormatException('Invalid imported media path');
    }
    if (!native) throw UnsupportedError('当前平台尚无缩略图提取适配器');
    final result = (await channel.invokeMapMethod<String, dynamic>(
      'thumbnailImported',
      {'path': path},
    ))!;
    return (
      bytes: result['bytes'] as Uint8List,
      duration: result['duration'] as int,
    );
  }

  Future<({Uint8List bytes, int duration})> thumbnail(
    FolderLease lease,
    String path,
  ) async {
    if (!native) throw UnsupportedError('当前平台尚无缩略图提取适配器');
    final result = (await channel.invokeMapMethod<String, dynamic>(
      'thumbnail',
      {'handle': lease.handle, 'path': path},
    ))!;
    return (
      bytes: result['bytes'] as Uint8List,
      duration: result['duration'] as int,
    );
  }
}
