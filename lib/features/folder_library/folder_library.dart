import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../player/domain/playback_engine.dart';
import '../library/domain/media_series.dart';
import '../anime_metadata/domain/anime_filename.dart' show normalizedAnimeTitle;
import 'folder_access.dart';
import 'folder_models.dart';

Map<String, dynamic> _decodeIndex(String value) =>
    jsonDecode(value) as Map<String, dynamic>;

class FolderLibrary extends ChangeNotifier {
  FolderLibrary({FolderAccess? access, Future<Directory> Function()? directory})
    : access = access ?? FolderAccess(),
      directory = directory ?? getApplicationSupportDirectory;
  final FolderAccess access;
  final Future<Directory> Function() directory;
  final List<FolderRoot> roots = [];
  final List<FolderEntry> entries = [];
  bool loading = true, scanning = false, disposed = false;
  String? scanningRoot, lastScanRoot, error;
  int discovered = 0, foldersScanned = 0, _scanGeneration = 0;
  Future<void> _writes = Future.value();
  bool _canBackupPrimary = false;
  final _childrenCache = <String, List<FolderEntry>>{};
  int revision = 0;
  Map<String, FolderEntry>? _entryIndex;
  final _identities = <String, SeriesIdentity>{};
  List<LocalMedia>? _seriesImports;
  List<MediaSeries>? _seriesGroups;
  void changed() {
    revision++;
    _childrenCache.clear();
    _entryIndex = null;
    _identities.clear();
    _seriesGroups = null;
    if (!disposed) notifyListeners();
  }

  Future<File> _file() async =>
      File('${(await directory()).path}/folder-library-v1.json');
  Future<void> initialize() async {
    try {
      final file = await _file();
      for (final candidate in [file, File('${file.path}.backup')]) {
        try {
          if (!await candidate.exists()) continue;
          final data = await compute(
            _decodeIndex,
            await candidate.readAsString(),
          );
          final loadedRoots = (data['roots'] as List)
              .map(
                (j) => FolderRoot.fromJson(Map<String, dynamic>.from(j as Map)),
              )
              .toList();
          final loadedEntries = <FolderEntry>[];
          var skippedEntries = false;
          for (final j in data['entries'] as List) {
            try {
              loadedEntries.add(
                FolderEntry.fromJson(Map<String, dynamic>.from(j as Map)),
              );
            } catch (_) {
              skippedEntries = true;
            }
          }
          roots.addAll(loadedRoots);
          entries.addAll(loadedEntries);
          final fromPrimary = identical(candidate, file);
          _canBackupPrimary = fromPrimary && !skippedEntries;
          if (skippedEntries) {
            error = '部分目录记录无效，重新扫描可修复';
          } else if (!fromPrimary) {
            error = '目录索引已从备份恢复';
          }
          break;
        } catch (_) {
          error = '目录索引损坏，未找到可用索引';
        }
      }
    } catch (e) {
      error = '目录索引未能读取：$e';
    }
    loading = false;
    changed();
  }

  Future<void> save() {
    final snapshot = jsonEncode({
      'version': 1,
      'roots': roots.map((r) => r.toJson()).toList(),
      'entries': entries.map((e) => e.toJson()).toList(),
    });
    final result = _writes.then((_) async {
      final file = await _file();
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.part');
      await temporary.writeAsString(snapshot, flush: true);
      if (_canBackupPrimary && await file.exists()) {
        await file.copy('${file.path}.backup');
      }
      await temporary.rename(file.path);
      _canBackupPrimary = true;
    });
    _writes = result.catchError((Object e) {
      error = '目录索引保存失败：$e';
      changed();
    });
    return _writes;
  }

  FolderRoot? root(String id) => roots.where((r) => r.id == id).firstOrNull;
  FolderEntry? entry(LocalMedia media) {
    _entryIndex ??= {for (final e in entries) '${e.rootId}:${e.id}': e};
    return _entryIndex!['${media.folderRoot}:${media.folderFile}'];
  }

  List<LocalMedia> catalog(List<LocalMedia> imported) => [
    ...imported,
    for (final entry in entries)
      if (entry.available && !entry.directory) entry.media,
  ];
  SeriesIdentity identityFor(LocalMedia media) {
    return _identities.putIfAbsent('${media.resumeKey}:${media.name}', () {
      final node = entry(media);
      String? title;
      int? folderSeason;
      if (node != null) {
        final names = [
          root(node.rootId)?.name ?? '',
          ...node.parent.split('/'),
        ];
        for (final name in names.reversed) {
          final season = RegExp(r'^(?:season|s)(\d{1,2})$')
              .firstMatch(normalizedAnimeTitle(name));
          if (season != null) folderSeason ??= int.tryParse(season[1]!);
          if (name.isEmpty ||
              RegExp(r'^[\d\s_–—-]+$').hasMatch(name) ||
              RegExp(
                r'^(?:tv|episodes?|videos?|movies?|media|anime|season\s*\d+|s\d+|第.+季|剧场版|视频|媒体|动漫|动画)$',
                caseSensitive: false,
              ).hasMatch(name)) {
            continue;
          }
          title = name;
          break;
        }
      }
      return identifySeries(
        media,
        folderTitle: title,
        folderSeason: folderSeason,
      );
    });
  }

  List<MediaSeries> series(List<LocalMedia> imported) {
    if (_seriesGroups == null || !identical(imported, _seriesImports)) {
      _seriesImports = imported;
      _seriesGroups = groupSeries(catalog(imported), identify: identityFor);
    }
    return _seriesGroups!;
  }

  List<LocalMedia> seriesMembers(LocalMedia media, List<LocalMedia> imported) {
    final identity = identityFor(media);
    if (!identity.episodic) return [media];
    return series(imported)
            .where((s) => s.key == identity.key)
            .firstOrNull
            ?.media ??
        [media];
  }

  List<FolderEntry> children(String rootId, String path, {bool? directories}) =>
      _childrenCache.putIfAbsent(
        '$rootId:$path:$directories',
        () =>
            entries
                .where(
                  (e) =>
                      e.rootId == rootId &&
                      e.parent == path &&
                      e.available &&
                      (directories == null || e.directory == directories),
                )
                .toList()
              ..sort((a, b) => naturalCompare(a.name, b.name)),
      );
  List<LocalMedia> playlist(LocalMedia media) {
    final current = entry(media);
    return current == null
        ? [media]
        : children(
            current.rootId,
            current.parent,
            directories: false,
          ).map((e) => e.media).toList();
  }

  Future<void> add({FolderRoot? reauthorize}) async {
    if (scanning || loading) return;
    try {
      final selection = await access.pick();
      if (selection == null || disposed) return;
      var existing = reauthorize;
      existing ??= roots
          .where(
            (r) => selection['identity'] != null
                ? r.identity == selection['identity']
                : r.location == selection['location'],
          )
          .firstOrNull;
      if (reauthorize != null &&
          (reauthorize.identity != null && selection['identity'] != null
              ? reauthorize.identity != selection['identity']
              : reauthorize.location != selection['location'])) {
        throw const FileSystemException('请选择原来的根目录；其他目录请通过“添加文件夹”添加');
      }
      final selected =
          existing ??
          FolderRoot(
            id: folderId(),
            name: selection['name'] as String,
            grant: selection['grant'] as String,
            location: selection['location'] as String,
            identity: selection['identity'] as String?,
          );
      selected.grant = selection['grant'] as String;
      selected.issue = null;
      if (existing == null) roots.add(selected);
      await save();
      await scan(selected);
    } catch (e) {
      error = '未能添加目录：$e';
      changed();
    }
  }

  void cancelScan() {
    ++_scanGeneration;
    changed();
  }

  Future<void> scan(FolderRoot root) async {
    if (scanning || disposed) return;
    final generation = ++_scanGeneration;
    scanning = true;
    scanningRoot = root.id;
    lastScanRoot = null;
    discovered = 0;
    foldersScanned = 0;
    error = null;
    changed();
    final old = entries.where((e) => e.rootId == root.id).toList();
    final byIdentity = <String, List<FolderEntry>>{};
    final byPath = <String, List<FolderEntry>>{};
    for (final previous in old) {
      (byPath[previous.path] ??= []).add(previous);
      if (previous.identity != null) {
        (byIdentity[previous.identity!] ??= []).add(previous);
      }
    }
    final visitedDirectories = <String>{
      if (root.identity != null) root.identity!,
    };
    final seen = <FolderEntry>[], used = <String>{}, failed = <String>{};
    var complete = false;
    FolderLease? lease;
    try {
      lease = await access.acquire(root);
      root.issue = null;
      final pending = <String>[''];
      var cursor = 0;
      while (cursor < pending.length &&
          generation == _scanGeneration &&
          !disposed) {
        final path = pending[cursor++];
        try {
          final values = await access.list(lease, path);
          if (generation != _scanGeneration || disposed) break;
          for (final raw in values) {
            final name = raw['name'] as String;
            if (name.contains('/') ||
                !validRelativePath(name) ||
                name.isEmpty) {
              continue;
            }
            final relative = path.isEmpty ? name : '$path/$name';
            if (raw['error'] != null) {
              failed.add(relative);
              continue;
            }
            final isDirectory = raw['directory'] == true;
            if (!isDirectory && !isVideoName(name)) continue;
            final identity = raw['identity'] as String?;
            if (isDirectory &&
                identity != null &&
                !visitedDirectories.add(identity)) {
              continue;
            }
            final candidates = identity == null
                ? byPath[relative]
                : byIdentity[identity];
            final node = reconcileEntry(
              root.id,
              relative,
              raw,
              candidates ?? const [],
              used,
            );
            seen.add(node);
            if (isDirectory) {
              pending.add(relative);
            } else {
              discovered++;
            }
          }
          foldersScanned++;
        } catch (_) {
          failed.add(path);
        }
        // Publish partial results without marking unseen entries as deleted.
        final seenPaths = seen.map((n) => n.path).toSet();
        entries.removeWhere(
          (e) =>
              e.rootId == root.id &&
              (used.contains(e.id) || seenPaths.contains(e.path)),
        );
        final known = entries.map((e) => e.id).toSet();
        entries.addAll(seen.where((e) => !known.contains(e.id)));
        changed();
        await Future<void>.delayed(Duration.zero);
      }
      complete = generation == _scanGeneration && !disposed;
      if (complete) {
        entries.removeWhere((e) => e.rootId == root.id);
        entries.addAll(seen);
        for (final previous in old.where((e) => !used.contains(e.id))) {
          if (!_hasUnreadableAncestor(previous.path, failed)) {
            previous.available = false;
          }
          entries.add(previous);
        }
        root.scannedAt = DateTime.now().toUtc();
        root.issue = failed.isEmpty ? null : '${failed.length} 处内容无法访问，旧记录已保留';
      } else {
        root.issue = '扫描已取消，已发现内容与旧记录均保留';
      }
    } catch (e) {
      root.issue = '目录无法访问，请重新授权';
      error = '扫描失败：$e';
    } finally {
      try {
        await lease?.release();
      } catch (_) {
        root.issue = '目录授权释放失败，请重启应用';
      }
      await save();
      scanning = false;
      scanningRoot = null;
      lastScanRoot = root.id;
      changed();
    }
  }

  bool _hasUnreadableAncestor(String path, Set<String> failed) {
    if (failed.isEmpty) return false;
    while (!failed.contains(path)) {
      if (path.isEmpty) return false;
      path = parentPath(path);
    }
    return true;
  }

  Future<({LocalMedia media, Future<void> Function() release})> prepare(
    LocalMedia media,
  ) async {
    final node = entry(media);
    final source = root(media.folderRoot ?? '');
    if (node == null || source == null || !node.available) {
      throw const FileSystemException('目录或视频已失效，请在媒体库重新扫描或授权');
    }
    FolderLease? lease;
    try {
      lease = await access.acquire(source);
      final uri = await access.resolve(
        lease,
        node.path,
        identity: node.identity,
      );
      source.issue = null;
      return (
        media: LocalMedia(
          uri: uri,
          name: node.name,
          folderRoot: node.rootId,
          folderFile: node.id,
        ),
        release: lease.release,
      );
    } catch (_) {
      await lease?.release();
      source.issue = '视频无法访问，请重新扫描或授权';
      changed();
      rethrow;
    }
  }

  @override
  void dispose() {
    disposed = true;
    ++_scanGeneration;
    super.dispose();
  }
}
