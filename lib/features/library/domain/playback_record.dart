import '../../player/domain/playback_engine.dart';

class PlaybackRecord {
  const PlaybackRecord({
    required this.media,
    required this.position,
    required this.duration,
    required this.updatedAt,
    this.completed = false,
  });

  final LocalMedia media;
  final Duration position;
  final Duration duration;
  final DateTime? updatedAt;
  final bool completed;

  bool get canContinue => !completed && position > Duration.zero;
  double get progress => duration.inMilliseconds <= 0
      ? 0
      : (position.inMilliseconds / duration.inMilliseconds).clamp(0, 1);
}
