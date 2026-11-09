import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../folder_library/folder_library.dart';
import '../../folder_library/thumbnail_cache.dart';
import '../../library/presentation/library_views.dart';
import '../domain/playback_engine.dart';

/// A temporary view of the active playback queue; it never creates a new queue.
class EpisodePicker extends StatefulWidget {
  const EpisodePicker({
    super.key,
    required this.items,
    required this.currentKey,
    required this.library,
    required this.thumbnails,
    required this.titleFor,
    required this.onSelect,
    required this.onClose,
  });

  final List<LocalMedia> items;
  final String? currentKey;
  final FolderLibrary library;
  final ThumbnailCache? thumbnails;
  final String Function(LocalMedia) titleFor;
  final ValueChanged<LocalMedia> onSelect;
  final VoidCallback onClose;

  @override
  State<EpisodePicker> createState() => _EpisodePickerState();
}

class _EpisodePickerState extends State<EpisodePicker> {
  static const _cardWidth = 168.0;
  static const _gap = 12.0;
  late final ScrollController _scroll;
  bool _positioned = false;
  double? _lastCardWidth;

  @override
  void initState() {
    super.initState();
    _scroll = ScrollController();
  }

  @override
  void didUpdateWidget(covariant EpisodePicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentKey != widget.currentKey ||
        !identical(oldWidget.items, widget.items)) {
      _positioned = false;
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    onKeyEvent: (_, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.escape) {
        widget.onClose();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: Material(
      color: Colors.black.withValues(alpha: 0.28),
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final cardWidth = (constraints.maxHeight < 220 ? 108.0 : _cardWidth)
                .clamp(0.0, math.max(0.0, constraints.maxWidth - 16))
                .toDouble();
            if (_lastCardWidth != cardWidth) {
              _positioned = false;
              _lastCardWidth = cardWidth;
            }
            final height = math.max(0.0, constraints.maxHeight - 48);
            final imageHeight = math.min(
              cardWidth * 9 / 16,
              math.max(0.0, height - 44),
            );
            if (!_positioned) {
              _positioned = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted || !_scroll.hasClients) return;
                final index = widget.items.indexWhere(
                  (m) => m.resumeKey == widget.currentKey,
                );
                final offset = math.max(0, index) * (cardWidth + _gap);
                _scroll.jumpTo(
                  offset.clamp(0.0, _scroll.position.maxScrollExtent),
                );
              });
            }
            return Stack(
              children: [
                Positioned.fill(
                  child: Semantics(
                    label: '关闭选集',
                    button: true,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.onClose,
                    ),
                  ),
                ),
                Positioned(
                  top: 0,
                  right: 0,
                  child: IconButton(
                    tooltip: '关闭选集',
                    onPressed: widget.onClose,
                    color: Colors.white,
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.black.withValues(alpha: 0.55),
                    ),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ),
                Align(
                  alignment: Alignment.bottomLeft,
                  child: SizedBox(
                    height: (imageHeight + 60).clamp(0.0, height),
                    child: ListView.separated(
                      controller: _scroll,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      scrollDirection: Axis.horizontal,
                      itemCount: widget.items.length,
                      separatorBuilder: (_, _) => const SizedBox(width: _gap),
                      itemBuilder: (context, index) {
                        final media = widget.items[index];
                        final selected = media.resumeKey == widget.currentKey;
                        final identity = widget.library.identityFor(media);
                        final label = widget.titleFor(media);
                        return Semantics(
                          selected: selected,
                          button: true,
                          label: '$label${selected ? '，当前播放' : ''}',
                          child: InkWell(
                            key: ValueKey('episode-${media.resumeKey}'),
                            onTap: () => widget.onSelect(media),
                            child: SizedBox(
                              width: cardWidth,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    height: imageHeight,
                                    clipBehavior: Clip.antiAlias,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(12),
                                      border: selected
                                          ? Border.all(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .primary,
                                              width: 2,
                                            )
                                          : null,
                                    ),
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        LocalVideoArtwork(
                                          media: media,
                                          cache: widget.thumbnails,
                                          entry: widget.library.entry(media),
                                          fallback: const ColoredBox(
                                            color: Color(0xff242934),
                                            child: Center(
                                              child: Icon(
                                                Icons.movie_outlined,
                                                color: Colors.white54,
                                              ),
                                            ),
                                          ),
                                        ),
                                        if (selected)
                                          const Align(
                                            alignment: Alignment.bottomLeft,
                                            child: Padding(
                                              padding: EdgeInsets.all(6),
                                              child: Icon(
                                                Icons.equalizer_rounded,
                                                color: Colors.white,
                                                size: 20,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  Expanded(
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(
                                          alpha: 0.66,
                                        ),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: ClipRect(
                                        child: Text.rich(
                                          TextSpan(
                                            text: label,
                                            children: [
                                              if (identity.episode
                                                  case final int episode)
                                                TextSpan(
                                                  text: '\n第 $episode 集',
                                                  style: const TextStyle(
                                                    color: Colors.white70,
                                                    fontSize: 12,
                                                  ),
                                                ),
                                            ],
                                          ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}
