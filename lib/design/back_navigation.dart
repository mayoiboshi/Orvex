import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'orvex_theme.dart';

/// A small local page stack, sharing the app's existing state and controllers.
class OrvexBackStack extends StatefulWidget {
  const OrvexBackStack({
    super.key,
    required this.pages,
    required this.onRemoved,
  });
  final List<Page<Object?>> pages;
  final ValueChanged<Page<Object?>> onRemoved;

  @override
  State<OrvexBackStack> createState() => _OrvexBackStackState();
}

class _OrvexBackStackState extends State<OrvexBackStack> {
  final _navigator = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) => NavigatorPopHandler<Object?>(
    enabled: TickerMode.valuesOf(context).enabled,
    onPopWithResult: (_) {
      if (TickerMode.valuesOf(context).enabled) {
        unawaited(_navigator.currentState!.maybePop());
      }
    },
    child: Navigator(
      key: _navigator,
      pages: widget.pages,
      onDidRemovePage: widget.onRemoved,
    ),
  );
}

Page<Object?> orvexNavigationPage({
  required BuildContext context,
  required LocalKey key,
  required Widget child,
  bool allowSnapshotting = true,
}) {
  final content = _NavigationInput(
    child: Material(color: OrvexColors.of(context).background, child: child),
  );
  return Theme.of(context).platform == TargetPlatform.iOS
      ? CupertinoPage<Object?>(
          key: key,
          allowSnapshotting: allowSnapshotting,
          child: content,
        )
      : MaterialPage<Object?>(
          key: key,
          allowSnapshotting: allowSnapshotting,
          child: content,
        );
}

class _NavigationInput extends StatelessWidget {
  const _NavigationInput({required this.child});
  final Widget child;
  static final _handledMouseBack = Expando<bool>();

  bool _canGoBack(BuildContext context) =>
      ModalRoute.of(context)?.isCurrent == true &&
      ModalRoute.of(context)?.popDisposition != RoutePopDisposition.bubble;

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent || !_canGoBack(context)) {
        return KeyEventResult.ignored;
      }
      final focus = FocusManager.instance.primaryFocus?.context;
      if (focus?.findAncestorWidgetOfExactType<EditableText>() != null ||
          focus?.widget is EditableText) {
        return KeyEventResult.ignored;
      }
      final platform = Theme.of(context).platform;
      final apple =
          platform == TargetPlatform.macOS || platform == TargetPlatform.iOS;
      final windows =
          platform == TargetPlatform.windows ||
          platform == TargetPlatform.linux;
      final keyboard = HardwareKeyboard.instance;
      final back =
          event.logicalKey == LogicalKeyboardKey.goBack ||
          (apple &&
              keyboard.isMetaPressed &&
              !keyboard.isAltPressed &&
              !keyboard.isControlPressed &&
              !keyboard.isShiftPressed &&
              event.logicalKey == LogicalKeyboardKey.bracketLeft) ||
          (windows &&
              keyboard.isAltPressed &&
              !keyboard.isMetaPressed &&
              !keyboard.isControlPressed &&
              !keyboard.isShiftPressed &&
              event.logicalKey == LogicalKeyboardKey.arrowLeft);
      if (!back) return KeyEventResult.ignored;
      unawaited(Navigator.of(context).maybePop());
      return KeyEventResult.handled;
    },
    child: Listener(
      onPointerDown: (event) {
        final original = event.original ?? event;
        if (_handledMouseBack[original] == true) return;
        if (event.kind == PointerDeviceKind.mouse &&
            event.buttons == kBackMouseButton &&
            Navigator.of(context).canPop() &&
            _canGoBack(context)) {
          _handledMouseBack[original] = true;
          unawaited(Navigator.of(context).maybePop());
        }
      },
      child: child,
    ),
  );
}
