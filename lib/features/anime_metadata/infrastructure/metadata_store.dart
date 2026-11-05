import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../domain/anime_subject.dart';

class MetadataStore {
  MetadataStore({this.directoryProvider = getApplicationSupportDirectory});
  final Future<Directory> Function() directoryProvider;
  Future<void> _writes = Future.value();

  Future<({bool automatic, Map<String, AnimeMatch> entries})> read() async {
    final directory = await directoryProvider();
    final file = File('${directory.path}/bangumi-metadata-v1.json');
    if (!await file.exists()) {
      return (automatic: true, entries: <String, AnimeMatch>{});
    }
    final root = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final entries = <String, AnimeMatch>{};
    for (final entry
        in (root['entries'] as Map<String, dynamic>? ?? {}).entries) {
      try {
        entries[entry.key] = AnimeMatch.fromJson(
          entry.value as Map<String, dynamic>,
        );
      } on FormatException {
        /* Preserve other valid entries. */
      } on TypeError {
        /* Preserve other valid entries. */
      } on ArgumentError {
        /* Ignore an unsupported status value. */
      }
    }
    return (automatic: root['automatic'] as bool? ?? true, entries: entries);
  }

  Future<void> write(bool automatic, Map<String, AnimeMatch> entries) {
    final content = jsonEncode({
      'automatic': automatic,
      'entries': entries.map((key, value) => MapEntry(key, value.toJson())),
    });
    final result = _writes.then((_) async {
      final directory = await directoryProvider();
      await directory.create(recursive: true);
      final file = File('${directory.path}/bangumi-metadata-v1.json');
      final temporary = File('${file.path}.part');
      await temporary.writeAsString(content, flush: true);
      await temporary.rename(file.path);
    });
    _writes = result.catchError((Object _) {});
    return result;
  }

  Future<Map<int, String>> posters() async {
    final directory = await directoryProvider();
    if (!await directory.exists()) return {};
    final found = <int, String>{};
    await for (final file in directory.list()) {
      if (file is! File) continue;
      final match = RegExp(r'^bangumi-cover-(\d+)\.img$')
          .firstMatch(file.uri.pathSegments.last);
      if (match != null) found[int.parse(match[1]!)] = file.path;
    }
    return found;
  }

  Future<String> savePoster(int id, List<int> bytes) async {
    final directory = await directoryProvider();
    await directory.create(recursive: true);
    final file = File('${directory.path}/bangumi-cover-$id.img');
    final part = File('${file.path}.part');
    await part.writeAsBytes(bytes, flush: true);
    await part.rename(file.path);
    return file.path;
  }
}
