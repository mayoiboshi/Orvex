import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'appearance_controller.dart';

abstract final class OrvexMetrics {
  static const small = 8.0;
  static const smallRadius = 10.0;
  static const coverRadius = 14.0;
  static const navigationRadius = 28.0;
  static const pillRadius = 99.0;
  static const glassBlur = 12.0;
  static const gap = 12.0;
  static const space = 16.0;
  static const section = 24.0;
  static const page = 20.0;
  static const cardRadius = 18.0;
  static const panelRadius = 26.0;
  static const controlRadius = 16.0;
  static const hitSize = 44.0;
  static const iconSize = 21.0;
  static const motion = Duration(milliseconds: 200);
  static const quickMotion = Duration(milliseconds: 130);
  static const curve = Curves.easeOutCubic;

  static Duration duration(BuildContext context, {bool quick = false}) =>
      MediaQuery.disableAnimationsOf(context) ||
          (AppearanceScope.maybeOf(context)?.reduceMotion ?? false)
      ? Duration.zero
      : quick
      ? quickMotion
      : motion;
}

@immutable
class OrvexColors extends ThemeExtension<OrvexColors> {
  const OrvexColors({
    required this.background,
    required this.surface,
    required this.elevated,
    required this.glass,
    required this.text,
    required this.secondary,
    required this.accent,
    required this.divider,
    required this.overlay,
    required this.error,
    required this.warning,
    required this.success,
  });
  final Color background, surface, elevated, glass, text, secondary;
  final Color accent, divider, overlay, error, warning, success;

  static const light = OrvexColors(
    background: Color(0xFFF4F6FA),
    surface: Color(0xFFFFFFFF),
    elevated: Color(0xFFE9EEF6),
    glass: Color(0xE6FFFFFF),
    text: Color(0xFF131D2E),
    secondary: Color(0xFF536279),
    accent: Color(0xFF285FE5),
    divider: Color(0xFFDCE3EF),
    overlay: Color(0x99121B2B),
    error: Color(0xFFB4233C),
    warning: Color(0xFF896000),
    success: Color(0xFF15734C),
  );
  static const dark = OrvexColors(
    background: Color(0xFF0C1018),
    surface: Color(0xFF151C28),
    elevated: Color(0xFF202B3C),
    glass: Color(0xD51D2737),
    text: Color(0xFFF1F5FD),
    secondary: Color(0xFFA8B6CC),
    accent: Color(0xFF90B5FF),
    divider: Color(0xFF303D51),
    overlay: Color(0xB3080D16),
    error: Color(0xFFFFA0AF),
    warning: Color(0xFFE3C477),
    success: Color(0xFF8AD8B4),
  );

  /// Immersive overlays remain readable regardless of the app theme or video.
  static const player = OrvexColors(
    background: Color(0xFF000000),
    surface: Color(0xFF141C29),
    elevated: Color(0xFF26344A),
    glass: Color(0xB31A2536),
    text: Color(0xFFF5F8FF),
    secondary: Color(0xFFCAD5E7),
    accent: Color(0xFFA9C6FF),
    divider: Color(0x66D4E4FF),
    overlay: Color(0x99101520),
    error: Color(0xFFFFA0AF),
    warning: Color(0xFFE3C477),
    success: Color(0xFF8AD8B4),
  );
  static OrvexColors of(BuildContext context) =>
      Theme.of(context).extension<OrvexColors>() ??
      (Theme.of(context).brightness == Brightness.dark ? dark : light);

  @override
  OrvexColors copyWith({
    Color? background,
    Color? surface,
    Color? elevated,
    Color? glass,
    Color? text,
    Color? secondary,
    Color? accent,
    Color? divider,
    Color? overlay,
    Color? error,
    Color? warning,
    Color? success,
  }) => OrvexColors(
    background: background ?? this.background,
    surface: surface ?? this.surface,
    elevated: elevated ?? this.elevated,
    glass: glass ?? this.glass,
    text: text ?? this.text,
    secondary: secondary ?? this.secondary,
    accent: accent ?? this.accent,
    divider: divider ?? this.divider,
    overlay: overlay ?? this.overlay,
    error: error ?? this.error,
    warning: warning ?? this.warning,
    success: success ?? this.success,
  );
  @override
  OrvexColors lerp(covariant OrvexColors? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return OrvexColors(
      background: mix(background, other.background),
      surface: mix(surface, other.surface),
      elevated: mix(elevated, other.elevated),
      glass: mix(glass, other.glass),
      text: mix(text, other.text),
      secondary: mix(secondary, other.secondary),
      accent: mix(accent, other.accent),
      divider: mix(divider, other.divider),
      overlay: mix(overlay, other.overlay),
      error: mix(error, other.error),
      warning: mix(warning, other.warning),
      success: mix(success, other.success),
    );
  }
}

abstract final class OrvexTheme {
  static ThemeData create(Brightness brightness, {bool immersive = false}) {
    final colors = immersive
        ? OrvexColors.player
        : brightness == Brightness.dark
        ? OrvexColors.dark
        : OrvexColors.light;
    final dark = brightness == Brightness.dark;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: colors.accent,
          brightness: brightness,
        ).copyWith(
          primary: colors.accent,
          onPrimary: dark ? OrvexColors.light.text : OrvexColors.dark.text,
          surface: colors.surface,
          onSurface: colors.text,
          onSurfaceVariant: colors.secondary,
          surfaceContainerHighest: colors.elevated,
          outline: colors.divider,
          error: colors.error,
        );
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: switch (defaultTargetPlatform) {
        TargetPlatform.iOS || TargetPlatform.macOS => '.SF UI Text',
        TargetPlatform.windows => 'Segoe UI',
        _ => null,
      },
      fontFamilyFallback: const [
        'PingFang SC',
        'Microsoft YaHei',
        'sans-serif',
      ],
    );
    final text = base.textTheme
        .apply(bodyColor: colors.text, displayColor: colors.text)
        .copyWith(
          headlineLarge: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w600,
            color: colors.text,
            letterSpacing: -0.6,
          ),
          headlineMedium: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w600,
            color: colors.text,
            letterSpacing: -0.4,
          ),
          titleLarge: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: colors.text,
          ),
          titleMedium: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: colors.text,
          ),
          titleSmall: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: colors.text,
          ),
          bodyLarge: TextStyle(fontSize: 16, height: 1.5, color: colors.text),
          bodyMedium: TextStyle(fontSize: 14, height: 1.5, color: colors.text),
          bodySmall: TextStyle(
            fontSize: 12,
            height: 1.5,
            color: colors.secondary,
          ),
          labelLarge: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: colors.text,
          ),
          labelMedium: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: colors.secondary,
          ),
          labelSmall: TextStyle(fontSize: 11, color: colors.secondary),
        );
    return base.copyWith(
      extensions: [colors],
      textTheme: text.apply(
        fontFamily: base.textTheme.bodyMedium?.fontFamily,
        fontFamilyFallback: const [
          'PingFang SC',
          'Microsoft YaHei',
          'sans-serif',
        ],
      ),
      scaffoldBackgroundColor: colors.background,
      dividerColor: colors.divider,
      iconTheme: IconThemeData(color: colors.text, size: OrvexMetrics.iconSize),
      appBarTheme: AppBarTheme(
        backgroundColor: colors.background,
        foregroundColor: colors.text,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        systemOverlayStyle: systemOverlay(brightness),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: const Size(44, 44)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.elevated.withValues(alpha: 0.65),
        hintStyle: TextStyle(color: colors.secondary),
        contentPadding: const EdgeInsets.all(16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: colors.accent),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: colors.divider,
        thickness: 0.7,
        space: 1,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: colors.secondary,
        textColor: colors.text,
        titleTextStyle: text.bodyMedium,
        subtitleTextStyle: text.bodySmall,
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        modalBarrierColor: colors.overlay,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(OrvexMetrics.panelRadius),
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: colors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(OrvexMetrics.cardRadius),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(OrvexMetrics.panelRadius),
        ),
      ),
      sliderTheme: base.sliderTheme.copyWith(
        activeTrackColor: colors.accent,
        inactiveTrackColor: colors.divider,
        thumbColor: colors.accent,
        overlayColor: colors.accent.withValues(alpha: 0.1),
        trackHeight: 3,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colors.accent,
        linearTrackColor: colors.elevated,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: colors.text,
        contentTextStyle: TextStyle(color: colors.background),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  static SystemUiOverlayStyle systemOverlay(Brightness brightness) =>
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: brightness == Brightness.dark
            ? Brightness.light
            : Brightness.dark,
        statusBarBrightness: brightness,
        systemNavigationBarColor: brightness == Brightness.dark
            ? OrvexColors.dark.background
            : OrvexColors.light.background,
        systemNavigationBarIconBrightness: brightness == Brightness.dark
            ? Brightness.light
            : Brightness.dark,
      );
}
