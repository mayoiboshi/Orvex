import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'appearance_controller.dart';
import 'orvex_theme.dart';

/// Flutter glass treatment, not Apple's native Liquid Glass. Blur is opt-in
/// and clipped to small floating surfaces; ordinary content panels stay solid.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.blur = false,
    this.immersive = false,
    this.subtle = false,
    this.radius = OrvexMetrics.cardRadius,
    this.padding = EdgeInsets.zero,
  });
  final Widget child;
  final bool blur, immersive, subtle;
  final double radius;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = immersive ? OrvexColors.player : OrvexColors.of(context);
    final appearance = AppearanceScope.maybeOf(context);
    final opaque =
        (appearance?.reduceTransparency ?? false) ||
        (appearance?.systemReduceTransparency ?? false) ||
        MediaQuery.highContrastOf(context) ||
        MediaQuery.accessibleNavigationOf(context);
    final fill = opaque
        ? colors.surface
        : blur
        ? subtle
              ? colors.glass.withValues(alpha: colors.glass.a * 0.8)
              : colors.glass
        : colors.surface;
    final panel = DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: opaque
              ? colors.divider
              : colors.divider.withValues(
                  alpha: immersive
                      ? (subtle ? 0.28 : 0.45)
                      : (subtle ? 0.45 : 0.7),
                ),
          width: 0.7,
        ),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: opaque || !blur
              ? null
              : LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(
                      alpha: immersive ? (subtle ? 0.035 : 0.06) : 0.1,
                    ),
                    Colors.transparent,
                  ],
                ),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: blur && !opaque
          ? BackdropFilter(
              filter: ui.ImageFilter.blur(
                sigmaX: OrvexMetrics.glassBlur,
                sigmaY: OrvexMetrics.glassBlur,
              ),
              child: panel,
            )
          : panel,
    );
  }
}

class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.immersive = false,
    this.prominent = false,
    this.size = 44,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool immersive, prominent;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = immersive ? OrvexColors.player : OrvexColors.of(context);
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: onPressed != null,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPressed,
            customBorder: const CircleBorder(),
            hoverColor: colors.accent.withValues(alpha: 0.1),
            splashColor: colors.accent.withValues(alpha: 0.14),
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: prominent
                    ? colors.accent.withValues(alpha: 0.12)
                    : colors.text.withValues(alpha: 0.035),
                shape: BoxShape.circle,
                border: Border.all(
                  color: colors.divider.withValues(alpha: 0.6),
                  width: 0.6,
                ),
              ),
              child: Icon(
                icon,
                size: OrvexMetrics.iconSize,
                color: onPressed == null
                    ? colors.secondary.withValues(alpha: 0.45)
                    : prominent
                    ? colors.accent
                    : colors.text,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class OrvexBrand extends StatelessWidget {
  const OrvexBrand({super.key, this.compact = false});
  final bool compact;
  @override
  Widget build(BuildContext context) {
    final colors = OrvexColors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 27,
          height: 27,
          decoration: BoxDecoration(
            color: colors.accent.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: colors.accent.withValues(alpha: 0.25)),
          ),
          child: Icon(Icons.play_arrow_rounded, size: 20, color: colors.accent),
        ),
        if (!compact) ...[
          const SizedBox(width: 9),
          Text(
            'ORVEX',
            style: TextStyle(
              color: colors.secondary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 2.5,
            ),
          ),
        ],
      ],
    );
  }
}
