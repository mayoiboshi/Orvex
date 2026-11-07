import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../design/glass.dart';
import '../../../design/back_navigation.dart';
import '../../../design/orvex_theme.dart';
import '../../anime_metadata/application/anime_metadata_controller.dart';
import '../../anime_metadata/domain/anime_subject.dart';
import '../../folder_library/folder_browser.dart';
import '../../folder_library/folder_library.dart';
import '../../folder_library/thumbnail_cache.dart';
import '../../player/domain/playback_engine.dart';
import '../domain/media_series.dart';
import '../domain/playback_record.dart';
import 'library_views.dart' show MediaCover;

class SeriesLibrary extends StatefulWidget {
  const SeriesLibrary({
    super.key,
    required this.library,
    required this.thumbnails,
    required this.imported,
    required this.history,
    required this.metadata,
    required this.onOpen,
    required this.onImport,
    required this.onMetadata,
    this.selection,
    required this.onSelection,
  });
  final FolderLibrary library;
  final ThumbnailCache thumbnails;
  final List<LocalMedia> imported;
  final List<PlaybackRecord> history;
  final AnimeMetadataController metadata;
  final ValueChanged<LocalMedia> onOpen, onMetadata;
  final VoidCallback onImport;
  final String? selection;
  final ValueChanged<String?> onSelection;
  @override
  State<SeriesLibrary> createState() => _SeriesLibraryState();
}

class _SeriesLibraryState extends State<SeriesLibrary> {
  bool _folders = false;
  String _query = '';
  String? _selected;
  int _revision = -1;
  List<LocalMedia>? _imports;
  List<MediaSeries> _series = [];
  @override
  void initState() {
    super.initState();
    _selected = widget.selection;
  }

  List<MediaSeries> _groups() {
    if (_revision != widget.library.revision ||
        !identical(_imports, widget.imported)) {
      _revision = widget.library.revision;
      _imports = widget.imported;
      _series = widget.library.series(widget.imported);
    }
    return _series;
  }

  void _select(String? key) {
    if (_selected == key) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _selected = key);
    widget.onSelection(key);
  }

  AnimeSubject? _subject(MediaSeries group) => group.media
      .map(widget.metadata.subjectFor)
      .whereType<AnimeSubject>()
      .firstOrNull;
  String _title(MediaSeries group) =>
      _subject(group)?.title ?? group.identity.title;

  FolderBrowser _browser({Widget? header, MediaSeries? group}) => FolderBrowser(
    library: widget.library,
    thumbnails: widget.thumbnails,
    imported: widget.imported,
    history: widget.history,
    metadata: widget.metadata,
    onOpen: widget.onOpen,
    onImport: widget.onImport,
    onMetadata: widget.onMetadata,
    header: header,
    collection: group?.media,
    collectionTitle: group == null ? null : _title(group),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.library,
    builder: (context, _) {
      final colors = OrvexColors.of(context);
      final groups = _groups();
      final selected = groups.where((g) => g.key == _selected).firstOrNull;
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Row(
              children: [
                ChoiceChip(
                  key: const ValueKey('series-view'),
                  label: const Text('剧集'),
                  selected: !_folders,
                  onSelected: (_) => setState(() => _folders = false),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  key: const ValueKey('folders-view'),
                  label: const Text('文件夹'),
                  selected: _folders,
                  onSelected: (_) => setState(() => _folders = true),
                ),
                const Spacer(),
                Text(
                  '${widget.library.roots.length} 个目录',
                  style: TextStyle(fontSize: 11, color: colors.secondary),
                ),
              ],
            ),
          ),
          Expanded(
            child: _folders
                ? _browser()
                : OrvexBackStack(
                    pages: [
                      orvexNavigationPage(
                        context: context,
                        key: const ValueKey('series-overview-page'),
                        child: _overview(context, groups),
                      ),
                      if (selected != null)
                        orvexNavigationPage(
                          context: context,
                          key: ValueKey('series-detail-${selected.key}'),
                          child: _detail(selected),
                        ),
                    ],
                    onRemoved: (page) {
                      if (selected != null &&
                          page.key ==
                              ValueKey('series-detail-${selected.key}')) {
                        _select(null);
                      }
                    },
                  ),
          ),
        ],
      );
    },
  );

  Widget _detail(MediaSeries selected) {
    final colors = OrvexColors.of(context);
    return _browser(
      group: selected,
      header: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 20, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: '返回剧集',
                  onPressed: () => _select(null),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
                Expanded(
                  child: Text(
                    _title(selected),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: '番剧资料',
                  onPressed: () => widget.onMetadata(selected.representative),
                  icon: const Icon(Icons.info_outline_rounded),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 8),
              child: Row(
                children: [
                  FilledButton.icon(
                    onPressed: () => widget.onOpen(selected.representative),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text(
                      widget.library
                                  .identityFor(selected.representative)
                                  .episode ==
                              null
                          ? '播放首个视频'
                          : '播放第 ${widget.library.identityFor(selected.representative).episode} 集',
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      '${selected.media.length} 个视频 · ${widget.library.root(selected.representative.folderRoot ?? '')?.name ?? '已导入'}',
                      style: TextStyle(color: colors.secondary, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            if (_subject(selected)?.summary case final String summary)
              if (summary.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 14, 0, 0),
                  child: Text(
                    summary,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.secondary,
                      height: 1.5,
                      fontSize: 13,
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _overview(BuildContext context, List<MediaSeries> all) {
    final colors = OrvexColors.of(context);
    final groups = _query.isEmpty
        ? all
        : all
              .where(
                (g) =>
                    '${_title(g)} ${g.identity.title} ${g.media.map((m) => m.name).join(' ')}'
                        .toLowerCase()
                        .contains(_query.toLowerCase()),
              )
              .toList();
    return CustomScrollView(
      key: const PageStorageKey('series-overview'),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '媒体库',
                        style: Theme.of(context).textTheme.headlineLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: '导入单个视频',
                      onPressed: widget.onImport,
                      icon: const Icon(Icons.note_add_outlined),
                    ),
                    GlassIconButton(
                      tooltip: '添加媒体文件夹',
                      onPressed: widget.library.scanning
                          ? null
                          : () => unawaited(widget.library.add()),
                      icon: Icons.create_new_folder_outlined,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextFormField(
                  initialValue: _query,
                  onChanged: (value) => setState(() => _query = value),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search_rounded),
                    hintText: '搜索作品或文件名',
                  ),
                ),
                if (widget.library.scanning) ...[
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(minHeight: 2),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '发现 ${widget.library.discovered} 个视频 · 正在扫描',
                          style: TextStyle(
                            color: colors.secondary,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: widget.library.cancelScan,
                        child: const Text('取消'),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  widget.metadata.busy
                      ? '正在关联 Bangumi · ${groups.length} 部作品'
                      : '${groups.length} 部作品 · ${all.fold<int>(0, (count, g) => count + g.media.length)} 个视频',
                  style: TextStyle(color: colors.secondary, fontSize: 12),
                ),
                if (widget.library.error ?? widget.metadata.error
                    case final String message)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      message,
                      style: TextStyle(color: colors.warning, fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (groups.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: Column(
                  children: [
                    Icon(
                      Icons.video_library_outlined,
                      size: 36,
                      color: colors.secondary,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _query.isEmpty ? '添加文件夹，自动整理同一作品的各集' : '没有找到符合条件的作品',
                      style: TextStyle(color: colors.secondary),
                    ),
                    if (_query.isEmpty)
                      TextButton.icon(
                        onPressed: widget.library.scanning
                            ? null
                            : () => widget.library.add(),
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('选择媒体根目录'),
                      ),
                  ],
                ),
              ),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          sliver: SliverLayoutBuilder(
            builder: (context, constraints) {
              final count = (constraints.crossAxisExtent / 170).floor().clamp(
                2,
                6,
              );
              final width =
                  (constraints.crossAxisExtent - (count - 1) * 14) / count;
              final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
              return SliverGrid(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final group = groups[index];
                  final subject = _subject(group);
                  final title = group.media.length == 1
                      ? folderMediaTitle(group.representative, widget.metadata)
                      : _title(group);
                  final match = widget.metadata.matchFor(group.representative);
                  final caption =
                      '${group.media.length} 个视频${match?.status == AnimeMatchStatus.failed
                          ? ' · 联网失败'
                          : subject == null
                          ? ' · 未关联'
                          : ''}';
                  return InkWell(
                    key: ValueKey('series-${group.key}'),
                    borderRadius: BorderRadius.circular(
                      OrvexMetrics.cardRadius,
                    ),
                    onTap: () => group.identity.episodic
                        ? _select(group.key)
                        : widget.onOpen(group.representative),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AspectRatio(
                          aspectRatio: 1 / 1.4,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(
                              OrvexMetrics.cardRadius,
                            ),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                MediaCover(
                                  media: group.representative,
                                  poster: true,
                                  posterPath: widget.metadata.posterPath(
                                    subject?.id ?? 0,
                                  ),
                                ),
                                Positioned(
                                  top: 4,
                                  right: 4,
                                  child: GlassIconButton(
                                    tooltip: '番剧资料',
                                    onPressed: () =>
                                        widget.onMetadata(group.representative),
                                    icon: Icons.info_outline_rounded,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 5),
                        Text(
                          caption,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.secondary,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  );
                }, childCount: groups.length),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: count,
                  crossAxisSpacing: 14,
                  mainAxisSpacing: 18,
                  mainAxisExtent: width * 1.4 + math.max(75, 90 * scale),
                ),
              );
            },
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 120)),
      ],
    );
  }
}
