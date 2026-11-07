import '../../player/domain/playback_engine.dart';

bool isSubtitleName(String name) => const {
  'srt',
  'ass',
  'ssa',
  'vtt',
}.contains(name.split('.').last.toLowerCase());

class SubtitleReference {
  const SubtitleReference({
    required this.kind,
    required this.path,
    required this.name,
    this.root,
    this.identity,
  });
  final String kind, path, name;
  final String? root, identity;
  String get key => '$kind:${root ?? ''}:$path';
  factory SubtitleReference.imported(LocalMedia source) => SubtitleReference(
    kind: source.relativeImportPath == null ? 'file' : 'import',
    path: source.relativeImportPath ?? source.uri.toString(),
    name: source.name,
  );
  Map<String, dynamic> toJson() => {
    'kind': kind,
    'path': path,
    'name': name,
    'root': root,
    'identity': identity,
  };
  factory SubtitleReference.fromJson(Map<String, dynamic> json) {
    final ref = SubtitleReference(
      kind: json['kind'] as String,
      path: json['path'] as String,
      name: json['name'] as String,
      root: json['root'] as String?,
      identity: json['identity'] as String?,
    );
    if (!{'import', 'folder', 'file'}.contains(ref.kind) ||
        !isSubtitleName(ref.name)) {
      throw const FormatException('字幕记录无效');
    }
    return ref;
  }
}

enum SubtitleChoiceMode { automatic, off, external, embedded }

class SubtitleChoice {
  const SubtitleChoice.automatic()
    : mode = SubtitleChoiceMode.automatic,
      reference = null,
      track = null;
  const SubtitleChoice.off()
    : mode = SubtitleChoiceMode.off,
      reference = null,
      track = null;
  const SubtitleChoice.external(SubtitleReference source)
    : mode = SubtitleChoiceMode.external,
      reference = source,
      track = null;
  const SubtitleChoice.embedded(MediaTrack source)
    : mode = SubtitleChoiceMode.embedded,
      reference = null,
      track = source;
  final SubtitleChoiceMode mode;
  final SubtitleReference? reference;
  final MediaTrack? track;
  Map<String, dynamic> toJson() => {
    'version': 1,
    'mode': mode.name,
    if (reference != null) 'reference': reference!.toJson(),
    if (track != null) 'track': {'id': track!.id, 'label': track!.label},
  };
  factory SubtitleChoice.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) throw const FormatException('字幕记忆版本不支持');
    return switch (json['mode']) {
      'automatic' => const SubtitleChoice.automatic(),
      'off' => const SubtitleChoice.off(),
      'external' => SubtitleChoice.external(
        SubtitleReference.fromJson(
          Map<String, dynamic>.from(json['reference'] as Map),
        ),
      ),
      'embedded' => SubtitleChoice.embedded(
        MediaTrack(
          (json['track'] as Map)['id'] as String,
          (json['track'] as Map)['label'] as String,
        ),
      ),
      _ => throw const FormatException('字幕记忆无效'),
    };
  }
}

enum SubtitleMatch { none, episode, languageName, exact }

class SubtitleCandidate {
  const SubtitleCandidate(this.reference, this.match);
  final SubtitleReference reference;
  final SubtitleMatch match;
  String get reason => switch (match) {
    SubtitleMatch.exact => '完整名称匹配',
    SubtitleMatch.languageName => '名称匹配（语言后缀）',
    SubtitleMatch.episode => '集数匹配',
    SubtitleMatch.none => '其他本地字幕',
  };
}

SubtitleCandidate? uniqueSubtitleMatch(List<SubtitleCandidate> candidates) {
  final matched =
      candidates.where((c) => c.match != SubtitleMatch.none).toList()
        ..sort((a, b) => b.match.index.compareTo(a.match.index));
  if (matched.isEmpty) return null;
  return matched.where((c) => c.match == matched.first.match).length == 1
      ? matched.first
      : null;
}

class PreparedSubtitle {
  const PreparedSubtitle(this.media, [this.release]);
  final LocalMedia media;
  final Future<void> Function()? release;
}

/// File access and persistence stay outside the playback session.
abstract class SubtitleSupport {
  Future<SubtitleChoice> readChoice(LocalMedia video);
  Future<void> remember(LocalMedia video, SubtitleChoice choice);
  Future<bool> automaticMatching();
  Future<void> setAutomaticMatching(bool value);
  Future<List<SubtitleCandidate>> discover(LocalMedia video);
  Future<PreparedSubtitle> prepare(SubtitleReference reference);
}
