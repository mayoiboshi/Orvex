import 'package:flutter/material.dart';

import '../application/playback_session.dart';
import '../infrastructure/airplay_playback_engine.dart';
import '../infrastructure/dlna/dlna_playback_engine.dart';

final _openRoutes = Expando<bool>();

/// Presents Apple's real route picker after the local session is paused and
/// AVPlayer has prepared a silent candidate. No selection is guessed from the
/// picker closing; only the native external-video state can activate casting.
Future<void> showAirPlayRouteDialog(
  BuildContext context,
  PlaybackSession session,
  AirPlayPlaybackEngine engine,
) async {
  if (_openRoutes[engine] == true) return;
  _openRoutes[engine] = true;
  try {
    final existingRoute = engine.externalActive;
    var cancelRequested = false;
    if (!existingRoute) {
      final prepared = await engine.prepareRoute();
      if (!context.mounted) {
        if (prepared) await engine.cancelRoute();
        return;
      }
      if (!prepared) {
        final message = engine.issue ?? '无法准备 AirPlay，播放已暂停';
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(message)));
        }
        return;
      }
    }
    if (!context.mounted || !_ownsEngine(session, engine)) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AirPlayRouteDialog(
        session: session,
        engine: engine,
        onCancel: () {
          cancelRequested = true;
          return engine.cancelRoute();
        },
      ),
    );
    if (!existingRoute &&
        !cancelRequested &&
        !engine.externalActive &&
        _ownsEngine(session, engine)) {
      await engine.cancelRoute();
    }
  } finally {
    _openRoutes[engine] = false;
  }
}

bool _ownsEngine(PlaybackSession session, AirPlayPlaybackEngine engine) =>
    identical(session.engine, engine) ||
    (session.engine is DlnaPlaybackEngine &&
        identical((session.engine as DlnaPlaybackEngine).airplay, engine));

class _AirPlayRouteDialog extends StatefulWidget {
  const _AirPlayRouteDialog({
    required this.session,
    required this.engine,
    required this.onCancel,
  });
  final PlaybackSession session;
  final AirPlayPlaybackEngine engine;
  final Future<void> Function() onCancel;
  @override
  State<_AirPlayRouteDialog> createState() => _AirPlayRouteDialogState();
}

class _AirPlayRouteDialogState extends State<_AirPlayRouteDialog> {
  bool _closing = false;
  bool _ending = false;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_checkSession);
  }

  void _checkSession() {
    if (mounted && !_ownsEngine(widget.session, widget.engine)) _closeDialog();
  }

  void _closeDialog() {
    if (!mounted || _closing) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    _closing = true;
    final navigator = Navigator.of(context);
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  Future<void> _endRoute() async {
    if (_ending || _closing) return;
    setState(() => _ending = true);
    try {
      await widget.onCancel();
      if (mounted) _closeDialog();
    } finally {
      if (mounted) setState(() => _ending = false);
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_checkSession);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<AirPlayPhase>(
    valueListenable: widget.engine.phaseNotifier,
    builder: (context, phase, _) => AlertDialog(
      title: const Text('AirPlay 视频投屏'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(switch (phase) {
            AirPlayPhase.preparing => '正在准备视频，本地播放已暂停。',
            AirPlayPhase.choosing => '请选择 AirPlay 视频设备，本地播放已暂停。本次投屏不会加载外挂字幕；内嵌音轨和字幕受设备及格式限制，暂不能在此切换，投屏按 1× 倍速播放。',
            AirPlayPhase.connecting => '正在连接视频设备，请稍候。',
            AirPlayPhase.active => '已连接 AirPlay 视频设备。本次投屏不会加载外挂字幕；内嵌音轨和字幕受设备及格式限制，暂不能在此切换，投屏按 1× 倍速播放。结束视频投屏后，音频可能仍由系统路由到 AirPlay 设备。',
            AirPlayPhase.failed => widget.engine.issue ?? '连接失败，播放已暂停。',
            AirPlayPhase.idle => '播放已暂停。',
          }),
          if (phase == AirPlayPhase.choosing ||
              phase == AirPlayPhase.connecting)
            const SizedBox(
              width: 64,
              height: 64,
              child: UiKitView(viewType: 'dev.orvex/airplay-picker'),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _ending ? null : _endRoute,
          child: Text(phase == AirPlayPhase.active ? '结束视频投屏' : '取消'),
        ),
        if (phase == AirPlayPhase.active)
          TextButton(
            onPressed: _ending ? null : _closeDialog,
            child: const Text('完成'),
          ),
      ],
    ),
  );
}
