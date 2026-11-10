import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:orvex/features/player/domain/playback_defaults.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:orvex/features/player/domain/subtitle_style.dart';

class FakeEngine implements PlaybackEngine {
  final frameController = StreamController<PlaybackFrame>.broadcast(sync: true);
  final errorController = StreamController<String>.broadcast(sync: true);
  final interruptionController =
      StreamController<PlaybackInterruption>.broadcast(sync: true);
  final seeks = <Duration>[];
  final rates = <double>[];
  final volumes = <double>[];
  final audioSelections = <String>[];
  final subtitleStyles = <SubtitleStyle>[];
  bool failSubtitleStyle = false;
  Completer<void>? subtitleStyleGate;
  Completer<void>? subtitleSelectionGate;
  bool failSubtitleSelection = false;
  String? confirmedSubtitleId;
  Duration? openedAt;
  Completer<void>? openGate;
  bool disposed = false;
  bool failSubtitle = false;
  bool failOpen = false;
  bool failDispose = false;
  int toggles = 0;
  int pauses = 0;

  @override
  Stream<PlaybackFrame> get frames => frameController.stream;
  @override
  Stream<String> get errors => errorController.stream;
  @override
  Stream<PlaybackInterruption> get interruptions =>
      interruptionController.stream;
  @override
  Widget buildVideo({PlaybackFit fit = PlaybackFit.contain}) =>
      const ColoredBox(color: Color(0xFF000000));
  @override
  Future<void> open(LocalMedia media, {required Duration start}) async {
    openedAt = start;
    if (openGate != null) await openGate!.future;
    if (failOpen) throw StateError('unreadable video');
  }

  @override
  Future<void> togglePause() async {
    toggles++;
  }

  @override
  Future<void> pause() async {
    pauses++;
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
  }

  @override
  Future<void> selectAudio(String id) async => audioSelections.add(id);
  @override
  Future<void> setRate(double rate) async {
    rates.add(rate);
  }

  @override
  Future<void> setVolume(double volume) async {
    volumes.add(volume);
  }

  @override
  Future<void> setSubtitleStyle(SubtitleStyle style) async {
    if (subtitleStyleGate != null) await subtitleStyleGate!.future;
    if (failSubtitleStyle) throw StateError('subtitle style unavailable');
    subtitleStyles.add(style);
  }

  @override
  Future<void> selectSubtitle(String id) async {
    if (subtitleSelectionGate != null) await subtitleSelectionGate!.future;
    if (failSubtitleSelection) throw StateError('subtitle selection failed');
  }

  @override
  Future<String?> confirmedSubtitleTrackId() async => confirmedSubtitleId;

  @override
  Future<void> loadSubtitle(Uri uri, String name) async {
    if (failSubtitle) throw StateError('unreadable subtitle');
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    if (failDispose) throw StateError('release failed');
  }

  Future<void> cleanUp() async {
    await frameController.close();
    await errorController.close();
    await interruptionController.close();
  }
}

class MemoryResumeStore implements ResumeStore {
  final values = <String, Duration>{};
  bool failRead = false;
  bool failWrite = false;

  @override
  Future<Duration> read(String key) async {
    if (failRead) throw StateError('storage unavailable');
    return values[key] ?? Duration.zero;
  }

  @override
  Future<void> write(String key, Duration position) async {
    if (failWrite) throw StateError('storage full');
    values[key] = position;
  }
}
