import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../design/orvex_theme.dart';
import '../application/playback_session.dart';
import 'subtitle_style_settings.dart';

/// One anchored route contains both the track list and its settings level.
Future<void> showSubtitleMenu({
  required BuildContext anchorContext,
  required PlaybackSession session,
  required VoidCallback onSubtitle,
  required bool inSettings,
}) async {
  final navigator = Navigator.of(anchorContext, rootNavigator: true);
  final overlay = navigator.overlay!.context.findRenderObject()! as RenderBox;
  final button = anchorContext.findRenderObject()! as RenderBox;
  final anchor =
      button.localToGlobal(Offset.zero, ancestor: overlay) & button.size;
  final color = OrvexColors.of(anchorContext).surface;
  final theme = Theme.of(anchorContext);
  await showGeneralDialog<void>(
    context: anchorContext,
    useRootNavigator: true,
    barrierDismissible: false,
    barrierLabel: MaterialLocalizations.of(anchorContext)
        .modalBarrierDismissLabel,
    barrierColor: Colors.transparent,
    transitionDuration: Duration.zero,
    pageBuilder: (context, _, _) => Theme(
      data: theme,
      child: _SubtitleMenu(
        anchor: anchor,
        session: session,
        onSubtitle: onSubtitle,
        inSettings: inSettings,
        color: color,
      ),
    ),
  );
}

class _SubtitleMenu extends StatefulWidget {
  const _SubtitleMenu({
    required this.anchor,
    required this.session,
    required this.onSubtitle,
    required this.inSettings,
    required this.color,
  });
  final Rect anchor;
  final PlaybackSession session;
  final VoidCallback onSubtitle;
  final bool inSettings;
  final Color color;

  @override
  State<_SubtitleMenu> createState() => _SubtitleMenuState();
}

class _SubtitleMenuState extends State<_SubtitleMenu>
    with WidgetsBindingObserver {
  bool _settings = false;
  late final Object? _engine;
  late final String? _mediaKey;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _engine = widget.session.engine;
    _mediaKey = widget.session.media?.resumeKey;
    WidgetsBinding.instance.addObserver(this);
    widget.session.addListener(_checkSession);
  }

  void _checkSession() {
    if (_closing || !mounted) return;
    if (!identical(_engine, widget.session.engine) ||
        _mediaKey != widget.session.media?.resumeKey) {
      _close();
    }
  }

  void _close() {
    if (_closing || !mounted) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    _closing = true;
    final navigator = Navigator.of(context);
    // A color picker can have its own popup route above this menu. Dismiss
    // those children first, then the menu itself, rather than popping only
    // the child and leaving a permanently half-closed menu behind.
    navigator.popUntil(
      (candidate) => identical(candidate, route) || candidate.isFirst,
    );
    if (route.isActive) navigator.removeRoute(route);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _close();
    }
  }

  @override
  void didChangeMetrics() => _close();

  @override
  void dispose() {
    widget.session.removeListener(_checkSession);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _back() {
    if (_settings) {
      setState(() => _settings = false);
    } else {
      _close();
    }
  }

  void _select(String id) {
    _close();
    unawaited(widget.session.selectSubtitle(id));
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    return PopScope(
      canPop: !_settings,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _settings) setState(() => _settings = false);
      },
      child: Focus(
        autofocus: true,
        onKeyEvent: (_, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            _back();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = math.min(
              380.0,
              math.max(0.0, constraints.maxWidth - padding.horizontal - 16),
            );
            final right = (constraints.maxWidth - widget.anchor.right)
                .clamp(
                  padding.right + 8,
                  math.max(
                    padding.right + 8,
                    constraints.maxWidth - padding.left - 8 - width,
                  ),
                )
                .toDouble();
            final above = math.max(0.0, widget.anchor.top - padding.top - 8);
            final below = math.max(
              0.0,
              constraints.maxHeight - padding.bottom - widget.anchor.bottom - 8,
            );
            final placeAbove = above >= below;
            final available = placeAbove ? above : below;
            return Stack(
              children: [
                Positioned.fill(
                  child: Semantics(
                    label: '关闭字幕菜单',
                    button: true,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _close,
                    ),
                  ),
                ),
                Positioned(
                  right: right,
                  top: placeAbove ? null : widget.anchor.bottom + 4,
                  bottom: placeAbove
                      ? constraints.maxHeight - widget.anchor.top + 4
                      : null,
                  child: Material(
                    key: const ValueKey('subtitle-menu-panel'),
                    color: widget.color,
                    elevation: 8,
                    borderRadius: BorderRadius.circular(
                      OrvexMetrics.controlRadius,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: width,
                        minWidth: width,
                        maxHeight: available,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              if (_settings)
                                IconButton(
                                  tooltip: '返回字幕轨道',
                                  onPressed: _back,
                                  icon: const Icon(Icons.arrow_back_rounded),
                                ),
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                  ),
                                  child: Text(
                                    _settings ? '字幕设置' : '字幕',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: '关闭字幕菜单',
                                onPressed: _close,
                                icon: const Icon(Icons.close_rounded),
                              ),
                            ],
                          ),
                          const Divider(height: 1),
                          Flexible(
                            child: ListenableBuilder(
                              listenable: widget.session,
                              builder: (context, _) => SingleChildScrollView(
                                key: ValueKey(_settings),
                                child: _settings
                                    ? Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                          16,
                                          12,
                                          16,
                                          16,
                                        ),
                                        child: SubtitleStyleSettings(
                                          session: widget.session,
                                          showTitle: false,
                                        ),
                                      )
                                    : _trackList(),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _trackList() {
    final frame = widget.session.frame;
    final selected = frame.subtitleTrackId;
    Widget item(String id, String label) => ListTile(
      title: Text(label),
      selected: widget.session.error == null && selected == id,
      trailing: widget.session.error == null && selected == id
          ? const Icon(Icons.check_rounded)
          : null,
      onTap: () => _select(id),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        item('auto', '自动选择'),
        item('no', '关闭字幕'),
        for (final track in frame.subtitleTracks) item(track.id, track.label),
        const Divider(height: 1),
        ListTile(
          title: const Text('字幕设置…'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => setState(() => _settings = true),
        ),
        if (!widget.inSettings)
          ListTile(
            title: const Text('打开外挂字幕…'),
            onTap: () {
              _close();
              widget.onSubtitle();
            },
          ),
      ],
    );
  }
}
