import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/appearance_controller.dart';
import '../design/orvex_theme.dart';
import '../features/player/presentation/player_page.dart';
import 'orvex_providers.dart';

export 'orvex_providers.dart';

class OrvexApp extends ConsumerWidget {
  const OrvexApp({super.key, this.startupError});
  final String? startupError;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(appearanceProvider);
    return AppearanceScope(
      controller: appearance,
      child: ListenableBuilder(
        listenable: appearance,
        builder: (context, _) => MaterialApp(
          title: 'Orvex',
          debugShowCheckedModeBanner: false,
          theme: OrvexTheme.create(Brightness.light),
          darkTheme: OrvexTheme.create(Brightness.dark),
          themeMode: appearance.mode,
          themeAnimationDuration: appearance.reduceMotion
              ? Duration.zero
              : OrvexMetrics.motion,
          themeAnimationCurve: OrvexMetrics.curve,
          builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
            value: OrvexTheme.systemOverlay(Theme.of(context).brightness),
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                disableAnimations:
                    MediaQuery.disableAnimationsOf(context) ||
                    appearance.reduceMotion,
              ),
              child: child!,
            ),
          ),
          home: PlayerPage(startupError: startupError),
        ),
      ),
    );
  }
}
