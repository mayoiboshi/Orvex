import 'package:flutter/widgets.dart';

class LocalMedia {
  const LocalMedia({
    required this.uri,
    required this.name,
    this.importPath,
    this.folderRoot,
    this.folderFile,
    this.modifiedAt,
  });
  final Uri uri;
  final String name;
  final String? importPath;
  final String? folderRoot, folderFile;
  final DateTime? modifiedAt;
  String? get relativeImportPath => importPath ?? legacyImportedPath(uri);
  String get resumeKey => folderRoot != null && folderFile != null
      ? 'orvex.folder.v1:$folderRoot:$folderFile'
      : relativeImportPath == null
      ? uri.toString()
      : 'orvex.import.v1:$relativeImportPath';
}

/// Older iOS records contain an absolute app-data UUID that changes on updates.
/// Only recognize the app-container layout, never an arbitrary desktop folder
/// named Imports. Newly imported media carries its relative identity explicitly.
String? legacyImportedPath(Uri uri) {
  if (uri.scheme != 'file') return null;
  final segments = uri.pathSegments;
  for (var i = 0; i + 5 < segments.length; i++) {
    if (segments[i] == 'Containers' &&
        segments[i + 1] == 'Data' &&
        segments[i + 2] == 'Application' &&
        segments[i + 4] == 'Documents' &&
        segments[i + 5] == 'Imports') {
      final relative = segments.sublist(i + 5);
      return validImportPath(relative.join('/')) ? relative.join('/') : null;
    }
  }
  return null;
}

bool validImportPath(String path) {
  final segments = path.split('/');
  return segments.length >= 2 &&
      segments.first == 'Imports' &&
      segments.every(
        (segment) =>
            segment.isNotEmpty &&
            segment != '.' &&
            segment != '..' &&
            !segment.contains('\\'),
      );
}

class MediaTrack {
  const MediaTrack(this.id, this.label);
  final String id;
  final String label;
}

class PlaybackFrame {
  const PlaybackFrame({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.playing = false,
    this.buffering = false,
    this.completed = false,
    this.rate = 1,
    this.volume = 100,
    this.audioTracks = const [],
    this.subtitleTracks = const [],
    this.audioTrackId = 'auto',
    this.subtitleTrackId = 'auto',
  });

  final Duration position;
  final Duration duration;
  final bool playing;
  final bool buffering;
  final bool completed;
  final double rate;
  final double volume;
  final List<MediaTrack> audioTracks;
  final List<MediaTrack> subtitleTracks;
  final String audioTrackId;
  final String subtitleTrackId;
}

enum PlaybackInterruption { audioFocusLost, headphonesDisconnected }

abstract interface class PlaybackEngine {
  Stream<PlaybackFrame> get frames;
  Stream<String> get errors;
  Stream<PlaybackInterruption> get interruptions;
  Widget buildVideo();
  Future<void> open(LocalMedia media, {required Duration start});
  Future<void> togglePause();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setRate(double rate);
  Future<void> setVolume(double volume);
  Future<void> selectAudio(String id);
  Future<void> selectSubtitle(String id);
  Future<void> loadSubtitle(Uri uri, String name);
  Future<void> dispose();
}

abstract interface class ResumeStore {
  Future<Duration> read(String key);
  Future<void> write(String key, Duration position);
}
