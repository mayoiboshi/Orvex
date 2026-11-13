import 'package:flutter/material.dart';

import '../application/playback_session.dart';
import '../infrastructure/airplay_playback_engine.dart';

/// Presents Apple's real route picker after the local session is paused and
/// AVPlayer has prepared a silent candidate. No selection is guessed from the
/// picker closing; only the native external-video state can activate casting.
Future<void> showAirPlayRouteDialog(
  BuildContext context,
  PlaybackSession session,
  AirPlayPlaybackEngine engine,
) async {
  final prepared = await engine.prepareRoute();
  if (!context.mounted) {
    await engine.cancelRoute();
    return;
  }
  if (!prepared) {
    final message = engine.issue ?? '无法准备 AirPlay，播放已暂停';
    await engine.cancelRoute();
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
    return;
  }
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _AirPlayRouteDialog(session: session, engine: engine),
  );
  if (!engine.externalActive) await engine.cancelRoute();
}

class _AirPlayRouteDialog extends StatefulWidget {
  const _AirPlayRouteDialog({required this.session, required this.engine});
  final PlaybackSession session;
  final AirPlayPlaybackEngine engine;
  @override
  State<_AirPlayRouteDialog> createState() => _AirPlayRouteDialogState();
}

class _AirPlayRouteDialogState extends State<_AirPlayRouteDialog> {
  @override
  void initState() {
    super.initState();
    widget.session.addListener(_checkSession);
  }

  void _checkSession() {
    if (mounted && !identical(widget.session.engine, widget.engine)) {
      Navigator.of(context).maybePop();
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
          onPressed: () async {
            await widget.engine.cancelRoute();
            if (context.mounted) Navigator.of(context).pop();
          },
          child: Text(phase == AirPlayPhase.active ? '结束视频投屏' : '取消'),
        ),
        if (phase == AirPlayPhase.active)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('完成'),
          ),
      ],
    ),
  );
}
