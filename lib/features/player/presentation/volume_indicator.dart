import 'package:flutter/material.dart';

import '../../../design/orvex_theme.dart';

class VolumeIndicator extends StatelessWidget {
  const VolumeIndicator({super.key, required this.volume, this.steps});

  final double volume;
  final int? steps;

  @override
  Widget build(BuildContext context) {
    final colors = OrvexColors.player;
    final level = (volume / 100).clamp(0.0, 1.0);
    final percent = '${volume.round()}%';
    final divisions = steps;
    return Semantics(
      label: '音量',
      value: percent,
      excludeSemantics: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(OrvexMetrics.pillRadius),
        child: ColoredBox(
          color: colors.surface,
          child: Stack(
            children: [
              Positioned.fill(
                child: FractionallySizedBox(
                  widthFactor: level,
                  alignment: Alignment.centerLeft,
                  child: ColoredBox(
                    color: colors.accent.withValues(alpha: 0.27),
                  ),
                ),
              ),
              if (divisions != null)
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 5,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      for (var step = 1; step <= divisions; step++)
                        Container(
                          width: 2,
                          height: 3,
                          decoration: BoxDecoration(
                            color: step <= level * divisions + 0.01
                                ? colors.accent
                                : colors.secondary.withValues(alpha: 0.40),
                            borderRadius: BorderRadius.circular(1),
                          ),
                        ),
                    ],
                  ),
                ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  12,
                  9,
                  12,
                  divisions == null ? 9 : 14,
                ),
                child: Row(
                  children: [
                    Icon(
                      level == 0
                          ? Icons.volume_off_outlined
                          : Icons.volume_up_outlined,
                      size: 19,
                      color: colors.text,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '音量',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: colors.secondary, fontSize: 13),
                      ),
                    ),
                    Text(
                      percent,
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
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
}
