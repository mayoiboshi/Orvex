import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/playback_defaults.dart';
import '../domain/playback_engine.dart';
import '../domain/subtitle_style.dart';

/// Native mpv distinguishes integer options such as sub-pos from floats.
@visibleForTesting
Map<String, String> subtitleStyleNativeProperties(
  SubtitleStyle style,
  String defaultAssOverride,
) => {
  'sub-delay': '${style.delay}',
  'sub-scale': '${style.scale}',
  'sub-pos': '${style.position.clamp(0, 100).round()}',
  'sub-bold': style.bold ? 'yes' : 'no',
  'sub-italic': style.italic ? 'yes' : 'no',
  'sub-color': style.color,
  'sub-border-color': style.outlineColor,
  'sub-border-size': '${style.outlineSize}',
  'sub-ass-override': style.overrideAss ? 'force' : defaultAssOverride,
};

class MediaKitEngine implements PlaybackEngine {
  MediaKitEngine({bool diagnostics = false, this.silentAudioForTesting = false})
    : _player = Player(
        configuration: PlayerConfiguration(
          libass: true,
          libassAndroidFont: 'assets/fonts/NotoSansCJKsc-Regular.otf',
          libassAndroidFontName: 'Noto Sans CJK SC',
          logLevel: diagnostics ? MPVLogLevel.debug : MPVLogLevel.error,
        ),
      ) {
    _video = VideoController(_player);
    if (Platform.isIOS) {
      _audioChannel.setMethodCallHandler((call) async {
        if (_disposed || call.method != 'interruption') return;
        final reason = switch (call.arguments) {
          'headphonesDisconnected' =>
            PlaybackInterruption.headphonesDisconnected,
          _ => PlaybackInterruption.audioFocusLost,
        };
        _interruptions.add(reason);
      });
    }
    void emit(dynamic _) {
      if (!_disposed) _frames.add(_snapshot());
    }

    if (diagnostics) {
      _subscriptions.add(
        _player.stream.log.listen((log) {
          if (log.prefix.contains('ao') ||
              log.text.toLowerCase().contains('audio') ||
              log.text.toLowerCase().contains('font') ||
              log.prefix.contains('sub')) {
            debugPrint('MPV ${log.prefix}: ${log.text}');
          }
        }),
      );
    }
    _subscriptions.addAll([
      _player.stream.position.listen(emit),
      _player.stream.duration.listen(emit),
      _player.stream.playing.listen(emit),
      _player.stream.buffering.listen(emit),
      _player.stream.completed.listen(emit),
      _player.stream.rate.listen(emit),
      _player.stream.volume.listen(emit),
      _player.stream.tracks.listen(emit),
      _player.stream.track.listen(emit),
    ]);
  }

  // Native libass preserves ASS positioning, fonts and styling. The default
  // plain-text Flutter subtitle overlay cannot reproduce those effects.
  final Player _player;
  final bool silentAudioForTesting;
  late final VideoController _video;
  final _frames = StreamController<PlaybackFrame>.broadcast(sync: true);
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  static const _audioChannel = MethodChannel('dev.orvex/audio-session');
  final _interruptions = StreamController<PlaybackInterruption>.broadcast(
    sync: true,
  );
  bool _disposed = false;
  String? _defaultAssOverride;
  static Future<String>? _fontDirectory;

  static Future<String> _prepareSubtitleFonts() {
    return _fontDirectory ??=
        () async {
          final support = await getApplicationSupportDirectory();
          final directory = Directory('${support.path}/subtitle-fonts-v2');
          await directory.create(recursive: true);
          final font = File('${directory.path}/NotoSansCJKsc-Regular.otf');
          if (!await font.exists()) {
            final data = await rootBundle.load(
              'assets/fonts/NotoSansCJKsc-Regular.otf',
            );
            final partial = File('${font.path}.part');
            await partial.writeAsBytes(data.buffer.asUint8List(), flush: true);
            await partial.rename(font.path);
          }
          return directory.path;
        }().catchError((Object error) {
          _fontDirectory = null;
          throw error;
        });
  }

  @override
  Stream<PlaybackFrame> get frames => _frames.stream;
  @override
  Stream<String> get errors => _player.stream.error;
  @override
  Stream<PlaybackInterruption> get interruptions => _interruptions.stream;

  PlaybackFrame _snapshot() {
    final state = _player.state;
    String label(String id, String? title, String? language) =>
        title ?? language ?? '轨道 $id';
    return PlaybackFrame(
      position: state.position,
      duration: state.duration,
      playing: state.playing,
      buffering: state.buffering,
      completed: state.completed,
      rate: state.rate,
      volume: state.volume,
      audioTracks: [
        for (final track in state.tracks.audio)
          if (track.id != 'auto' && track.id != 'no')
            MediaTrack(
              track.id,
              label(track.id, track.title, track.language),
              language: track.language,
              codec: track.codec,
              channelLayout: track.channels,
              channelCount: track.channelscount,
            ),
      ],
      subtitleTracks: [
        for (final track in state.tracks.subtitle)
          if (track.id != 'auto' && track.id != 'no')
            MediaTrack(
              track.id,
              label(track.id, track.title, track.language),
              language: track.language,
              codec: track.codec,
            ),
      ],
      audioTrackId: state.track.audio.id,
      subtitleTrackId: state.track.subtitle.id,
    );
  }

  @override
  Widget buildVideo({PlaybackFit fit = PlaybackFit.contain}) => Video(
    controller: _video,
    controls: NoVideoControls,
    fit: fit == PlaybackFit.cover ? BoxFit.cover : BoxFit.contain,
  );

  @override
  Future<void> open(LocalMedia media, {required Duration start}) async {
    // The bundled libass builds do not consistently discover system CJK fonts.
    // Register our OFL font directory before opening any subtitle decoder.
    final native = _player.platform as NativePlayer;
    // Orvex owns matching and explicit off/manual choices, rather than mpv's
    // independent default filename autoloading. Internal tracks remain intact.
    await native.setProperty('sub-auto', 'no');
    await native.setProperty('sub-fonts-dir', await _prepareSubtitleFonts());
    await native.setProperty('sub-font', 'Noto Sans CJK SC');
    if (Platform.isIOS) {
      await const MethodChannel('dev.orvex/audio-session')
          .invokeMethod<void>('activate');
    }
    if (silentAudioForTesting) {
      if (!Platform.isIOS) {
        throw StateError('Silent simulator experiments are iOS-only');
      }
      final simulator = await const MethodChannel('dev.orvex/audio-session')
          .invokeMethod<bool>('isSimulator');
      if (simulator != true) {
        throw StateError('Silent mode must not be used on an iPhone');
      }
      await (_player.platform as NativePlayer).setProperty('ao', 'null');
    }
    await _player.open(Media(media.uri.toString(), start: start));
  }

  @override
  Future<void> togglePause() async {
    if (Platform.isIOS && !_player.state.playing) {
      await const MethodChannel('dev.orvex/audio-session')
          .invokeMethod<void>('activate');
    }
    await _player.playOrPause();
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);
  @override
  Future<void> setRate(double rate) => _player.setRate(rate);
  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);
  @override
  Future<void> setSubtitleStyle(SubtitleStyle style) async {
    final native = _player.platform as NativePlayer;
    _defaultAssOverride ??= await native.getProperty('sub-ass-override');
    if (_defaultAssOverride!.isEmpty) {
      throw StateError('不支持字幕设置 sub-ass-override');
    }
    final properties = subtitleStyleNativeProperties(
      style,
      _defaultAssOverride!,
    );
    for (final property in properties.entries) {
      await native.setProperty(property.key, property.value);
      final actual = await native.getProperty(property.key);
      if (actual.isEmpty) throw StateError('不支持字幕设置 ${property.key}');
      final expectedNumber = double.tryParse(property.value);
      if (expectedNumber != null) {
        final actualNumber = double.tryParse(actual);
        if (actualNumber == null ||
            (actualNumber - expectedNumber).abs() > .001) {
          throw StateError('字幕设置 ${property.key} 未生效');
        }
      } else if (actual.toUpperCase() != property.value.toUpperCase()) {
        throw StateError('字幕设置 ${property.key} 未生效');
      }
    }
  }

  @override
  Future<void> selectAudio(String id) =>
      _player.setAudioTrack(AudioTrack(id, null, null));
  @override
  Future<void> selectSubtitle(String id) =>
      _player.setSubtitleTrack(SubtitleTrack(id, null, null));
  @override
  Future<String?> confirmedSubtitleTrackId() async {
    final value = (await (_player.platform as NativePlayer).getProperty('sid'))
        .trim();
    return value == 'no' || int.tryParse(value) != null ? value : null;
  }

  @override
  Future<void> loadSubtitle(Uri uri, String name) async {
    if (uri.scheme == 'file' && !await File.fromUri(uri).exists()) {
      throw const FileSystemException('字幕文件不存在或无法读取');
    }
    final native = _player.platform as NativePlayer;
    final previous = await native.getProperty('sid');
    final count =
        int.tryParse(await native.getProperty('track-list/count')) ?? 0;
    // Reuse an existing external track instead of adding duplicates.
    for (var index = 0; index < count; index++) {
      final path = await native.getProperty(
        'track-list/$index/external-filename',
      );
      if (path == uri.toString() ||
          (uri.scheme == 'file' && path == uri.toFilePath())) {
        final id = await native.getProperty('track-list/$index/id');
        await selectSubtitle(id);
        return;
      }
    }
    await _player.setSubtitleTrack(
      SubtitleTrack.uri(uri.toString(), title: name),
    );
    final id = await native.getProperty('sid');
    final newCount =
        int.tryParse(await native.getProperty('track-list/count')) ?? 0;
    var verified = false;
    for (var index = 0; index < newCount; index++) {
      if (await native.getProperty('track-list/$index/id') != id) continue;
      final path = await native.getProperty(
        'track-list/$index/external-filename',
      );
      verified =
          path == uri.toString() ||
          (uri.scheme == 'file' && path == uri.toFilePath());
      if (verified) break;
    }
    if (!verified) {
      await selectSubtitle(previous.isEmpty ? 'no' : previous);
      throw const FormatException('字幕未能加载，请检查文件格式或编码');
    }
    await selectSubtitle(id);
  }

  /// Captures the decoded native frame for the stage-0 rendering experiment.
  Future<Uint8List?> captureFrame() =>
      _player.screenshot(format: 'image/png', includeLibassSubtitles: true);

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (Platform.isIOS) _audioChannel.setMethodCallHandler(null);
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    try {
      await _player.dispose();
    } finally {
      try {
        if (Platform.isIOS) {
          await const MethodChannel('dev.orvex/audio-session')
              .invokeMethod<void>('deactivate');
        }
      } finally {
        await _frames.close();
        await _interruptions.close();
      }
    }
  }
}
