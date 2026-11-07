import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/scheduler.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Owned by the thumbnail queue: at most one short-lived, audio-disabled
/// decoder. It never enters PlaybackSession or writes playback progress.
class MediaKitPreview {
  Future<({Uint8List bytes, int duration})> extract(Uri uri) async {
    final player = Player(
      configuration: const PlayerConfiguration(
        muted: true,
        bufferSize: 4 * 1024 * 1024,
      ),
    );
    try {
      final controller = VideoController(
        player,
        configuration: const VideoControllerConfiguration(
          width: 480,
          height: 270,
          enableHardwareAcceleration: false,
          hwdec: 'no',
        ),
      );
      SchedulerBinding.instance.ensureVisualUpdate();
      await controller.platform.future.timeout(const Duration(seconds: 10));
      final native = player.platform as NativePlayer;
      for (final property in {
        'aid': 'no',
        'sid': 'no',
        'hwdec': 'no',
      }.entries) {
        await native.setProperty(property.key, property.value);
      }
      final durationReady = player.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 12));
      // Observe errors immediately so an invalid file cannot leave an unhandled
      // duration Future while open is failing.
      unawaited(durationReady.then<void>((_) {}, onError: (Object _) {}));
      await player
          .open(Media(uri.toString()), play: false)
          .timeout(const Duration(seconds: 12));
      final duration = await durationReady;
      final seconds = (duration.inMilliseconds * 0.15 / 1000).clamp(0.2, 90.0);
      await player.seek(Duration(milliseconds: (seconds * 1000).round()));
      // The native output needs a real decoded frame. A permanently paused
      // output can report dimensions yet have no screenshot available.
      await player.play();
      final end = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final seeking = await native.getProperty('seeking');
        final position =
            double.tryParse(await native.getProperty('time-pos')) ?? -1;
        if (seeking == 'yes' || position < seconds - 0.25) continue;
        final bytes = await player.screenshot(includeLibassSubtitles: true);
        if (bytes != null && bytes.isNotEmpty) {
          return (bytes: bytes, duration: duration.inMilliseconds);
        }
      }
      throw StateError('Video frame unavailable');
    } finally {
      await player.dispose();
    }
  }
}
