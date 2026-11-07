import 'package:flutter/material.dart';

import '../../../design/orvex_theme.dart';

/// Presentation only; playback commands and preference writes stay in PlayerPage.
class WatchInformation extends StatelessWidget {
  const WatchInformation({
    super.key,
    required this.title,
    required this.episode,
    required this.progress,
    required this.linked,
    required this.onMetadata,
    required this.onPrevious,
    required this.onNext,
    required this.autoNext,
    required this.onAutoNext,
  });

  final String title, episode, progress;
  final bool linked, autoNext;
  final VoidCallback onMetadata;
  final VoidCallback? onPrevious, onNext;
  final ValueChanged<bool> onAutoNext;

  @override
  Widget build(BuildContext context) {
    final colors = OrvexColors.of(context);
    final text = Theme.of(context).textTheme;
    final information = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: text.titleLarge,
        ),
        const SizedBox(height: OrvexMetrics.small),
        Wrap(
          spacing: OrvexMetrics.gap,
          runSpacing: OrvexMetrics.small,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (episode.isNotEmpty)
              Text(
                episode,
                style: text.labelMedium?.copyWith(
                  color: colors.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            Text(
              progress,
              style: text.bodySmall?.copyWith(color: colors.secondary),
            ),
          ],
        ),
        const SizedBox(height: OrvexMetrics.gap),
        TextButton(
          key: const ValueKey('watch-metadata'),
          onPressed: onMetadata,
          style: TextButton.styleFrom(
            foregroundColor: colors.secondary,
            backgroundColor: colors.surface,
            minimumSize: const Size(0, OrvexMetrics.hitSize),
            padding: const EdgeInsets.symmetric(horizontal: OrvexMetrics.gap),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(OrvexMetrics.smallRadius),
              side: BorderSide(
                color: colors.divider.withValues(alpha: 0.7),
                width: 0.7,
              ),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.auto_awesome_outlined, size: 16, color: colors.accent),
              const SizedBox(width: OrvexMetrics.small),
              Flexible(
                child: Text(
                  linked ? 'Bangumi · 查看作品资料' : 'Bangumi · 关联番剧资料',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelMedium,
                ),
              ),
              const SizedBox(width: OrvexMetrics.small),
              const Icon(Icons.chevron_right_rounded, size: 16),
            ],
          ),
        ),
      ],
    );
    final sequence = DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(OrvexMetrics.controlRadius),
        border: Border.all(
          color: colors.divider.withValues(alpha: 0.7),
          width: 0.7,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '上一集',
              onPressed: onPrevious,
              icon: const Icon(
                Icons.skip_previous_rounded,
                size: OrvexMetrics.iconSize,
              ),
            ),
            IconButton(
              tooltip: '下一集',
              onPressed: onNext,
              icon: const Icon(
                Icons.skip_next_rounded,
                size: OrvexMetrics.iconSize,
              ),
            ),
          ],
        ),
      ),
    );
    final automatic = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '自动下一集',
          style: text.labelMedium?.copyWith(color: colors.secondary),
        ),
        const SizedBox(width: OrvexMetrics.small),
        Semantics(
          label: '自动下一集',
          child: Switch.adaptive(
            key: const ValueKey('watch-auto-next'),
            value: autoNext,
            onChanged: onAutoNext,
          ),
        ),
      ],
    );
    return Padding(
      key: const ValueKey('watch-information'),
      padding: const EdgeInsets.all(OrvexMetrics.page),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= 560 &&
              MediaQuery.textScalerOf(context).scale(14) <= 21) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: information),
                const SizedBox(width: OrvexMetrics.section),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    sequence,
                    const SizedBox(height: OrvexMetrics.small),
                    automatic,
                  ],
                ),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              information,
              const SizedBox(height: OrvexMetrics.space),
              Wrap(
                spacing: OrvexMetrics.space,
                runSpacing: OrvexMetrics.small,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [sequence, automatic],
              ),
            ],
          );
        },
      ),
    );
  }
}
