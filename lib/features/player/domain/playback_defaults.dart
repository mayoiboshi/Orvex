enum ReopenBehavior {
  resume('继续上次进度'),
  ask('每次询问'),
  restart('从头开始');

  const ReopenBehavior(this.label);
  final String label;
}

enum PlaybackOpenIntent { ordinary, resume, restart }

enum PlaybackFit {
  contain('完整显示'),
  cover('填满画面');

  const PlaybackFit(this.label);
  final String label;
}

enum TrackLanguage {
  fileDefault('文件默认', []),
  chinese('中文', ['zh', 'zho', 'chi', 'cmn']),
  english('英语', ['en', 'eng']),
  japanese('日语', ['ja', 'jpn']),
  korean('韩语', ['ko', 'kor']),
  french('法语', ['fr', 'fra', 'fre']),
  spanish('西班牙语', ['es', 'spa']);

  const TrackLanguage(this.label, this.codes);
  final String label;
  final List<String> codes;

  bool matches(String? language) =>
      language != null &&
      codes.contains(language.trim().toLowerCase().split(RegExp('[-_]')).first);
}

const playbackRates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
const playbackSkipSteps = [5, 10, 30];

class PlaybackDefaults {
  const PlaybackDefaults({
    this.reopen = ReopenBehavior.resume,
    this.rate = 1,
    this.fit = PlaybackFit.contain,
    this.skipSeconds = 10,
    this.touchGestures = true,
    this.subtitleLanguage = TrackLanguage.fileDefault,
    this.audioLanguage = TrackLanguage.fileDefault,
  });

  final ReopenBehavior reopen;
  final double rate;
  final PlaybackFit fit;
  final int skipSeconds;
  final bool touchGestures;
  final TrackLanguage subtitleLanguage, audioLanguage;

  PlaybackDefaults copyWith({
    ReopenBehavior? reopen,
    double? rate,
    PlaybackFit? fit,
    int? skipSeconds,
    bool? touchGestures,
    TrackLanguage? subtitleLanguage,
    TrackLanguage? audioLanguage,
  }) => PlaybackDefaults(
    reopen: reopen ?? this.reopen,
    rate: rate ?? this.rate,
    fit: fit ?? this.fit,
    skipSeconds: skipSeconds ?? this.skipSeconds,
    touchGestures: touchGestures ?? this.touchGestures,
    subtitleLanguage: subtitleLanguage ?? this.subtitleLanguage,
    audioLanguage: audioLanguage ?? this.audioLanguage,
  );
}
