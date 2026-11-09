import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../design/orvex_theme.dart';
import '../application/playback_session.dart';
import '../domain/playback_defaults.dart';
import '../infrastructure/player_brightness.dart';
import '../infrastructure/player_system_volume.dart';
import '../../subtitles/domain/subtitle_models.dart';
import 'volume_indicator.dart';

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
    this.brightness,
    this.systemVolume,
    this.wide = false,
    this.title,
    this.onToggleWide,
  });
  final PlaybackSession session;
  final bool fullscreen;
  final VoidCallback onFullscreen;
  final VoidCallback onSubtitle;
  final PlayerBrightness? brightness;
  final PlayerSystemVolume? systemVolume;
  final bool wide;
  final String? title;
  final VoidCallback? onToggleWide;

  @override
  State<PlaybackSurface> createState() => _PlaybackSurfaceState();
}

class _PlaybackSurfaceState extends State<PlaybackSurface>
    with WidgetsBindingObserver {
  static const _hideDelay = Duration(seconds: 3);
  static const _targetSize = 44.0;

  final _focus = FocusNode(debugLabel: 'Video controls');
  late final ThemeData _playerTheme = OrvexTheme.create(
    Brightness.dark,
    immersive: true,
  );
  late PlaybackSession session;
  late PlayerBrightness _display;
  late final PlayerSystemVolume _volume;
  final _systemLevel = ValueNotifier<double?>(null);
  final _volumeSteps = VolumeSteps();
  StreamSubscription<SystemVolumeReading>? _volumeSubscription;
  Timer? _volumeTimer;
  int _volumeRevision = 0;
  bool _volumePresented = false;
  bool _volumeVisible = false;
  double? _beforeMute;

  double get _outputVolume => _systemLevel.value ?? session.frame.volume;
  Timer? _hideTimer;
  Timer? _feedbackTimer;
  Timer? _seekTimer;
  Object? _observedEngine;
  bool _visible = true;
  bool _locked = false;
  bool _wasPlaying = false;
  bool _wasBuffering = false;
  bool _accessibleNavigation = false;
  bool _controlsHaveFocus = false;
  final _controlPointers = <int>{};
  bool _foreground = true;
  bool _dragging = false;
  bool _seekPending = false;
  bool _menuOpen = false;
  bool _remaining = false;
  double? _dragSeconds;
  double? _level;
  bool _adjustingBrightness = false;
  double? _brightness;
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
    _volume = widget.systemVolume ?? PlayerSystemVolume();
    _observedEngine = session.engine;
    WidgetsBinding.instance.addObserver(this);
    session.addListener(_playbackChanged);
    FocusManager.instance.addHighlightModeListener(_highlightModeChanged);
    _playbackChanged();
    unawaited(_readBrightness());
    unawaited(_watchVolume());
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    _accessibleNavigation = MediaQuery.accessibleNavigationOf(context);
    _armHide();
  }

  void _highlightModeChanged(FocusHighlightMode _) => _armHide();

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
      _wasPlaying = false;
      _wasBuffering = false;
      _armHide();
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
      _stopWatchingVolume();
      _brightnessRevision++;
      unawaited(_display.restore());
      if (mounted) setState(() => _visible = true);
    } else {
      unawaited(_readBrightness());
      unawaited(_watchVolume());
      _armHide();
    }
  }

  void _playbackChanged() {
    if (!identical(_observedEngine, session.engine)) {
      _resetInteraction();
      _observedEngine = session.engine;
      _locked = false;
      _visible = true;
      _wasPlaying = false;
      _wasBuffering = false;
      _armHide();
    }
    if (!session.frame.playing && !session.frame.buffering) {
      _restoreRate();
      _hideTimer?.cancel();
      if (_wasPlaying) {
        _level = null;
        _feedback = null;
        _visible = true;
      }
    } else if (session.frame.buffering) {
      _hideTimer?.cancel();
    } else if (!_wasPlaying || _wasBuffering) {
      _armHide();
    }
    if (_seekPending &&
        _dragSeconds != null &&
        (session.frame.position.inMilliseconds - _dragSeconds! * 1000).abs() <
            1000) {
      _cancelSeek();
      _armHide();
    }
    if (!session.frame.buffering) _wasPlaying = session.frame.playing;
    _wasBuffering = session.frame.buffering;
    _syncVolumePresentation();
    if (mounted) setState(() {});
  }

  Future<void> _watchVolume() async {
    if (!_foreground || _volumeSubscription != null) return;
    final revision = ++_volumeRevision;
    if (!await _volume.available() ||
        !mounted ||
        revision != _volumeRevision ||
        !_foreground) {
      return;
    }
    var receivedEvent = false;
    void receive(SystemVolumeReading reading) {
      if (!mounted || revision != _volumeRevision || !_foreground) return;
      receivedEvent = true;
      final previous = _systemLevel.value;
      final level = (reading.level * 100).clamp(0.0, 100.0);
      _volumeSteps.observe(reading);
      _systemLevel.value = level;
      if (reading.reset) _beforeMute = null;
      if (previous == null && session.ready && session.frame.volume != 100) {
        // Use one gain control once the system route becomes available.
        unawaited(session.setVolume(100));
      }
      _syncVolumePresentation();
      if (!reading.reset &&
          previous != null &&
          (previous - level).abs() > 0.01 &&
          session.frame.playing) {
        _showVolume(persistent: _level != null && !_adjustingBrightness);
      } else {
        setState(() {});
      }
    }

    _volumeSubscription = _volume.changes.listen(receive);
    // A second surface can overlap the old one during a route transition.
    // In that case the shared event stream does not send another initial value.
    final level = await _volume.currentLevel();
    if (!receivedEvent && level != null) {
      receive(SystemVolumeReading(level, reset: true));
    }
  }

  void _stopWatchingVolume() {
    _volumeRevision++;
    final subscription = _volumeSubscription;
    _volumeSubscription = null;
    unawaited(subscription?.cancel());
    _volumePresented = false;
  }

  void _syncVolumePresentation() {
    final active =
        _foreground &&
        _volumeSubscription != null &&
        _systemLevel.value != null &&
        session.frame.playing;
    if (_volumePresented == active) return;
    _volumePresented = active;
    unawaited(_volume.present(active));
  }

  void _showVolume({bool persistent = false}) {
    _volumeTimer?.cancel();
    setState(() => _volumeVisible = true);
    if (!persistent) {
      _volumeTimer = Timer(const Duration(milliseconds: 1100), () {
        if (mounted) setState(() => _volumeVisible = false);
      });
    }
  }

  Future<void> _setOutputVolume(double level, {bool dragging = false}) async {
    final engine = session.engine;
    final revision = _volumeRevision;
    if (_systemLevel.value != null) {
      final accepted = await _volume.set(level / 100);
      if (!mounted ||
          !_foreground ||
          revision != _volumeRevision ||
          !identical(engine, session.engine)) {
        return;
      }
      if (!accepted) {
        _showFeedback('音量调节不可用，请使用系统控制');
        return;
      }
    } else {
      await session.setVolume(level);
      if (!mounted || !_foreground || !identical(engine, session.engine)) {
        return;
      }
    }
    _showVolume(
      persistent: dragging && _level != null && !_adjustingBrightness,
    );
  }

  bool get _canAutoHide =>
      _foreground &&
      _visible &&
      !_locked &&
      session.frame.playing &&
      !session.frame.buffering &&
      !_menuOpen &&
      !_interacting &&
      _controlPointers.isEmpty &&
      !_accessibleNavigation &&
      !(_controlsHaveFocus &&
          FocusManager.instance.highlightMode ==
              FocusHighlightMode.traditional);

  void _armHide() {
    _hideTimer?.cancel();
    if (!_canAutoHide) return;
    _hideTimer = Timer(_hideDelay, () {
      if (mounted && _canAutoHide) setState(() => _visible = false);
    });
  }

  void _releaseControlPointer(PointerEvent event) {
    _controlPointers.remove(event.pointer);
    _armHide();
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

  void _togglePlayback() {
    if (!_foreground || !session.ready) return;
    unawaited(session.togglePause());
    _showControls();
  }

  void _startLongPress() {
    if (!_foreground ||
        !session.ready ||
        !session.frame.playing ||
        _previousRate != null) {
      return;
    }
    _hideTimer?.cancel();
    _previousRate = session.frame.rate;
    _rateEngine = session.engine;
    unawaited(session.setRate(2));
    _showFeedback('临时 2 倍速', persistent: true);
  }

  void _endLongPress() {
    if (_previousRate == null) return;
    _restoreRate();
    setState(() => _feedback = null);
    _armHide();
  }

  void _resetInteraction() {
    _hideTimer?.cancel();
    _controlPointers.clear();
    _feedbackTimer?.cancel();
    _volumeTimer?.cancel();
    _volumeVisible = false;
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
    _level = brightness ? _brightness! * 100 : _outputVolume;
    if (brightness) {
      _showFeedback('亮度 ${_level!.round()}%', persistent: true);
    } else {
      _showVolume(persistent: true);
    }
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
      _showFeedback('亮度 ${_level!.round()}%', persistent: true);
    } else {
      unawaited(_setOutputVolume(_level!, dragging: true));
    }
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
    if (_adjustingBrightness) {
      if (_feedback != null) _showFeedback(_feedback!);
    } else {
      _showVolume();
    }
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
      _togglePlayback();
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
    FocusManager.instance.removeHighlightModeListener(_highlightModeChanged);
    session.removeListener(_playbackChanged);
    _resetInteraction();
    _stopWatchingVolume();
    _systemLevel.dispose();
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
                    onDoubleTap: _locked || (_mobile && !_touchGestures)
                        ? null
                        : () {
                            _focus.requestFocus();
                            if (_mobile) {
                              _togglePlayback();
                            } else {
                              widget.onFullscreen();
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
                        : (_) => _startLongPress(),
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
                          child: Focus(
                            canRequestFocus: false,
                            onFocusChange: (focused) {
                              _controlsHaveFocus = focused;
                              _armHide();
                            },
                            child: Listener(
                              onPointerDown: (event) {
                                _controlPointers.add(event.pointer);
                                _hideTimer?.cancel();
                              },
                              onPointerUp: _releaseControlPointer,
                              onPointerCancel: _releaseControlPointer,
                              child: LayoutBuilder(builder: _controls),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (_dragSeconds != null || _feedback != null)
                    IgnorePointer(
                      child: Align(
                        alignment: Alignment.center,
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
                  if (_volumeVisible)
                    IgnorePointer(
                      child: SafeArea(
                        top: widget.fullscreen,
                        bottom: false,
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 260),
                              child: VolumeIndicator(
                                key: const ValueKey(
                                  'playback-volume-indicator',
                                ),
                                volume: _outputVolume,
                                steps: _volumeSteps.count,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (_locked) _screenLock(),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );

  Widget _controls(BuildContext context, BoxConstraints constraints) {
    final insets = widget.fullscreen
        ? MediaQuery.paddingOf(context)
        : EdgeInsets.zero;
    final padding = EdgeInsets.fromLTRB(
      insets.left + 8,
      insets.top,
      insets.right + 8,
      insets.bottom,
    );
    final width = constraints.maxWidth - padding.horizontal;
    final position = _progressPosition;
    final compactHeight =
        widget.fullscreen && constraints.maxHeight - insets.vertical < 200;
    return Stack(
      fit: StackFit.expand,
      children: [
        Align(
          alignment: Alignment.topCenter,
          child: _edge(
            top: true,
            padding: padding.copyWith(bottom: compactHeight ? 0 : 10),
            child: _header(compactHeight: compactHeight),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: _edge(
            key: const ValueKey('playback-bottom-controls'),
            top: false,
            padding: padding.copyWith(top: compactHeight ? 0 : 12),
            child: widget.fullscreen
                ? _fullscreenControls(context, width, position)
                : _inlineControls(
                    context,
                    width,
                    constraints.maxHeight,
                    position,
                  ),
          ),
        ),
        if (widget.fullscreen && _mobile && !_locked && !compactHeight)
          _screenLock(),
      ],
    );
  }

  Widget _edge({
    Key? key,
    required bool top,
    required EdgeInsets padding,
    required Widget child,
  }) => Stack(
    key: key,
    children: [
      Positioned.fill(
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: top ? Alignment.topCenter : Alignment.bottomCenter,
                end: top ? Alignment.bottomCenter : Alignment.topCenter,
                colors: [
                  OrvexColors.player.background.withValues(
                    alpha: top ? 0.86 : 0.92,
                  ),
                  OrvexColors.player.background.withValues(
                    alpha: top ? 0.53 : 0.62,
                  ),
                  OrvexColors.player.background.withValues(alpha: 0),
                ],
                stops: const [0, 0.60, 1],
              ),
            ),
          ),
        ),
      ),
      Padding(padding: padding, child: child),
    ],
  );

  Widget _header({required bool compactHeight}) => Row(
    children: [
      if (widget.fullscreen)
        IconButton(
          tooltip: '退出全屏',
          onPressed: widget.onFullscreen,
          icon: const Icon(Icons.arrow_back_rounded, size: 21),
        )
      else
        const SizedBox(width: 4),
      if (widget.fullscreen && _mobile && compactHeight && !_locked)
        _lockButton(),
      Expanded(
        child: IgnorePointer(
          child: Text(
            widget.title ?? session.media?.name ?? '正在播放',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: widget.fullscreen ? TextAlign.center : TextAlign.start,
            style: _playerTheme.textTheme.titleSmall,
          ),
        ),
      ),
      IconButton(
        tooltip: '播放设置',
        onPressed: session.ready ? _showSettings : null,
        icon: const Icon(Icons.tune_rounded, size: 21),
      ),
    ],
  );

  Widget _screenLock() => SafeArea(
    child: Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: _lockButton(),
      ),
    ),
  );

  Widget _lockButton() => IconButton(
    tooltip: _locked ? '解除锁定' : '锁定屏幕',
    style: IconButton.styleFrom(
      backgroundColor: OrvexColors.player.overlay,
      foregroundColor: OrvexColors.player.text,
      minimumSize: const Size.square(_targetSize),
    ),
    onPressed: () {
      if (_locked) {
        setState(() => _locked = false);
        _showControls();
      } else {
        _resetInteraction();
        setState(() => _locked = true);
      }
    },
    icon: Icon(
      _locked ? Icons.lock_rounded : Icons.lock_open_rounded,
      size: 20,
    ),
  );

  Widget _fullscreenControls(
    BuildContext context,
    double width,
    Duration position,
  ) {
    // Leave a clear center for transport even when the device is narrow.
    // The settings sheet retains the track controls when they do not fit.
    final directTracks = width >= 600;
    final narrow = width < 240;
    final tiny = width < 176;
    Widget transportButton(Widget child) => narrow
        ? SizedBox(width: _targetSize, height: _targetSize, child: child)
        : child;
    final transport = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        transportButton(_skipButton(forward: false)),
        transportButton(_playButton()),
        transportButton(_skipButton(forward: true)),
      ],
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _progressWithTimes(position, width),
        SizedBox(
          height: _targetSize + 4,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (width >= 260)
                Align(alignment: Alignment.centerLeft, child: _speedMenu()),
              Align(
                alignment: narrow ? Alignment.centerLeft : Alignment.center,
                child: tiny ? transportButton(_playButton()) : transport,
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (directTracks) ...[
                      _tracks(audio: true),
                      _tracks(audio: false),
                      _muteButton(),
                    ],
                    if (narrow)
                      SizedBox(
                        width: _targetSize,
                        height: _targetSize,
                        child: _fullscreenButton(),
                      )
                    else
                      _fullscreenButton(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _inlineControls(
    BuildContext context,
    double width,
    double height,
    Duration position,
  ) {
    final split =
        height >= 146 &&
        (width < 290 || MediaQuery.textScalerOf(context).scale(11) > 16);
    final tail = [
      if (widget.onToggleWide != null) _wideButton(),
      _fullscreenButton(),
    ];
    if (split) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _progressWithTimes(position, width),
          Row(children: [_playButton(), const Spacer(), ...tail]),
        ],
      );
    }
    return Row(
      children: [
        _playButton(),
        Expanded(child: _progressSlider(position)),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width * 0.38),
          child: _timeButton('${formatTime(position)} / $_durationLabel'),
        ),
        ...tail,
      ],
    );
  }

  Widget _progressWithTimes(Duration position, double width) => Row(
    children: [
      ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width * 0.27),
        child: Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            formatTime(position),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: OrvexColors.player.text),
          ),
        ),
      ),
      Expanded(child: _progressSlider(position)),
      ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width * 0.27),
        child: _timeButton(_durationLabel),
      ),
    ],
  );

  Widget _playButton() {
    final playing = session.frame.playing;
    return IconButton(
      tooltip: playing ? '暂停' : '播放',
      onPressed: session.ready ? _togglePlayback : null,
      icon: Icon(
        playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
        size: 27,
      ),
    );
  }

  Widget _skipButton({required bool forward}) {
    final seconds = forward ? _step : -_step;
    return IconButton(
      tooltip: forward ? '快进 $_step 秒' : '后退 $_step 秒',
      onPressed: session.ready ? () => _skip(seconds) : null,
      icon: Icon(switch ((forward, _step)) {
        (true, 5) => Icons.forward_5_rounded,
        (true, 30) => Icons.forward_30_rounded,
        (true, _) => Icons.forward_10_rounded,
        (false, 5) => Icons.replay_5_rounded,
        (false, 30) => Icons.replay_30_rounded,
        (false, _) => Icons.replay_10_rounded,
      }, size: 22),
    );
  }

  Widget _progressSlider(Duration position) {
    final duration = session.frame.duration.inMilliseconds.toDouble();
    return SliderTheme(
      data: _playerTheme.sliderTheme.copyWith(
        trackHeight: _dragging ? 4 : 2,
        thumbShape: RoundSliderThumbShape(
          enabledThumbRadius: _dragging ? 7 : 4,
        ),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
      ),
      child: Listener(
        onPointerCancel: (_) {
          setState(_cancelSeek);
          _armHide();
        },
        child: SizedBox(
          height: _targetSize,
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
    );
  }

  Duration get _progressPosition => _dragSeconds == null
      ? session.frame.position
      : Duration(milliseconds: (_dragSeconds! * 1000).round());

  String get _durationLabel {
    final duration = session.frame.duration;
    if (duration <= Duration.zero) return '—';
    if (!_remaining) return formatTime(duration);
    return '-${formatTime(duration - _progressPosition)}';
  }

  Widget _timeButton(String label) {
    return TextButton(
      style: TextButton.styleFrom(
        foregroundColor: OrvexColors.player.text,
        minimumSize: const Size(0, _targetSize),
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      onPressed: () {
        setState(() => _remaining = !_remaining);
        _armHide();
      },
      child: Text(
        label,
        style: const TextStyle(fontSize: 11),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _muteButton() {
    final muted = _outputVolume == 0;
    return IconButton(
      tooltip: muted ? '取消静音' : '静音',
      onPressed: () {
        if (!muted) _beforeMute = _outputVolume;
        final restored =
            _beforeMute ?? (_systemLevel.value == null ? 100.0 : 25.0);
        unawaited(_setOutputVolume(muted ? restored : 0));
        _showControls();
      },
      icon: Icon(
        muted ? Icons.volume_off_outlined : Icons.volume_up_outlined,
        size: 20,
      ),
    );
  }

  Widget _wideButton() => IconButton(
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
    selectedIcon: const Icon(Icons.width_normal_outlined, size: 21),
  );

  Widget _fullscreenButton() => IconButton(
    tooltip: widget.fullscreen ? '退出全屏' : '全屏播放',
    onPressed: session.ready ? widget.onFullscreen : null,
    icon: Icon(
      widget.fullscreen
          ? Icons.fullscreen_exit_rounded
          : Icons.fullscreen_rounded,
      size: 22,
    ),
  );

  void _openedMenu() {
    _menuOpen = true;
    _hideTimer?.cancel();
  }

  void _closedMenu() {
    _menuOpen = false;
    if (mounted) _showControls();
  }

  Widget _speedMenu({bool inSettings = false}) => PopupMenuButton<double>(
    tooltip: '播放速度',
    onOpened: inSettings ? null : _openedMenu,
    onCanceled: inSettings ? null : _closedMenu,
    onSelected: (rate) {
      unawaited(session.setRate(rate));
      if (!inSettings) _closedMenu();
    },
    itemBuilder: (_) => [
      for (final rate in playbackRates)
        CheckedPopupMenuItem(
          value: rate,
          checked: session.frame.rate == rate,
          child: Text('$rate 倍速'),
        ),
    ],
    child: ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 44, minHeight: _targetSize),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Center(
          widthFactor: 1,
          heightFactor: 1,
          child: Text(
            '${session.frame.rate}×',
            style: TextStyle(
              fontSize: 12,
              color: inSettings ? null : OrvexColors.player.text,
            ),
          ),
        ),
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
          listenable: Listenable.merge([session, _systemLevel]),
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
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text('播放速度'),
                      _speedMenu(inSettings: true),
                      _skipButton(forward: false),
                      _skipButton(forward: true),
                      _muteButton(),
                    ],
                  ),
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
                  Text(
                    '${_systemLevel.value == null ? '音量' : '系统音量'} ${_outputVolume.round()}%',
                  ),
                  Slider(
                    key: const ValueKey('settings-volume'),
                    value: _outputVolume.clamp(0, 100),
                    max: 100,
                    onChanged: (value) => unawaited(_setOutputVolume(value)),
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
    final label = audio ? '音轨' : '字幕';
    final icon = Icon(
      audio ? Icons.audiotrack_outlined : Icons.subtitles_outlined,
      size: 20,
    );
    return PopupMenuButton<String>(
      tooltip: label,
      icon: icon,
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
