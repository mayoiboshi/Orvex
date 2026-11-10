import '../domain/playback_engine.dart';

/// Labels only use metadata supplied by the media source; no codec profile is
/// inferred from a generic codec name or a channel layout from channel count.
class AudioTrackLabel {
  const AudioTrackLabel({required this.title, this.channels});
  final String title;
  final String? channels;
}

AudioTrackLabel audioTrackLabel(MediaTrack track) {
  final rawLanguage = track.language?.trim();
  final code = rawLanguage?.toLowerCase().split(RegExp('[-_]')).first;
  const languages = <String, (String, String)>{
    'ja': ('Japanese', '日语'),
    'jpn': ('Japanese', '日语'),
    'zh': ('Chinese', '中文'),
    'zho': ('Chinese', '中文'),
    'chi': ('Chinese', '中文'),
    'cmn': ('Chinese', '中文'),
    'en': ('English', '英语'),
    'eng': ('English', '英语'),
    'ko': ('Korean', '韩语'),
    'kor': ('Korean', '韩语'),
    'fr': ('French', '法语'),
    'fra': ('French', '法语'),
    'fre': ('French', '法语'),
    'es': ('Spanish', '西班牙语'),
    'spa': ('Spanish', '西班牙语'),
  };
  final lang = languages[code];
  final knownUnknown = code == 'und' || code == 'unknown' || code == '';
  final displayLanguage = lang == null
      ? (knownUnknown ? null : rawLanguage)
      : '${lang.$1} [${lang.$2}]';
  final source = track.label.trim();
  final generic = source.isEmpty || source == '轨道 ${track.id}';
  final sameLanguage =
      rawLanguage != null && source.toLowerCase() == rawLanguage.toLowerCase();
  final namedLanguage =
      lang != null &&
      (source.toLowerCase() == lang.$1.toLowerCase() || source == lang.$2);
  String title;
  if (generic || sameLanguage || namedLanguage) {
    title = displayLanguage?.isNotEmpty == true
        ? displayLanguage!
        : '轨道 ${track.id}';
  } else {
    title = source;
    if (displayLanguage != null && displayLanguage.isNotEmpty) {
      title = '$title · $displayLanguage';
    }
  }
  final rawCodec = track.codec?.trim();
  if (rawCodec != null && rawCodec.isNotEmpty) {
    const names = {
      'aac': 'AAC',
      'ac3': 'AC-3',
      'eac3': 'E-AC-3',
      'dts': 'DTS',
      'truehd': 'TrueHD',
      'alac': 'ALAC',
      'flac': 'FLAC',
      'mp3': 'MP3',
      'opus': 'Opus',
      'vorbis': 'Vorbis',
    };
    final codec = names[rawCodec.toLowerCase()] ?? rawCodec;
    title = '$title : $codec';
  }
  final rawLayout = track.channelLayout?.trim();
  final String? channels;
  if (rawLayout != null && rawLayout.isNotEmpty) {
    channels = switch (rawLayout.toLowerCase()) {
      'mono' => '单声道',
      'stereo' => '立体声',
      '5.1' => '5.1 声道',
      '7.1' => '7.1 声道',
      _ => rawLayout,
    };
  } else {
    final count = track.channelCount;
    channels = count != null && count > 0 ? '$count 声道' : null;
  }
  return AudioTrackLabel(title: title, channels: channels);
}
