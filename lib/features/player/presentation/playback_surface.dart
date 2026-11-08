import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../design/glass.dart';
import '../../../design/orvex_theme.dart';
import '../application/playback_session.dart';
import '../domain/playback_defaults.dart';
import '../infrastructure/player_brightness.dart';
import '../../subtitles/domain/subtitle_models.dart';

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
    this.onBack,
    this.brightness,
    this.wide = false,
    this.title,
    this.onToggleWide,
  });
  final PlaybackSession session;
  final bool fullscreen;
  final VoidCallback onFullscreen;
  final VoidCallback onSubtitle;
  final VoidCallback? onBack;
  final PlayerBrightness? brightness;
  final bool wide;
  final String? title;
  final VoidCallback? onToggleWide;

  @override
  State<PlaybackSurface> createState() => _PlaybackSurfaceState();
}

class _PlaybackSurfaceState extends State<PlaybackSurface>
    with WidgetsBindingObserver {
  final _focus = FocusNode(debugLabel: 'Video controls');
  late final ThemeData _playerTheme = OrvexTheme.create(
    Brightness.dark,
    immersive: true,
  );
  late PlaybackSession session;
  late PlayerBrightness _display;
  Timer? _hideTimer;
  Timer? _feedbackTimer;
  Timer? _seekTimer;
  Object? _observedEngine;
  bool _visible = true;
  bool _locked = false;
  bool _wasPlaying = false;
  bool _foreground = true;
  bool _dragging = false;
  bool _seekPending = false;
  bool _menuOpen = false;
  bool _remaining = false;
  double? _dragSeconds;
  double? _level;
  bool _adjustingBrightness = false;
  double? _brightness;
  double _doubleTapX = 0;
  double? _previousRate;
  Object? _rateEngine;
  String? _feedback;
  int _brightnessRevision = 0;

  bool get _mobile =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;
  bool get _touchGestures => _mobile && session.currentDefaults.touchGestures;
  int get _step => session.currentDefaults.skipSeconds;
  bool get _interacting =>
      _dragging || _seekPending || _level != null || _previousRate != null;

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    session = widget.session;
    _display = widget.brightness ?? PlayerBrightness();
    _observedEngine = session.engine;
    WidgetsBinding.instance.addObserver(this);
    session.addListener(_playbackChanged);
    _playbackChanged();
    unawaited(_readBrightness());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_foreground) return;
      final focusedContext = FocusManager.instance.primaryFocus?.context;
      if (focusedContext?.findAncestorWidgetOfExactType<EditableText>() ==
          null) {
        _focus.requestFocus();
      }
    });
  }

  @override
  void didUpdateWidget(covariant PlaybackSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      _resetInteraction();
      session.removeListener(_playbackChanged);
      session = widget.session;
      _observedEngine = session.engine;
      _locked = false;
      _visible = true;
      session.addListener(_playbackChanged);
      _playbackChanged();
    }
  }

  Future<void> _readBrightness() async {
    final revision = ++_brightnessRevision;
    final value = await _display.read();
    if (mounted && _foreground && revision == _brightnessRevision) {
      setState(() => _brightness = value);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _resetInteraction();
      _brightnessRevision++;
      unawaited(_display.restore());
      if (mounted) setState(() => _visible = true);
    } else {
      unawaited(_readBrightness());
      _armHide();
    }
  }

  void _playbackChanged() {
    if (!identical(_observedEngine, session.engine)) {
      _resetInteraction();
      _observedEngine = session.engine;
      _locked = false;
      _visible = true;
    }
    if (!session.frame.playing) {
      _restoreRate();
      _hideTimer?.cancel();
      if (_wasPlaying) {
        _cancelSeek();
        _level = null;
        _feedback = null;
        _visible = true;
      }
    } else if (!_wasPlaying) {
      _armHide();
    }
    if (_seekPending &&
        _dragSeconds != null &&
        (session.frame.position.inMilliseconds - _dragSeconds! * 1000).abs() <
            1000) {
      _cancelSeek();
      _armHide();
    }
    _wasPlaying = session.frame.playing;
    if (mounted) setState(() {});
  }

  void _armHide() {
    _hideTimer?.cancel();
    if (!_foreground || !session.frame.playing || _menuOpen || _interacting) {
      return;
    }
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && session.frame.playing && !_menuOpen && !_interacting) {
        setState(() => _visible = false);
      }
    });
  }

  void _showControls() {
    if (!_locked) setState(() => _visible = true);
    _armHide();
  }

  void _showFeedback(String text, {bool persistent = false}) {
    _feedbackTimer?.cancel();
    setState(() => _feedback = text);
    if (!persistent) {
      _feedbackTimer = Timer(const Duration(milliseconds: 1100), () {
        if (mounted) setState(() => _feedback = null);
      });
    }
  }

  void _skip(int seconds) {
    if (!_foreground ||
        !session.ready ||
        session.frame.duration <= Duration.zero) {
      return;
    }
    final target = (session.frame.position + Duration(seconds: seconds))
        .inMilliseconds
        .clamp(0, session.frame.duration.inMilliseconds);
    unawaited(session.seek(Duration(milliseconds: target)));
    _showFeedback(seconds > 0 ? '快进 $seconds 秒' : '后退 ${-seconds} 秒');
    _showControls();
  }

  void _cancelSeek() {
    _seekTimer?.cancel();
    _seekPending = false;
    _dragging = false;
    _dragSeconds = null;
  }

  void _startSeek(double seconds) {
    if (!_foreground ||
        !session.ready ||
        session.frame.duration <= Duration.zero) {
      return;
    }
    _cancelSeek();
    _hideTimer?.cancel();
    setState(() {
      _dragging = true;
      _dragSeconds = seconds;
    });
  }

  void _commitSeek() {
    if (!_dragging || _dragSeconds == null) return;
    final target = Duration(milliseconds: (_dragSeconds! * 1000).round());
    setState(() {
      _dragging = false;
      _seekPending = true;
    });
    // Keep the target visible until the engine reports it, rather than briefly
    // snapping back to the old position while the asynchronous seek is pending.
    _seekTimer = Timer(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      setState(_cancelSeek);
      _armHide();
    });
    unawaited(session.seek(target));
  }

  void _restoreRate() {
    final rate = _previousRate;
    final engine = _rateEngine;
    _previousRate = null;
    _rateEngine = null;
    if (rate != null && identical(engine, session.engine)) {
      unawaited(session.setRate(rate));
    }
  }

  void _endLongPress() {
    if (_previousRate == null) return;
    _restoreRate();
    setState(() => _feedback = null);
    _armHide();
  }

  void _resetInteraction() {
    _hideTimer?.cancel();
    _feedbackTimer?.cancel();
    _cancelSeek();
    _restoreRate();
    _level = null;
    _feedback = null;
  }

  void _startLevel(bool brightness) {
    if (!_foreground || !session.ready || (brightness && _brightness == null)) {
      return;
    }
    _hideTimer?.cancel();
    _adjustingBrightness = brightness;
    _level = brightness ? _brightness! * 100 : session.frame.volume;
    _showFeedback(
      '${brightness ? '亮度' : '音量'} ${_level!.round()}%',
      persistent: true,
    );
  }

  void _updateLevel(double delta, double height) {
    if (_level == null) return;
    _level = (_level! - delta / height * 100).clamp(
      _adjustingBrightness ? 5.0 : 0.0,
      100.0,
    );
    if (_adjustingBrightness) {
      _brightness = _level! / 100;
      unawaited(_writeBrightness(_brightness!));
    } else {
      unawaited(session.setVolume(_level!));
    }
    _showFeedback(
      '${_adjustingBrightness ? '亮度' : '音量'} ${_level!.round()}%',
      persistent: true,
    );
  }

  Future<void> _writeBrightness(double value) async {
    final revision = _brightnessRevision;
    try {
      await _display.set(value);
    } catch (_) {
      if (!mounted || revision != _brightnessRevision) return;
      setState(() {
        _brightness = null;
        _level = null;
      });
      unawaited(_display.restore());
      _showFeedback('亮度调节不可用，请使用系统控制');
      _armHide();
    }
  }

  void _endLevel() {
    if (_level == null) return;
    setState(() => _level = null);
    if (_feedback != null) _showFeedback(_feedback!);
    _armHide();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // Only the video's own focus handles shortcuts. Sliders, buttons, menus and
    // text inputs keep their normal keyboard behavior.
    if (!node.hasPrimaryFocus ||
        _menuOpen ||
        _locked ||
        !_foreground ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft) {
      _skip(-_step);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _skip(_step);
    } else if (event is KeyDownEvent && key == LogicalKeyboardKey.space) {
      unawaited(session.togglePause());
      _showControls();
    } else if (event is KeyDownEvent &&
        (key == LogicalKeyboardKey.keyF ||
            (key == LogicalKeyboardKey.escape && widget.fullscreen))) {
      widget.onFullscreen();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    session.removeListener(_playbackChanged);
    _resetInteraction();
    _brightnessRevision++;
    unawaited(_display.restore());
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: _playerTheme,
    child: ListenableBuilder(
      listenable: session,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final frame = session.frame;
          final show = !_locked && _visible;
          final compact = constraints.maxWidth < 520;
          return Focus(
            focusNode: _focus,
            autofocus: true,
            onKeyEvent: _onKey,
            child: MouseRegion(
              onHover: (_) => _showControls(),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  GestureDetector(
                    key: const ValueKey('video-gestures'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      _focus.requestFocus();
                      if (!_locked) setState(() => _visible = !_visible);
                      _armHide();
                    },
                    onDoubleTapDown: _locked || !_touchGestures
                        ? null
                        : (details) => _doubleTapX = details.localPosition.dx,
                    onDoubleTap: _locked || (_mobile && !_touchGestures)
                        ? null
                        : () {
                            _focus.requestFocus();
                            if (!_mobile) {
                              widget.onFullscreen();
                            } else if (_doubleTapX <
                                constraints.maxWidth * 0.35) {
                              _skip(-_step);
                            } else if (_doubleTapX >
                                constraints.maxWidth * 0.65) {
                              _skip(_step);
                            }
                          },
                    onHorizontalDragStart: !_touchGestures || _locked
                        ? null
                        : (_) =>
                              _startSeek(frame.position.inMilliseconds / 1000),
                    onHorizontalDragUpdate: !_touchGestures || _locked
                        ? null
                        : (details) {
                            if (!_dragging) return;
                            setState(() {
                              _dragSeconds =
                                  (_dragSeconds! +
                                          details.delta.dx /
                                              constraints.maxWidth *
                                              90)
                                      .clamp(
                                        0,
                                        frame.duration.inMilliseconds / 1000,
                                      );
                            });
                          },
                    onHorizontalDragEnd: !_touchGestures || _locked
                        ? null
                        : (_) => _commitSeek(),
                    onHorizontalDragCancel: !_touchGestures || _locked
                        ? null
                        : () {
                            setState(_cancelSeek);
                            _armHide();
                          },
                    onLongPressStart: !_touchGestures || _locked
                        ? null
                        : (details) {
                            final x = details.localPosition.dx;
                            if (!_foreground ||
                                !session.ready ||
                                !session.frame.playing ||
                                x < constraints.maxWidth * 0.35 ||
                                x > constraints.maxWidth * 0.65) {
                              return;
                            }
                            _hideTimer?.cancel();
                            _previousRate = session.frame.rate;
                            _rateEngine = session.engine;
                            unawaited(session.setRate(2));
                            _showFeedback('临时 2 倍速', persistent: true);
                          },
                    onLongPressEnd: !_touchGestures || _locked
                        ? null
                        : (_) => _endLongPress(),
                    onLongPressCancel: !_touchGestures || _locked
                        ? null
                        : _endLongPress,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ColoredBox(
                          color: OrvexColors.player.background,
                          child:
                              session.engine?.buildVideo(
                                fit: session.pictureFit,
                              ) ??
                              const SizedBox(),
                        ),
                        if (_touchGestures && !_locked)
                          Row(
                            children: [
                              for (final brightness in [true, false])
                                Expanded(
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.translucent,
                                    onVerticalDragStart:
                                        brightness && _brightness == null
                                        ? null
                                        : (_) => _startLevel(brightness),
                                    onVerticalDragUpdate:
                                        brightness && _brightness == null
                                        ? null
                                        : (details) => _updateLevel(
                                            details.delta.dy,
                                            constraints.maxHeight,
                                          ),
                                    onVerticalDragEnd:
                                        brightness && _brightness == null
                                        ? null
                                        : (_) => _endLevel(),
                                    onVerticalDragCancel:
                                        brightness && _brightness == null
                                        ? null
                                        : _endLevel,
                                  ),
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
                  if (frame.buffering || session.loading)
                    const IgnorePointer(
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  Semantics(
                    hidden: !show,
                    container: true,
                    explicitChildNodes: true,
                    child: ExcludeFocus(
                      excluding: !show,
                      child: IgnorePointer(
                        ignoring: !show,
                        child: AnimatedOpacity(
                          alwaysIncludeSemantics: true,
                          key: const ValueKey('playback-controls'),
                          opacity: show ? 1 : 0,
                          duration: OrvexMetrics.duration(context),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              SafeArea(
                                top: widget.fullscreen,
                                bottom: widget.fullscreen,
                                left: widget.fullscreen,
                                right: widget.fullscreen,
                                minimum: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                child: Stack(
                                  children: [
                                    Align(
                                      alignment: Alignment.topCenter,
                                      child: _header(),
                                    ),
                                    Align(
                                      alignment: compact
                                          ? const Alignment(0, -0.12)
                                          : Alignment.center,
                                      child: _transport(compact),
                                    ),
                                    Align(
                                      alignment: Alignment.bottomCenter,
                                      child: _timeline(compact),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (_dragSeconds != null || _feedback != null)
                    IgnorePointer(
                      child: Align(
                        alignment: const Alignment(0, -0.3),
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 16),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: OrvexColors.player.surface.withValues(
                              alpha: 0.94,
                            ),
                            borderRadius: BorderRadius.circular(
                              OrvexMetrics.controlRadius,
                            ),
                          ),
                          child: Text(
                            _dragSeconds != null
                                ? '${formatTime(Duration(milliseconds: (_dragSeconds! * 1000).round()))} / ${formatTime(frame.duration)}'
                                : _feedback!,
                            key: const ValueKey('gesture-feedback'),
                            style: TextStyle(color: OrvexColors.player.text),
                          ),
                        ),
                      ),
                    ),
                  if (_locked)
                    SafeArea(
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: Padding(
                          padding: const EdgeInsets.all(8),
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
                    ),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );

  Widget _header() => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 900),
    child: GlassSurface(
      immersive: true,
      blur: true,
      subtle: true,
      radius: OrvexMetrics.controlRadius,
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            if (widget.onBack != null || widget.fullscreen)
              IconButton(
                tooltip: widget.fullscreen ? '退出全屏' : '返回媒体库',
                onPressed: widget.fullscreen
                    ? widget.onFullscreen
                    : widget.onBack,
                icon: const Icon(Icons.arrow_back_rounded, size: 20),
              ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                widget.title ?? session.media?.name ?? '正在播放',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: OrvexColors.player.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (widget.fullscreen && _mobile)
              IconButton(
                tooltip: '锁定屏幕',
                onPressed: () {
                  _resetInteraction();
                  setState(() => _locked = true);
                },
                icon: const Icon(Icons.lock_open_rounded, size: 20),
              ),
            IconButton(
              tooltip: '播放设置',
              onPressed: session.ready ? _showSettings : null,
              icon: const Icon(Icons.tune_rounded, size: 20),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _transport(bool compact) => GlassSurface(
    immersive: true,
    blur: true,
    subtle: true,
    radius: OrvexMetrics.pillRadius,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!compact)
          IconButton(
            tooltip: '后退 $_step 秒',
            onPressed: () => _skip(-_step),
            icon: Icon(switch (_step) {
              5 => Icons.replay_5_rounded,
              30 => Icons.replay_30_rounded,
              _ => Icons.replay_10_rounded,
            }, size: 23),
          ),
        IconButton(
          style: IconButton.styleFrom(
            foregroundColor: OrvexColors.player.text,
            minimumSize: Size(compact ? 48 : 56, compact ? 48 : 54),
          ),
          tooltip: session.frame.playing ? '暂停' : '播放',
          onPressed: session.ready
              ? () {
                  unawaited(session.togglePause());
                  _showControls();
                }
              : null,
          icon: Icon(
            session.frame.playing
                ? Icons.pause_rounded
                : Icons.play_arrow_rounded,
            size: compact ? 30 : 34,
          ),
        ),
        if (!compact)
          IconButton(
            tooltip: '快进 $_step 秒',
            onPressed: () => _skip(_step),
            icon: Icon(switch (_step) {
              5 => Icons.forward_5_rounded,
              30 => Icons.forward_30_rounded,
              _ => Icons.forward_10_rounded,
            }, size: 23),
          ),
      ],
    ),
  );

  Widget _timeline(bool compact) {
    final frame = session.frame;
    final duration = frame.duration.inMilliseconds.toDouble();
    final position = (_dragSeconds == null
        ? frame.position
        : Duration(milliseconds: (_dragSeconds! * 1000).round()));
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 920),
      child: GlassSurface(
        immersive: true,
        blur: true,
        subtle: true,
        radius: OrvexMetrics.controlRadius,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: SliderTheme(
          data: _playerTheme.sliderTheme.copyWith(
            trackHeight: _dragging ? 4 : 2,
            thumbShape: RoundSliderThumbShape(
              enabledThumbRadius: _dragging ? 7 : 4,
            ),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Listener(
                onPointerCancel: (_) {
                  setState(_cancelSeek);
                  _armHide();
                },
                child: SizedBox(
                  height: 28,
                  child: Slider(
                    key: const ValueKey('playback-progress'),
                    value: position.inMilliseconds.toDouble().clamp(
                      0,
                      duration > 0 ? duration : 1,
                    ),
                    max: duration > 0 ? duration : 1,
                    onChangeStart: (value) => _startSeek(value / 1000),
                    onChanged: session.ready && duration > 0
                        ? (value) {
                            if (_dragging) {
                              setState(() => _dragSeconds = value / 1000);
                            }
                          }
                        : null,
                    onChangeEnd: (_) => _commitSeek(),
                  ),
                ),
              ),
              SizedBox(
                height: 44,
                child: Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: OrvexColors.player.text,
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          alignment: Alignment.centerLeft,
                        ),
                        onPressed: () {
                          setState(() => _remaining = !_remaining);
                          _armHide();
                        },
                        child: Text(
                          '${formatTime(position)} / ${_remaining ? '-${formatTime(frame.duration - position)}' : formatTime(frame.duration)}',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ),
                    _speedMenu(),
                    if (!compact) ...[
                      _tracks(audio: true),
                      _tracks(audio: false),
                    ],
                    IconButton(
                      tooltip: frame.volume == 0 ? '取消静音' : '静音',
                      onPressed: () {
                        unawaited(
                          session.setVolume(frame.volume == 0 ? 100 : 0),
                        );
                        _showControls();
                      },
                      icon: Icon(
                        frame.volume == 0
                            ? Icons.volume_off_outlined
                            : Icons.volume_up_outlined,
                        size: 20,
                      ),
                    ),
                    if (!widget.fullscreen && widget.onToggleWide != null)
                      IconButton(
                        key: const ValueKey('playback-wide-mode'),
                        tooltip: widget.wide ? '窄屏模式 · 右侧显示列表' : '宽屏模式',
                        isSelected: widget.wide,
                        onPressed: session.ready
                            ? () {
                                widget.onToggleWide!();
                                _showControls();
                              }
                            : null,
                        icon: const Icon(Icons.width_wide_outlined, size: 21),
                        selectedIcon: const Icon(
                          Icons.width_normal_outlined,
                          size: 21,
                        ),
                      ),
                    IconButton(
                      tooltip: widget.fullscreen ? '退出全屏' : '全屏播放',
                      onPressed: session.ready ? widget.onFullscreen : null,
                      icon: Icon(
                        widget.fullscreen
                            ? Icons.fullscreen_exit_rounded
                            : Icons.fullscreen_rounded,
                        size: 22,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openedMenu() {
    _menuOpen = true;
    _hideTimer?.cancel();
  }

  void _closedMenu() {
    _menuOpen = false;
    if (mounted) _showControls();
  }

  Widget _speedMenu() => PopupMenuButton<double>(
    tooltip: '播放速度',
    onOpened: _openedMenu,
    onCanceled: _closedMenu,
    onSelected: (rate) {
      unawaited(session.setRate(rate));
      _closedMenu();
    },
    itemBuilder: (_) => [
      for (final rate in playbackRates)
        CheckedPopupMenuItem(
          value: rate,
          checked: session.frame.rate == rate,
          child: Text('$rate 倍速'),
        ),
    ],
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      child: Text(
        '${session.frame.rate}×',
        style: TextStyle(fontSize: 12, color: OrvexColors.player.text),
      ),
    ),
  );

  Future<void> _showSettings() async {
    _resetInteraction();
    _openedMenu();
    if (session.subtitleSupport != null && !session.findingSubtitles) {
      unawaited(session.refreshLocalSubtitles());
    }
    try {
      await showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        showDragHandle: true,
        backgroundColor: OrvexColors.of(context).surface,
        builder: (sheetContext) => ListenableBuilder(
          listenable: session,
          builder: (context, _) => SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('播放设置', style: TextStyle(fontSize: 18)),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Expanded(child: Text('音轨')),
                      _tracks(audio: true, inSettings: true),
                      const SizedBox(width: 12),
                      const Expanded(child: Text('字幕')),
                      _tracks(audio: false, inSettings: true),
                    ],
                  ),
                  if (session.subtitleSupport != null) _localSubtitleSettings(),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('当前画面适配'),
                    subtitle: const Text('填满画面可能裁切边缘。'),
                    trailing: PopupMenuButton<PlaybackFit>(
                      tooltip: '当前画面适配',
                      onSelected: session.setPictureFit,
                      itemBuilder: (_) => [
                        for (final fit in PlaybackFit.values)
                          CheckedPopupMenuItem(
                            value: fit,
                            checked: fit == session.pictureFit,
                            child: Text(fit.label),
                          ),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.all(OrvexMetrics.small),
                        child: Text(session.pictureFit.label),
                      ),
                    ),
                  ),
                  Text('音量 ${session.frame.volume.round()}%'),
                  Slider(
                    key: const ValueKey('settings-volume'),
                    value: session.frame.volume.clamp(0, 100),
                    max: 100,
                    onChanged: (value) => session.setVolume(value),
                  ),
                  if (_touchGestures)
                    Text(
                      _brightness == null ? '亮度请使用系统控制' : '左侧上下滑动调亮度，右侧上下滑动调音量',
                      style: TextStyle(
                        color: OrvexColors.of(context).secondary,
                        fontSize: 12,
                      ),
                    ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      widget.onSubtitle();
                    },
                    icon: const Icon(Icons.subtitles_outlined),
                    label: const Text('打开外挂字幕…'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    } finally {
      _closedMenu();
    }
  }

  Widget _tracks({required bool audio, bool inSettings = false}) {
    final frame = session.frame;
    final tracks = audio ? frame.audioTracks : frame.subtitleTracks;
    final selected = audio ? frame.audioTrackId : frame.subtitleTrackId;
    return PopupMenuButton<String>(
      tooltip: audio ? '音轨' : '字幕',
      icon: Icon(
        audio ? Icons.audiotrack_outlined : Icons.subtitles_outlined,
        size: 21,
      ),
      onOpened: _openedMenu,
      onCanceled: inSettings ? null : _closedMenu,
      onSelected: (id) {
        if (id == 'external') {
          widget.onSubtitle();
        } else if (audio) {
          unawaited(session.selectAudio(id));
        } else {
          unawaited(session.selectSubtitle(id));
        }
        if (!inSettings) _closedMenu();
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
        if (!audio && !inSettings) ...[
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'external', child: Text('打开外挂字幕…')),
        ],
      ],
    );
  }

  Widget _localSubtitleSettings() {
    final colors = OrvexColors.of(context);
    final candidates = session.localSubtitles;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        const Text('本地字幕', style: TextStyle(fontSize: 16)),
        const SizedBox(height: 6),
        Text(
          session.subtitleStatus,
          style: TextStyle(fontSize: 12, color: colors.secondary),
        ),
        if (session.subtitleIssue.isNotEmpty)
          Text(
            session.subtitleIssue,
            style: TextStyle(fontSize: 12, color: colors.warning),
          ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('智能匹配本地字幕'),
          subtitle: const Text(
            '完整名称优先，其次集数；多候选由你选择。手动选择和关闭字幕始终优先。',
            style: TextStyle(fontSize: 12),
          ),
          value: session.automaticSubtitles,
          onChanged: session.subtitleBusy
              ? null
              : (value) =>
                    unawaited(session.setAutomaticSubtitleMatching(value)),
        ),
        if (session.subtitleChoice.mode != SubtitleChoiceMode.automatic)
          TextButton(
            onPressed: () => unawaited(session.selectSubtitle('auto')),
            child: const Text('清除本集记忆，恢复自动选择'),
          ),
        Row(
          children: [
            Expanded(
              child: Text(
                session.media?.relativeImportPath != null
                    ? 'App 已导入的字幕'
                    : '视频同文件夹的字幕',
                style: TextStyle(fontSize: 12, color: colors.secondary),
              ),
            ),
            IconButton(
              tooltip: '重新扫描本地字幕',
              onPressed: session.findingSubtitles
                  ? null
                  : () => unawaited(session.refreshLocalSubtitles()),
              icon: const Icon(Icons.refresh_rounded, size: 20),
            ),
          ],
        ),
        if (session.subtitleBusy || session.findingSubtitles)
          const LinearProgressIndicator(minHeight: 2),
        if (session.subtitleScanIssue.isNotEmpty)
          Text(
            session.subtitleScanIssue,
            style: TextStyle(fontSize: 12, color: colors.warning),
          ),
        for (final candidate in candidates.take(20))
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              candidate.reference.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
            subtitle: Text(
              candidate.reason,
              style: const TextStyle(fontSize: 11),
            ),
            selected: session.selectedLocalSubtitle == candidate.reference.key,
            trailing: session.selectedLocalSubtitle == candidate.reference.key
                ? const Icon(Icons.check_rounded, size: 20)
                : null,
            onTap: () =>
                unawaited(session.chooseLocalSubtitle(candidate.reference)),
          ),
        if (candidates.length > 20)
          Text(
            '显示前 20 / ${candidates.length} 项，其他字幕可通过“打开外挂字幕”选择。',
            style: TextStyle(fontSize: 12, color: colors.secondary),
          ),
        const Divider(),
      ],
    );
  }
}
