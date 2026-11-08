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
import '../domain/library_overview.dart';
import '../domain/media_series.dart';
import '../domain/playback_record.dart';
import 'library_views.dart' show MediaCover;

typedef LibraryImportStatus = ({
  String title,
  String detail,
  double? fraction,
  bool failed,
  bool active,
});

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
    required this.arrivals,
    required this.sort,
    required this.onSort,
    required this.compact,
    required this.onCompact,
    required this.importStatus,
    required this.onDismissImport,
    this.selection,
    required this.onSelection,
  });
  final FolderLibrary library;
  final ThumbnailCache thumbnails;
  final List<LocalMedia> imported;
  final List<PlaybackRecord> history;
  final AnimeMetadataController metadata;
  final ValueChanged<LocalMedia> onOpen, onMetadata;
  final VoidCallback? onImport;
  final Map<String, DateTime> arrivals;
  final LibrarySort sort;
  final ValueChanged<LibrarySort> onSort;
  final bool compact;
  final ValueChanged<bool> onCompact;
  final LibraryImportStatus? importStatus;
  final VoidCallback onDismissImport;
  final String? selection;
  final ValueChanged<String?> onSelection;
  @override
  State<SeriesLibrary> createState() => _SeriesLibraryState();
}

class _SeriesLibraryState extends State<SeriesLibrary> {
  bool _folders = false;
  String _query = '';
  LibraryKind _filter = LibraryKind.all;
  String? _dismissedScan;
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

  FolderBrowser _browser({
    Widget? header,
    Widget? libraryHeader,
    MediaSeries? group,
  }) => FolderBrowser(
    library: widget.library,
    thumbnails: widget.thumbnails,
    imported: widget.imported,
    history: widget.history,
    metadata: widget.metadata,
    onOpen: widget.onOpen,
    onImport: widget.onImport,
    onMetadata: widget.onMetadata,
    header: header,
    libraryHeader: libraryHeader,
    collection: group?.media,
    collectionTitle: group == null ? null : _title(group),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.library,
    builder: (context, _) {
      final groups = _groups();
      final selected = groups.where((g) => g.key == _selected).firstOrNull;
      if (widget.library.scanning) _dismissedScan = null;
      return _folders
          ? _browser(libraryHeader: _header(context))
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
                    page.key == ValueKey('series-detail-${selected.key}')) {
                  _select(null);
                }
              },
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

  String _sortLabel(LibrarySortField field) => switch (field) {
    LibrarySortField.added => '最近添加',
    LibrarySortField.name => '名称',
    LibrarySortField.year => '发行年份',
    LibrarySortField.score => '评分',
  };

  String _filterLabel(LibraryKind kind) => switch (kind) {
    LibraryKind.all => '全部',
    LibraryKind.movie => '电影',
    LibraryKind.series => '剧集',
    LibraryKind.unknown => '未识别',
  };

  double _inset(double width) =>
      (width * .04).clamp(OrvexMetrics.space, OrvexMetrics.section * 2);

  Widget _header(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final theme = Theme.of(context).textTheme;
      final library = widget.library;
      final scanRoot = library.lastScanRoot;
      final lastRoot = scanRoot == null ? null : library.root(scanRoot);
      return Padding(
        padding: EdgeInsets.fromLTRB(
          _inset(constraints.maxWidth),
          20,
          _inset(constraints.maxWidth),
          OrvexMetrics.gap,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const OrvexBrand(),
            const SizedBox(height: OrvexMetrics.gap),
            Row(
              children: [
                Expanded(child: Text('媒体库', style: theme.headlineLarge)),
                GlassIconButton(
                  tooltip: '导入单个视频',
                  icon: Icons.note_add_outlined,
                  onPressed: widget.onImport,
                ),
                const SizedBox(width: OrvexMetrics.small),
                GlassIconButton(
                  tooltip: '添加媒体文件夹',
                  icon: Icons.create_new_folder_outlined,
                  prominent: true,
                  onPressed: library.loading || library.scanning
                      ? null
                      : () => unawaited(library.add()),
                ),
              ],
            ),
            const SizedBox(height: OrvexMetrics.gap),
            Wrap(
              spacing: OrvexMetrics.small,
              runSpacing: OrvexMetrics.small,
              children: [
                ChoiceChip(
                  key: const ValueKey('series-view'),
                  label: const Text('作品'),
                  selected: !_folders,
                  onSelected: (_) => setState(() => _folders = false),
                ),
                ChoiceChip(
                  key: const ValueKey('folders-view'),
                  label: const Text('文件夹'),
                  selected: _folders,
                  onSelected: (_) => setState(() => _folders = true),
                ),
              ],
            ),
            if (widget.importStatus case final status?)
              _task(
                context,
                status,
                onAction: status.active ? null : widget.onDismissImport,
              ),
            if (library.scanning)
              _task(
                context,
                (
                  title: '正在扫描',
                  detail:
                      '已读取 ${library.foldersScanned} 个目录 · 发现 ${library.discovered} 个视频',
                  fraction: null,
                  failed: false,
                  active: true,
                ),
                onAction: library.cancelScan,
                action: '取消',
              )
            else if (lastRoot != null && scanRoot != _dismissedScan)
              _task(context, (
                title: library.error != null
                    ? '扫描失败'
                    : lastRoot.issue ?? '扫描完成',
                detail:
                    library.error ??
                    '已读取 ${library.foldersScanned} 个目录 · 发现 ${library.discovered} 个视频',
                fraction: null,
                failed: library.error != null,
                active: false,
              ), onAction: () => setState(() => _dismissedScan = scanRoot))
            else if (library.error case final message?)
              Padding(
                padding: const EdgeInsets.only(top: OrvexMetrics.small),
                child: Text(
                  message,
                  style: theme.bodySmall?.copyWith(
                    color: OrvexColors.of(context).warning,
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );

  Widget _task(
    BuildContext context,
    LibraryImportStatus status, {
    VoidCallback? onAction,
    String action = '关闭',
  }) {
    final theme = Theme.of(context).textTheme;
    final colors = OrvexColors.of(context);
    final fraction = status.fraction;
    return Padding(
      padding: const EdgeInsets.only(top: OrvexMetrics.small),
      child: GlassSurface(
        radius: OrvexMetrics.controlRadius,
        padding: const EdgeInsets.all(OrvexMetrics.gap),
        child: Row(
          children: [
            if (status.active)
              SizedBox.square(
                dimension: 19,
                child: CircularProgressIndicator(
                  value: fraction,
                  strokeWidth: 2,
                ),
              )
            else
              Icon(
                status.failed
                    ? Icons.error_outline_rounded
                    : Icons.check_circle_outline_rounded,
                color: status.failed ? colors.warning : colors.accent,
                size: 20,
              ),
            const SizedBox(width: OrvexMetrics.gap),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    fraction == null
                        ? status.title
                        : '${status.title} · ${(fraction * 100).round()}%',
                    style: theme.titleSmall,
                  ),
                  Text(
                    status.detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.bodySmall,
                  ),
                ],
              ),
            ),
            if (onAction != null)
              TextButton(onPressed: onAction, child: Text(action)),
          ],
        ),
      ),
    );
  }

  Widget _overview(
    BuildContext context,
    List<MediaSeries> groups,
  ) => LayoutBuilder(
    builder: (context, constraints) {
      final theme = Theme.of(context).textTheme;
      final colors = OrvexColors.of(context);
      final inset = _inset(constraints.maxWidth);
      final entries = browseLibrary(
        libraryEntries(
          groups,
          arrivals: widget.arrivals,
          matchFor: widget.metadata.matchFor,
          identify: widget.library.identityFor,
        ),
        query: _query,
        filter: _filter,
        sort: widget.sort,
      );
      final width = constraints.maxWidth - 2 * inset;
      final columns = (width / 168).floor().clamp(1, 6);
      final cardWidth = (width - (columns - 1) * OrvexMetrics.gap) / columns;
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final searchActive = _query.trim().isNotEmpty;
      final count = entries.fold<int>(
        0,
        (count, entry) => count + entry.group.media.length,
      );
      return CustomScrollView(
        key: const PageStorageKey('series-overview'),
        slivers: [
          SliverToBoxAdapter(child: _header(context)),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(inset, 0, inset, OrvexMetrics.space),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextFormField(
                    initialValue: _query,
                    onChanged: (query) => setState(() => _query = query),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search_rounded),
                      hintText: '搜索作品或文件名',
                    ),
                  ),
                  const SizedBox(height: OrvexMetrics.gap),
                  Text(
                    '${entries.length} 项 · $count 个视频',
                    style: theme.bodySmall,
                  ),
                  const SizedBox(height: OrvexMetrics.small),
                  Wrap(
                    spacing: OrvexMetrics.small,
                    runSpacing: OrvexMetrics.small,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      PopupMenuButton<LibrarySortField>(
                        tooltip: '排序',
                        key: const ValueKey('library-sort'),
                        initialValue: widget.sort.field,
                        onSelected: (field) => widget.onSort((
                          field: field,
                          descending: field == widget.sort.field
                              ? widget.sort.descending
                              : field != LibrarySortField.name,
                        )),
                        itemBuilder: (_) => [
                          for (final field in LibrarySortField.values)
                            CheckedPopupMenuItem(
                              value: field,
                              checked: widget.sort.field == field,
                              child: Text(_sortLabel(field)),
                            ),
                        ],
                        child: _tool(
                          context,
                          Icons.sort_rounded,
                          _sortLabel(widget.sort.field),
                        ),
                      ),
                      IconButton(
                        tooltip: widget.sort.descending
                            ? '当前降序，切换升序'
                            : '当前升序，切换降序',
                        onPressed: () => widget.onSort((
                          field: widget.sort.field,
                          descending: !widget.sort.descending,
                        )),
                        icon: Icon(
                          widget.sort.descending
                              ? Icons.arrow_downward_rounded
                              : Icons.arrow_upward_rounded,
                        ),
                      ),
                      PopupMenuButton<LibraryKind>(
                        tooltip: '筛选',
                        key: const ValueKey('library-filter'),
                        initialValue: _filter,
                        onSelected: (kind) => setState(() => _filter = kind),
                        itemBuilder: (_) => [
                          for (final kind in LibraryKind.values)
                            CheckedPopupMenuItem(
                              value: kind,
                              checked: _filter == kind,
                              child: Text(_filterLabel(kind)),
                            ),
                        ],
                        child: _tool(
                          context,
                          Icons.filter_list_rounded,
                          _filter == LibraryKind.all
                              ? '筛选'
                              : _filterLabel(_filter),
                          selected: _filter != LibraryKind.all,
                        ),
                      ),
                      if (_filter != LibraryKind.all)
                        IconButton(
                          tooltip: '重置筛选',
                          onPressed: () =>
                              setState(() => _filter = LibraryKind.all),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      IconButton(
                        tooltip: widget.compact ? '切换海报网格' : '切换紧凑列表',
                        onPressed: () => widget.onCompact(!widget.compact),
                        icon: Icon(
                          widget.compact
                              ? Icons.grid_view_rounded
                              : Icons.view_list_rounded,
                        ),
                      ),
                    ],
                  ),
                  if (widget.metadata.busy)
                    Padding(
                      padding: const EdgeInsets.only(top: OrvexMetrics.small),
                      child: Text('正在关联 Bangumi', style: theme.bodySmall),
                    ),
                  if (widget.metadata.error case final String message)
                    Padding(
                      padding: const EdgeInsets.only(top: OrvexMetrics.small),
                      child: Text(
                        message,
                        style: theme.bodySmall?.copyWith(color: colors.warning),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (entries.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Center(
                  child: Text(
                    searchActive || _filter != LibraryKind.all
                        ? '没有找到符合条件的媒体'
                        : '添加视频或媒体文件夹，开始整理你的片库',
                    style: theme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: inset),
              sliver: widget.compact
                  ? SliverList.builder(
                      itemCount: entries.length,
                      itemBuilder: (_, index) =>
                          _entryTile(context, entries[index], compact: true),
                    )
                  : SliverGrid.builder(
                      itemCount: entries.length,
                      itemBuilder: (_, index) =>
                          _entryTile(context, entries[index], compact: false),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        crossAxisSpacing: OrvexMetrics.gap,
                        mainAxisSpacing: OrvexMetrics.space,
                        mainAxisExtent:
                            cardWidth * 1.5 + math.max(75, 90 * scale),
                      ),
                    ),
            ),
          SliverToBoxAdapter(
            child: SizedBox(
              height: MediaQuery.paddingOf(context).bottom + OrvexMetrics.page,
            ),
          ),
        ],
      );
    },
  );

  Widget _tool(
    BuildContext context,
    IconData icon,
    String label, {
    bool selected = false,
  }) {
    final colors = OrvexColors.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: OrvexMetrics.hitSize),
      padding: const EdgeInsets.symmetric(horizontal: OrvexMetrics.gap),
      decoration: BoxDecoration(
        color: selected ? colors.accent.withValues(alpha: .12) : colors.surface,
        borderRadius: BorderRadius.circular(OrvexMetrics.controlRadius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            color: selected ? colors.accent : colors.secondary,
            size: 19,
          ),
          const SizedBox(width: OrvexMetrics.small),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
        ],
      ),
    );
  }

  Widget _entryTile(
    BuildContext context,
    LibraryEntry entry, {
    required bool compact,
  }) {
    final group = entry.group;
    final title = group.media.length == 1
        ? folderMediaTitle(group.representative, widget.metadata)
        : entry.title;
    final theme = Theme.of(context).textTheme;
    final caption = [
      '${group.media.length} 个视频',
      if (entry.year case final year?) '$year',
      if (entry.score case final score?) '★ ${score.toStringAsFixed(1)}',
      if (entry.kind == LibraryKind.unknown) '未识别',
    ].join(' · ');
    final poster = ClipRRect(
      borderRadius: BorderRadius.circular(OrvexMetrics.coverRadius),
      child: AspectRatio(
        aspectRatio: 2 / 3,
        child: MediaCover(
          media: group.representative,
          poster: true,
          posterPath: widget.metadata.posterPath(entry.subject?.id ?? 0),
        ),
      ),
    );
    final info = GlassIconButton(
      tooltip: '番剧资料',
      onPressed: () => widget.onMetadata(group.representative),
      icon: Icons.info_outline_rounded,
    );
    final labels = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.titleSmall,
        ),
        const SizedBox(height: 4),
        Text(
          caption,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.bodySmall,
        ),
      ],
    );
    return InkWell(
      key: ValueKey('series-${group.key}'),
      borderRadius: BorderRadius.circular(OrvexMetrics.cardRadius),
      onTap: () => group.identity.episodic
          ? _select(group.key)
          : widget.onOpen(group.representative),
      child: compact
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: OrvexMetrics.small),
              child: Row(
                children: [
                  SizedBox(width: 42, child: poster),
                  const SizedBox(width: OrvexMetrics.gap),
                  Expanded(child: labels),
                  info,
                ],
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  children: [
                    poster,
                    PositionedDirectional(top: 4, end: 4, child: info),
                  ],
                ),
                const SizedBox(height: OrvexMetrics.small),
                labels,
              ],
            ),
    );
  }
}
