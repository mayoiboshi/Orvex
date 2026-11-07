import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../../folder_library/folder_library.dart';
import '../../folder_library/folder_models.dart';
import '../../media_sources/imported_file_store.dart';
import '../../player/domain/playback_engine.dart';
import '../domain/subtitle_matcher.dart';
import '../domain/subtitle_models.dart';

class LocalSubtitles extends SubtitleSupport {
  LocalSubtitles({
    required this.folders,
    required this.imports,
    SharedPreferencesAsync? preferences,
  }) : preferences = preferences ?? SharedPreferencesAsync();
  final FolderLibrary folders;
  final ImportedFileStore imports;
  final SharedPreferencesAsync preferences;
  Future<void> _writes = Future.value();
  bool? _automatic;
  static const automaticKey = 'orvex.subtitles.automatic.v1';
  String _key(LocalMedia media) =>
      'orvex.subtitles.choice.v1.${media.resumeKey}';
  @override
  Future<SubtitleChoice> readChoice(LocalMedia video) async {
    final value = await preferences.getString(_key(video));
    return value == null
        ? const SubtitleChoice.automatic()
        : SubtitleChoice.fromJson(jsonDecode(value) as Map<String, dynamic>);
  }

  Future<void> _write(Future<void> Function() write) {
    final result = _writes.then((_) => write());
    _writes = result.catchError((Object _) {});
    return result;
  }

  @override
  Future<void> remember(LocalMedia video, SubtitleChoice choice) => _write(
    () => preferences.setString(_key(video), jsonEncode(choice.toJson())),
  );
  @override
  Future<bool> automaticMatching() async {
    if (_automatic != null) return _automatic!;
    final saved = await preferences.getBool(automaticKey) ?? true;
    return _automatic ??= saved;
  }

  @override
  Future<void> setAutomaticMatching(bool value) {
    _automatic = value;
    return _write(() => preferences.setBool(automaticKey, value));
  }

  @override
  Future<List<SubtitleCandidate>> discover(LocalMedia video) async {
    final sources = <SubtitleReference>[];
    if (video.folderRoot != null) {
      final entry = folders.entry(video),
          root = folders.root(video.folderRoot!);
      if (entry == null || root == null || !entry.available) {
        throw const FileSystemException('视频目录已失效，请重新扫描或授权');
      }
      final lease = await folders.access.acquire(root);
      try {
        final parent = parentPath(entry.path);
        for (final raw in await folders.access.list(lease, parent)) {
          final name = raw['name'];
          if (name is! String ||
              name.isEmpty ||
              name.contains('/') ||
              !validRelativePath(name) ||
              raw['directory'] == true ||
              raw['error'] != null ||
              !isSubtitleName(name)) {
            continue;
          }
          sources.add(
            SubtitleReference(
              kind: 'folder',
              path: parent.isEmpty ? name : '$parent/$name',
              name: name,
              root: root.id,
              identity: raw['identity'] as String?,
            ),
          );
        }
      } finally {
        await lease.release();
      }
    } else if (video.relativeImportPath != null) {
      for (final media in await imports.listSubtitles()) {
        sources.add(SubtitleReference.imported(media));
      }
    } else if (video.uri.scheme == 'file' &&
        !Platform.isIOS &&
        !Platform.isAndroid) {
      await for (final file in File.fromUri(
        video.uri,
      ).parent.list(followLinks: false)) {
        if (file is File && isSubtitleName(file.path)) {
          sources.add(
            SubtitleReference(
              kind: 'file',
              path: file.uri.toString(),
              name: file.uri.pathSegments.last,
            ),
          );
        }
      }
    }
    final unique = <String, SubtitleCandidate>{};
    for (final reference in sources) {
      unique[reference.key] = SubtitleCandidate(
        reference,
        matchSubtitleName(video.name, reference.name),
      );
    }
    return unique.values.toList()..sort((a, b) {
      final rank = b.match.index.compareTo(a.match.index);
      return rank == 0
          ? naturalCompare(a.reference.name, b.reference.name)
          : rank;
    });
  }

  @override
  Future<PreparedSubtitle> prepare(SubtitleReference reference) async {
    if (!isSubtitleName(reference.name)) {
      throw const FormatException('不支持的字幕格式');
    }
    if (reference.kind == 'import') {
      if (!validImportPath(reference.path)) {
        throw const FormatException('字幕位置无效');
      }
      final media = await imports.resolve(
        LocalMedia(
          uri: Uri(),
          name: reference.name,
          importPath: reference.path,
        ),
      );
      return PreparedSubtitle(media);
    }
    if (reference.kind == 'folder') {
      if (!validRelativePath(reference.path) || reference.path.isEmpty) {
        throw const FormatException('字幕相对位置无效');
      }
      final root = folders.root(reference.root ?? '');
      if (root == null) throw const FileSystemException('字幕所在目录未授权');
      final lease = await folders.access.acquire(root);
      try {
        final uri = await folders.access.resolve(
          lease,
          reference.path,
          identity: reference.identity,
        );
        return PreparedSubtitle(
          LocalMedia(uri: uri, name: reference.name),
          lease.release,
        );
      } catch (_) {
        await lease.release();
        rethrow;
      }
    }
    if (reference.kind == 'file' && !Platform.isIOS && !Platform.isAndroid) {
      final uri = Uri.parse(reference.path);
      if (uri.scheme != 'file' || !await File.fromUri(uri).exists()) {
        throw const FileSystemException('字幕文件已失效');
      }
      return PreparedSubtitle(LocalMedia(uri: uri, name: reference.name));
    }
    throw const FormatException('字幕来源无效，请重新选择');
  }
}
