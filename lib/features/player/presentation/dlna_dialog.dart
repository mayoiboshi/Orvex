import 'package:flutter/material.dart';

import '../infrastructure/dlna/dlna_playback_engine.dart';

Widget dlnaIssueMessage(String? issue) =>
    Text(issue ?? '无法确认设备状态。请在接收设备上停止或关闭播放，再重启应用；设备已缓冲的视频可能仍会播放。');

Future<void> showDlnaDialog(BuildContext context, DlnaPlaybackEngine engine) =>
    showDialog<void>(context: context, builder: (_) => _Dialog(engine));

class _Dialog extends StatefulWidget {
  const _Dialog(this.engine);
  final DlnaPlaybackEngine engine;
  @override
  State<_Dialog> createState() => _DialogState();
}

class _DialogState extends State<_Dialog> {
  final address = TextEditingController();
  String? message;
  bool busy = false;
  @override
  void dispose() {
    address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<DlnaPhase>(
    valueListenable: widget.engine.phase,
    builder: (context, phase, _) => AlertDialog(
      title: const Text('DLNA 视频投屏'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '输入接收设备的局域网 IPv4 地址；设备与本机须连接同一局域网。外挂字幕不会随投送，格式和内嵌轨道支持取决于接收设备；无法识别容器时将以通用格式发送。',
            ),
            if (phase == DlnaPhase.idle)
              TextField(
                controller: address,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '设备 IPv4 地址',
                  hintText: '例如 192.168.1.10',
                ),
              ),
            if (phase == DlnaPhase.active) const Text('已发送给设备，请在接收设备确认画面。'),
            if (phase == DlnaPhase.uncertain)
              dlnaIssueMessage(widget.engine.mediaSelectionIssue),
            if (message != null) Text(message!),
            if (busy) const LinearProgressIndicator(),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        if (phase == DlnaPhase.idle)
          TextButton(
            onPressed: busy
                ? null
                : () async {
                    setState(() => busy = true);
                    try {
                      await widget.engine.connect(address.text);
                    } catch (e) {
                      message = '连接失败：$e';
                    } finally {
                      if (mounted) setState(() => busy = false);
                    }
                  },
            child: const Text('连接'),
          ),
        if (phase == DlnaPhase.active)
          TextButton(
            onPressed: busy
                ? null
                : () async {
                    setState(() => busy = true);
                    try {
                      await widget.engine.disconnect();
                    } catch (e) {
                      message = '停止失败：$e';
                    } finally {
                      if (mounted) setState(() => busy = false);
                    }
                  },
            child: const Text('结束投屏'),
          ),
      ],
    ),
  );
}
