import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../application/playback_session.dart';

String formatTime(Duration value) {
  final seconds = value.inSeconds.clamp(0, 1 << 32);
  final minutes = (seconds ~/ 60 % 60).toString().padLeft(2, '0');
  final remainder = (seconds % 60).toString().padLeft(2, '0');
  return seconds >= 3600
      ? '${seconds ~/ 3600}:$minutes:$remainder'
      : '$minutes:$remainder';
}

class PlaybackSurface extends StatefulWidget {
  const PlaybackSurface({
    super.key,
    required this.session,
    required this.fullscreen,
    required this.onFullscreen,
    required this.onSubtitle,
  });
  final PlaybackSession session;
  final bool fullscreen;
  final VoidCallback onFullscreen;
  final VoidCallback onSubtitle;

  @override
  State<PlaybackSurface> createState() => _PlaybackSurfaceState();
}

class _PlaybackSurfaceState extends State<PlaybackSurface> {
  Timer? _hideTimer;
  Timer? _feedbackTimer;
  bool _visible = true;
  bool _locked = false;
  bool _wasPlaying = false;
  double? _dragSeconds;
  double _dragOrigin = 0;
  double _doubleTapX = 0;
  double? _previousRate;
  String? _feedback;

  PlaybackSession get session => widget.session;

  @override
  void initState() {
    super.initState();
    session.addListener(_playbackChanged);
    _playbackChanged();
  }

  void _playbackChanged() {
    if (session.frame.playing && !_wasPlaying) _armHide();
    if (!session.frame.playing) {
      _hideTimer?.cancel();
      if (_wasPlaying && mounted) setState(() => _visible = true);
    }
    _wasPlaying = session.frame.playing;
  }

  void _armHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && session.frame.playing && _dragSeconds == null) {
        setState(() => _visible = false);
      }
    });
  }

  void _showControls() {
    setState(() => _visible = true);
    _armHide();
  }

  void _showFeedback(String text) {
    _feedbackTimer?.cancel();
    setState(() => _feedback = text);
    _feedbackTimer = Timer(const Duration(milliseconds: 1100), () {
      if (mounted) setState(() => _feedback = null);
    });
  }

  void _skip(int seconds) {
    unawaited(
      session.seek(session.frame.position + Duration(seconds: seconds)),
    );
    _showFeedback(seconds > 0 ? '快进 $seconds 秒' : '后退 ${-seconds} 秒');
    _showControls();
  }

  @override
  void dispose() {
    session.removeListener(_playbackChanged);
    _hideTimer?.cancel();
    _feedbackTimer?.cancel();
    // A view change during long press must not leave playback stuck at 2x.
    if (_previousRate case final double rate) unawaited(session.setRate(rate));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final show = !_locked && _visible;
        final compact = constraints.maxWidth < 520;
        final frame = session.frame;
        final duration = frame.duration.inMilliseconds
            .toDouble()
            .clamp(1.0, double.infinity)
            .toDouble();
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.space): () =>
                session.togglePause(),
            const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                _skip(-10),
            const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                _skip(10),
            const SingleActivator(LogicalKeyboardKey.escape): widget.fullscreen
                ? widget.onFullscreen
                : () {},
            const SingleActivator(LogicalKeyboardKey.keyF): widget.onFullscreen,
          },
          child: Focus(
            autofocus: true,
            child: MouseRegion(
              onHover: (_) {
                if (!_locked) _showControls();
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      if (!_locked) setState(() => _visible = !_visible);
                      _armHide();
                    },
                    onDoubleTapDown: _locked
                        ? null
                        : (details) => _doubleTapX = details.localPosition.dx,
                    onDoubleTap: _locked
                        ? null
                        : () {
                            if (_doubleTapX < constraints.maxWidth * 0.4) {
                              _skip(-10);
                            } else if (_doubleTapX >
                                constraints.maxWidth * 0.6) {
                              _skip(10);
                            } else {
                              unawaited(session.togglePause());
                            }
                          },
                    onHorizontalDragStart: _locked
                        ? null
                        : (_) {
                            _hideTimer?.cancel();
                            _dragOrigin = frame.position.inMilliseconds / 1000;
                            setState(() => _dragSeconds = _dragOrigin);
                          },
                    onHorizontalDragUpdate: _locked
                        ? null
                        : (details) {
                            setState(
                              () => _dragSeconds =
                                  ((_dragSeconds ?? _dragOrigin) +
                                          details.delta.dx /
                                              constraints.maxWidth *
                                              90)
                                      .clamp(
                                        0,
                                        frame.duration.inMilliseconds / 1000,
                                      ),
                            );
                          },
                    onHorizontalDragEnd: _locked
                        ? null
                        : (_) {
                            if (_dragSeconds case final double seconds) {
                              unawaited(
                                session.seek(
                                  Duration(
                                    milliseconds: (seconds * 1000).round(),
                                  ),
                                ),
                              );
                            }
                            setState(() => _dragSeconds = null);
                            _armHide();
                          },
                    onHorizontalDragCancel: () =>
                        setState(() => _dragSeconds = null),
                    onLongPressStart: _locked
                        ? null
                        : (_) {
                            _previousRate = frame.rate;
                            unawaited(session.setRate(2));
                            _showFeedback('2 倍速播放');
                          },
                    onLongPressEnd: _locked
                        ? null
                        : (_) {
                            unawaited(session.setRate(_previousRate ?? 1));
                            _previousRate = null;
                          },
                    child: ColoredBox(
                      color: Colors.black,
                      child: session.engine?.buildVideo() ?? const SizedBox(),
                    ),
                  ),
                  if (show)
                    const IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black87,
                              Colors.transparent,
                              Colors.transparent,
                              Colors.black87,
                            ],
                            stops: [0, 0.3, 0.65, 1],
                          ),
                        ),
                      ),
                    ),
                  if (frame.buffering || session.loading)
                    const Center(child: CircularProgressIndicator()),
                  if (_dragSeconds != null || _feedback != null)
                    Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(
                          _dragSeconds != null
                              ? '${formatTime(Duration(milliseconds: (_dragSeconds! * 1000).round()))} / ${formatTime(frame.duration)}'
                              : _feedback!,
                          style: const TextStyle(
                            fontSize: 18,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  if (show) ...[
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: Container(
                        padding: EdgeInsets.fromLTRB(
                          widget.fullscreen
                              ? MediaQuery.paddingOf(context).left + 12
                              : 12,
                          widget.fullscreen
                              ? MediaQuery.paddingOf(context).top + 8
                              : 8,
                          widget.fullscreen
                              ? MediaQuery.paddingOf(context).right + 12
                              : 12,
                          28,
                        ),
                        child: Row(
                          children: [
                            if (widget.fullscreen)
                              IconButton(
                                tooltip: '退出全屏',
                                onPressed: widget.onFullscreen,
                                icon: const Icon(Icons.arrow_back_rounded),
                              ),
                            Expanded(
                              child: Text(
                                session.media?.name ?? '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 14),
                              ),
                            ),
                            if (widget.fullscreen)
                              IconButton(
                                tooltip: '锁定屏幕',
                                onPressed: () => setState(() => _locked = true),
                                icon: const Icon(Icons.lock_open_rounded),
                              ),
                          ],
                        ),
                      ),
                    ),
                    Align(
                      alignment: compact && !widget.fullscreen
                          ? const Alignment(0, -0.25)
                          : Alignment.center,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: '后退 10 秒',
                            onPressed: () => _skip(-10),
                            icon: const Icon(Icons.replay_10_rounded, size: 30),
                          ),
                          const SizedBox(width: 20),
                          IconButton.filledTonal(
                            tooltip: frame.playing ? '暂停' : '播放',
                            onPressed: session.ready
                                ? () {
                                    unawaited(session.togglePause());
                                    _showControls();
                                  }
                                : null,
                            iconSize: compact ? 32 : 42,
                            icon: Icon(
                              frame.playing
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                            ),
                          ),
                          const SizedBox(width: 20),
                          IconButton(
                            tooltip: '快进 10 秒',
                            onPressed: () => _skip(10),
                            icon: const Icon(
                              Icons.forward_10_rounded,
                              size: 30,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: Container(
                        padding: EdgeInsets.fromLTRB(
                          widget.fullscreen
                              ? MediaQuery.paddingOf(context).left + 12
                              : 12,
                          0,
                          widget.fullscreen
                              ? MediaQuery.paddingOf(context).right + 12
                              : 12,
                          widget.fullscreen
                              ? MediaQuery.paddingOf(context).bottom + 8
                              : 4,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              height: 24,
                              child: Slider(
                                value:
                                    ((_dragSeconds == null
                                                ? frame.position.inMilliseconds
                                                : _dragSeconds! * 1000)
                                            .toDouble())
                                        .clamp(0, duration),
                                max: duration,
                                onChangeStart: (_) => _hideTimer?.cancel(),
                                onChanged: frame.duration > Duration.zero
                                    ? (value) => setState(
                                        () => _dragSeconds = value / 1000,
                                      )
                                    : null,
                                onChangeEnd: (value) {
                                  unawaited(
                                    session.seek(
                                      Duration(milliseconds: value.round()),
                                    ),
                                  );
                                  setState(() => _dragSeconds = null);
                                  _armHide();
                                },
                              ),
                            ),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${formatTime(frame.position)} / ${formatTime(frame.duration)}',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                                PopupMenuButton<double>(
                                  tooltip: '播放速度',
                                  onOpened: () => _hideTimer?.cancel(),
                                  onCanceled: _armHide,
                                  onSelected: (rate) {
                                    unawaited(session.setRate(rate));
                                    _showControls();
                                  },
                                  itemBuilder: (_) => [
                                    for (final rate in [
                                      0.5,
                                      0.75,
                                      1.0,
                                      1.25,
                                      1.5,
                                      2.0,
                                    ])
                                      CheckedPopupMenuItem(
                                        value: rate,
                                        checked: frame.rate == rate,
                                        child: Text('$rate 倍速'),
                                      ),
                                  ],
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 12,
                                    ),
                                    child: Text(
                                      '${frame.rate}×',
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                                ),
                                _tracks(audio: true),
                                _tracks(audio: false),
                                IconButton(
                                  tooltip: frame.volume == 0 ? '取消静音' : '静音',
                                  onPressed: () => session.setVolume(
                                    frame.volume == 0 ? 100 : 0,
                                  ),
                                  icon: Icon(
                                    frame.volume == 0
                                        ? Icons.volume_off_outlined
                                        : Icons.volume_up_outlined,
                                    size: 21,
                                  ),
                                ),
                                IconButton(
                                  tooltip: widget.fullscreen ? '退出全屏' : '全屏播放',
                                  onPressed: widget.onFullscreen,
                                  icon: Icon(
                                    widget.fullscreen
                                        ? Icons.fullscreen_exit_rounded
                                        : Icons.fullscreen_rounded,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  if (_locked)
                    Positioned(
                      left: 20 + MediaQuery.paddingOf(context).left,
                      top: 20,
                      child: SafeArea(
                        child: IconButton.filledTonal(
                          tooltip: '解除锁定',
                          onPressed: () {
                            setState(() => _locked = false);
                            _showControls();
                          },
                          icon: const Icon(Icons.lock_rounded),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );

  Widget _tracks({required bool audio}) {
    final frame = session.frame;
    final tracks = audio ? frame.audioTracks : frame.subtitleTracks;
    final selected = audio ? frame.audioTrackId : frame.subtitleTrackId;
    return PopupMenuButton<String>(
      tooltip: audio ? '音轨' : '字幕',
      icon: Icon(
        audio ? Icons.audiotrack_outlined : Icons.subtitles_outlined,
        size: 21,
      ),
      onOpened: () => _hideTimer?.cancel(),
      onCanceled: _armHide,
      onSelected: (id) {
        if (id == 'external') {
          widget.onSubtitle();
        } else if (audio) {
          unawaited(session.selectAudio(id));
        } else {
          unawaited(session.selectSubtitle(id));
        }
        _showControls();
      },
      itemBuilder: (_) => [
        CheckedPopupMenuItem(
          value: 'auto',
          checked: session.error == null && selected == 'auto',
          child: const Text('自动选择'),
        ),
        CheckedPopupMenuItem(
          value: 'no',
          checked: session.error == null && selected == 'no',
          child: Text(audio ? '关闭音轨' : '关闭字幕'),
        ),
        for (final track in tracks)
          CheckedPopupMenuItem(
            value: track.id,
            checked: session.error == null && selected == track.id,
            child: Text(track.label),
          ),
        if (!audio) ...[
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'external', child: Text('打开外挂字幕…')),
        ],
      ],
    );
  }
}
