import 'dart:math';

import '../player/domain/playback_engine.dart';

String folderId() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

bool validRelativePath(String path) =>
    path.isEmpty ||
    path
        .split('/')
        .every(
          (part) =>
              part.isNotEmpty &&
              part != '.' &&
              part != '..' &&
              !part.contains('\\'),
        );
String parentPath(String path) =>
    path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';
String leafName(String path) => path.split('/').last;
const videoExtensions = {'mp4', 'mkv', 'mov', 'm4v', 'webm', 'avi', 'ts'};
bool isVideoName(String name) =>
    videoExtensions.contains(name.split('.').last.toLowerCase());

/// Numeric runs are compared by value without parsing unbounded integers.
int naturalCompare(String a, String b) {
  final pattern = RegExp(r'\d+|\D+');
  final aa = pattern.allMatches(a.toLowerCase()).map((m) => m[0]!).toList();
  final bb = pattern.allMatches(b.toLowerCase()).map((m) => m[0]!).toList();
  for (var i = 0; i < min(aa.length, bb.length); i++) {
    final x = aa[i], y = bb[i];
    int result;
    if (RegExp(r'^\d').hasMatch(x) && RegExp(r'^\d').hasMatch(y)) {
      final xx = x.replaceFirst(RegExp(r'^0+(?=\d)'), '');
      final yy = y.replaceFirst(RegExp(r'^0+(?=\d)'), '');
      result = xx.length.compareTo(yy.length);
      if (result == 0) result = xx.compareTo(yy);
    } else {
      result = x.compareTo(y);
    }
    if (result != 0) return result;
  }
  final length = aa.length.compareTo(bb.length);
  return length == 0 ? a.compareTo(b) : length;
}

class FolderRoot {
  FolderRoot({
    required this.id,
    required this.name,
    required this.grant,
    required this.location,
    this.identity,
    this.scannedAt,
    this.issue,
  });
  final String id;
  String name, grant, location;
  String? identity, issue;
  DateTime? scannedAt;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'grant': grant,
    'location': location,
    'identity': identity,
    'scannedAt': scannedAt?.toIso8601String(),
    'issue': issue,
  };
  factory FolderRoot.fromJson(Map<String, dynamic> j) => FolderRoot(
    id: j['id'] as String,
    name: j['name'] as String,
    grant: j['grant'] as String,
    location: j['location'] as String,
    identity: j['identity'] as String?,
    scannedAt: DateTime.tryParse(j['scannedAt'] as String? ?? ''),
    issue: j['issue'] as String?,
  );
}

class FolderEntry {
  FolderEntry({
    required this.id,
    required this.rootId,
    required this.path,
    required this.directory,
    this.identity,
    this.size = 0,
    this.modified = 0,
    this.available = true,
    this.duration = 0,
  });
  final String id, rootId, path;
  final bool directory;
  final String? identity;
  final int size, modified;
  bool available;
  int duration;
  String get name => leafName(path);
  String get parent => parentPath(path);
  String get cacheVersion => '$id:$size:$modified';
  LocalMedia get media => LocalMedia(
    uri: Uri(scheme: 'orvex-folder', host: rootId, path: '/$id'),
    name: name,
    folderRoot: rootId,
    folderFile: id,
    modifiedAt: modified > 0
        ? DateTime.fromMillisecondsSinceEpoch(modified, isUtc: true)
        : null,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'rootId': rootId,
    'path': path,
    'directory': directory,
    'identity': identity,
    'size': size,
    'modified': modified,
    'available': available,
    'duration': duration,
  };
  factory FolderEntry.fromJson(Map<String, dynamic> j) {
    final path = j['path'] as String;
    if (!validRelativePath(path) || path.isEmpty) {
      throw const FormatException('Invalid index path');
    }
    return FolderEntry(
      id: j['id'] as String,
      rootId: j['rootId'] as String,
      path: path,
      directory: j['directory'] as bool,
      identity: j['identity'] as String?,
      size: j['size'] as int? ?? 0,
      modified: j['modified'] as int? ?? 0,
      available: j['available'] as bool? ?? true,
      duration: j['duration'] as int? ?? 0,
    );
  }
}

/// Never infer a move from a display title, size, or nonpersistent inode.
FolderEntry reconcileEntry(
  String rootId,
  String path,
  Map<String, dynamic> raw,
  List<FolderEntry> old,
  Set<String> used,
) {
  final identity = raw['identity'] as String?;
  final directory = raw['directory'] == true;
  final size = raw['size'] as int? ?? 0,
      modified = raw['modified'] as int? ?? 0;
  final candidates = old
      .where(
        (e) =>
            !used.contains(e.id) &&
            e.directory == directory &&
            (identity != null
                ? e.identity == identity
                : e.identity == null &&
                      e.path == path &&
                      e.size == size &&
                      e.modified == modified),
      )
      .toList();
  final previous = candidates.length == 1 ? candidates.single : null;
  final id = previous?.id ?? folderId();
  used.add(id);
  return FolderEntry(
    id: id,
    rootId: rootId,
    path: path,
    directory: directory,
    identity: identity,
    size: size,
    modified: modified,
    duration: previous?.size == size && previous?.modified == modified
        ? previous!.duration
        : 0,
  );
}
