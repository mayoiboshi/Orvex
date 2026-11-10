import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:orvex/features/player/presentation/audio_track_label.dart';

void main() {
  test(
    'uses real language, codec and channel layout without inventing profile',
    () {
      final label = audioTrackLabel(
        const MediaTrack(
          '1',
          'jpn',
          language: 'jpn',
          codec: 'aac',
          channelLayout: 'stereo',
          channelCount: 2,
        ),
      );
      expect(label.title, 'Japanese [日语] : AAC');
      expect(label.channels, '立体声');
      expect(label.title, isNot(contains('HE-AAC')));
    },
  );
  test('retains custom track title and raw unrecognized metadata', () {
    final label = audioTrackLabel(
      const MediaTrack(
        '2',
        '导演评论',
        language: 'eng',
        codec: 'codec-x',
        channelLayout: 'custom-layout',
      ),
    );
    expect(label.title, '导演评论 · English [英语] : codec-x');
    expect(label.channels, 'custom-layout');
  });
  test('uses numeric channels only when layout unavailable and leaves missing metadata absent', () {
    final numeric = audioTrackLabel(
      const MediaTrack('3', '轨道 3', channelCount: 2),
    );
    expect(numeric.title, '轨道 3');
    expect(numeric.channels, '2 声道');
    expect(numeric.channels, isNot('立体声'));
    final missing = audioTrackLabel(const MediaTrack('4', '轨道 4'));
    expect(missing.title, '轨道 4');
    expect(missing.channels, isNull);
    final undetermined = audioTrackLabel(
      const MediaTrack('5', 'und', language: 'und'),
    );
    expect(undetermined.title, '轨道 5');
    expect(undetermined.channels, isNull);
  });
  test('recognizes known channel layouts and language tags without assuming default locale', () {
    final label = audioTrackLabel(
      const MediaTrack(
        '6',
        'zh-Hans',
        language: 'zh-Hans',
        codec: 'eac3',
        channelLayout: '5.1',
      ),
    );
    expect(label.title, 'Chinese [中文] : E-AC-3');
    expect(label.channels, '5.1 声道');
  });
}
