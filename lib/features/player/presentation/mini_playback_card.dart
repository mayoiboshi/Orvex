import 'dart:async';

import 'package:flutter/material.dart';

import '../../../design/glass.dart';
import '../../../design/orvex_theme.dart';
import '../application/playback_session.dart';
import 'playback_surface.dart' show formatTime;

class MiniPlaybackCard extends StatelessWidget {
  const MiniPlaybackCard({
    super.key,
    required this.session,
    required this.title,
    required this.artwork,
    required this.onExpand,
  });

  final PlaybackSession session;
  final String title;
  final Widget artwork;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return GlassSurface(
      radius: OrvexMetrics.cardRadius,
      padding: const EdgeInsets.all(OrvexMetrics.small),
      child: Row(
        children: [
          SizedBox(
            width: OrvexMetrics.hitSize,
            height: OrvexMetrics.hitSize,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(OrvexMetrics.smallRadius),
              child: artwork,
            ),
          ),
          const SizedBox(width: OrvexMetrics.small),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.titleSmall,
                ),
                ListenableBuilder(
                  listenable: session,
                  builder: (context, _) {
                    final frame = session.frame;
                    final status = session.loading
                        ? '正在打开'
                        : !session.ready
                        ? '暂不可播放'
                        : frame.completed
                        ? '已播放完毕'
                        : frame.playing && frame.buffering
                        ? '正在缓冲'
                        : frame.playing
                        ? '正在播放'
                        : '已暂停';
                    return Text(
                      [
                        status,
                        if (session.ready)
                          '${formatTime(frame.position)}'
                              '${frame.duration > Duration.zero ? ' / ${formatTime(frame.duration)}' : ''}',
                      ].join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.labelSmall,
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(width: OrvexMetrics.small),
          ListenableBuilder(
            listenable: session,
            builder: (context, _) => GlassIconButton(
              tooltip: session.frame.playing ? '暂停视频' : '播放视频',
              icon: session.frame.playing
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
              prominent: true,
              onPressed: session.ready
                  ? () => unawaited(session.togglePause())
                  : null,
            ),
          ),
          const SizedBox(width: OrvexMetrics.small),
          GlassIconButton(
            tooltip: '展开播放器',
            icon: Icons.open_in_full_rounded,
            onPressed: onExpand,
          ),
        ],
      ),
    );
  }
}
