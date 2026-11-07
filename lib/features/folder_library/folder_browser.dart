import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../design/glass.dart';
import '../../design/back_navigation.dart';
import '../../design/orvex_theme.dart';
import '../anime_metadata/application/anime_metadata_controller.dart';
import '../anime_metadata/domain/anime_filename.dart';
import '../library/domain/playback_record.dart';
import '../library/presentation/library_views.dart' show mediaTitle;
import '../player/application/playback_session.dart';
import '../player/domain/playback_engine.dart';
import '../player/presentation/playback_surface.dart';
import 'folder_library.dart';
import 'folder_models.dart';
import 'thumbnail_cache.dart';

String folderMediaTitle(LocalMedia media, AnimeMetadataController metadata) {
  final subject = metadata.subjectFor(media);
  final parsed = AnimeFilename.parse(media.name);
  if (subject != null) {
    return '${subject.title}${parsed.episode == null ? '' : ' · ${parsed.episodeLabel}'}';
  }
  if (parsed.episode != null && parsed.title.isNotEmpty) {
    return '${parsed.title} · ${parsed.episodeLabel}';
  }
  return mediaTitle(media.name);
}

class FolderBrowser extends StatefulWidget {
  const FolderBrowser({
    super.key,
    required this.library,
    required this.thumbnails,
    required this.imported,
    required this.history,
    required this.metadata,
    required this.onOpen,
    required this.onImport,
    required this.onMetadata,
    this.current,
    this.header,
    this.playback,
    this.collection,
    this.collectionTitle,
  });
  final FolderLibrary library;
  final ThumbnailCache thumbnails;
  final List<LocalMedia> imported;
  final List<PlaybackRecord> history;
  final AnimeMetadataController metadata;
  final ValueChanged<LocalMedia> onOpen, onMetadata;
  final VoidCallback onImport;
  final LocalMedia? current;
  final Widget? header;
  final PlaybackSession? playback;
  final List<LocalMedia>? collection;
  final String? collectionTitle;
  @override
  State<FolderBrowser> createState() => _FolderBrowserNavigationState();
}

class _FolderBrowserNavigationState extends State<FolderBrowser> {
  final _locations = <({int id, String? root, String path})>[
    (id: 0, root: null, path: ''),
  ];
  int _nextId = 1;

  void _navigate(String? root, String path) {
    final previous = _locations.lastIndexWhere(
      (location) => location.root == root && location.path == path,
    );
    setState(() {
      if (previous >= 0) {
        _locations.removeRange(previous + 1, _locations.length);
      } else {
        _locations.add((id: _nextId++, root: root, path: path));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // A watch header contains the one live video surface. Its directory strips
    // stay in place; only standalone library browsing keeps folder page history.
    if (widget.header != null ||
        widget.current != null ||
        widget.collection != null) {
      return _FolderBrowserContent(source: widget);
    }
    return OrvexBackStack(
      pages: [
        for (final location in _locations)
          orvexNavigationPage(
            context: context,
            key: ValueKey('folder-location-${location.id}'),
            child: _FolderBrowserContent(
              source: widget,
              root: location.root,
              path: location.path,
              onNavigate: _navigate,
            ),
          ),
      ],
      onRemoved: (page) {
        final index = _locations.indexWhere(
          (location) => page.key == ValueKey('folder-location-${location.id}'),
        );
        if (index > 0) {
          setState(() => _locations.removeRange(index, _locations.length));
        }
      },
    );
  }
}

class _FolderBrowserContent extends StatefulWidget {
  const _FolderBrowserContent({
    required this.source,
    this.root,
    this.path = '',
    this.onNavigate,
  });
  final FolderBrowser source;
  final String? root;
  final String path;
  final void Function(String?, String)? onNavigate;
  @override
  State<_FolderBrowserContent> createState() => _FolderBrowserState();
}

class _FolderBrowserState extends State<_FolderBrowserContent> {
  FolderBrowser get config => widget.source;
  String? _root;
  String _path = '', _query = '';
  bool _unwatched = false;
  bool _showSearch = false;
  bool _useCollection = true;
  final _scroll = ScrollController();
  final _breadcrumbs = ScrollController();
  String? _sourceKey;
  List<LocalMedia> _source = const [];
  List<LocalMedia>? _importedSource;
  final _header = GlobalKey();
  double get _rowHeight =>
      (_watching ? 120 : 112) *
      (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(1, 3);
  FolderLibrary get library => config.library;
  bool get _watching => config.current != null || config.header != null;

  @override
  void initState() {
    super.initState();
    _locate(onlyIfFar: true);
    if (widget.onNavigate != null) {
      _root = widget.root;
      _path = widget.path;
    }
    _showSearch = !_watching;
  }

  @override
  void didUpdateWidget(_FolderBrowserContent old) {
    super.didUpdateWidget(old);
    if (old.source.header == null && config.header != null) {
      // Returning to wide mode must reveal the player above the list.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
      });
    }
    if (old.source.current?.resumeKey != config.current?.resumeKey) {
      _locate(onlyIfFar: true);
    }
  }

  void _toggleSearch() {
    setState(() => _showSearch = !_showSearch);
    if (_showSearch && config.header == null && _scroll.hasClients) {
      _scroll.animateTo(
        0,
        duration: OrvexMetrics.duration(context),
        curve: OrvexMetrics.curve,
      );
    }
  }

  void _locate({bool scroll = true, bool onlyIfFar = false}) {
    final current = config.current == null
        ? null
        : library.entry(config.current!);
    _root = current?.rootId;
    _path = current?.parent ?? '';
    _query = '';
    _unwatched = false;
    _useCollection = true;
    _revealBreadcrumb();
    if (scroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        final index = _items().indexWhere(
          (m) => m.resumeKey == config.current?.resumeKey,
        );
        if (onlyIfFar && index < 3) return;
        final height = _header.currentContext?.size?.height ?? 0;
        _scroll.animateTo(
          (height + index.clamp(0, 100000) * _rowHeight - 130).clamp(
            0,
            _scroll.position.maxScrollExtent,
          ),
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : OrvexMetrics.motion,
          curve: OrvexMetrics.curve,
        );
      });
    }
  }

  void _navigate(String? root, String path) {
    if (widget.onNavigate != null) {
      widget.onNavigate!(root, path);
      return;
    }
    setState(() {
      _root = root;
      _path = path;
      _query = '';
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _revealBreadcrumb();
  }

  void _revealBreadcrumb() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _breadcrumbs.hasClients) {
        _breadcrumbs.jumpTo(_breadcrumbs.position.maxScrollExtent);
      }
    });
  }

  PlaybackRecord? _record(LocalMedia media) => config.history
      .where((r) => r.media.resumeKey == media.resumeKey)
      .firstOrNull;
  List<LocalMedia> _items() {
    final sourceKey =
        '${library.revision}:$_root:$_path:$_useCollection:${identityHashCode(config.collection)}';
    if (_sourceKey != sourceKey ||
        !identical(_importedSource, config.imported)) {
      _sourceKey = sourceKey;
      _importedSource = config.imported;
      _source = config.collection != null && _useCollection
          ? config.collection!
          : _root == null
          ? config.imported
          : library
                .children(_root!, _path, directories: false)
                .map((e) => e.media)
                .toList();
    }
    if (_query.isEmpty && !_unwatched) return _source;
    return _source
        .where(
          (media) =>
              (_query.isEmpty ||
                  '${media.name} ${folderMediaTitle(media, config.metadata)}'
                      .toLowerCase()
                      .contains(_query.toLowerCase())) &&
              (!_unwatched || _record(media) == null),
        )
        .toList();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _breadcrumbs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: library,
    builder: (context, _) {
      final colors = OrvexColors.of(context);
      final root = _root == null ? null : library.root(_root!);
      final grouped = config.collection != null && _useCollection;
      final items = _items();
      final folders = root == null
          ? <FolderEntry>[]
          : library.children(root.id, _path, directories: true);
      final segments = _path.isEmpty ? <String>[] : _path.split('/');
      final levels = <String>[
        '',
        for (var i = 1; i <= segments.length; i++) segments.take(i).join('/'),
      ];
      final sideList = _watching && config.header == null;
      final toolbar = Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 16, 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _watching ? '播放列表' : '媒体库',
                style: _watching
                    ? Theme.of(context).textTheme.titleMedium
                    : Theme.of(context).textTheme.titleLarge,
              ),
            ),
            if (config.collection != null && config.current != null)
              IconButton(
                tooltip: grouped ? '浏览文件夹' : '浏览同一剧集',
                onPressed: () =>
                    setState(() => _useCollection = !_useCollection),
                icon: Icon(
                  grouped
                      ? Icons.folder_outlined
                      : Icons.video_library_outlined,
                ),
              ),
            if (_watching)
              IconButton(
                tooltip: '搜索和筛选列表',
                onPressed: _toggleSearch,
                icon: Icon(
                  _showSearch ? Icons.search_off_rounded : Icons.search_rounded,
                ),
              ),
            if (config.current != null)
              IconButton(
                tooltip: '定位当前视频',
                onPressed: () => setState(() => _locate()),
                icon: const Icon(Icons.my_location_rounded),
              ),
            if (!_watching) ...[
              IconButton(
                tooltip: '导入单个视频副本',
                onPressed: config.onImport,
                icon: const Icon(Icons.note_add_outlined),
              ),
              GlassIconButton(
                tooltip: '添加媒体文件夹',
                onPressed: library.scanning ? null : () => library.add(),
                icon: Icons.create_new_folder_outlined,
              ),
            ],
          ],
        ),
      );
      final content = CustomScrollView(
        controller: _scroll,
        key: PageStorageKey(_watching ? 'folder-player' : 'folder-library'),
        slivers: [
          SliverToBoxAdapter(
            child: Column(
              key: _header,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (config.header != null) config.header!,
                if (!sideList) toolbar,
                if (library.scanning)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      children: [
                        const LinearProgressIndicator(minHeight: 2),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '已读取 ${library.foldersScanned} 个目录 · 发现 ${library.discovered} 个视频',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                            TextButton(
                              onPressed: library.cancelScan,
                              child: const Text('取消'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                if (library.error != null)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      library.error!,
                      style: TextStyle(color: colors.error),
                    ),
                  ),
                if (!grouped && root == null && library.roots.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      children: [
                        for (final source in library.roots)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              Icons.folder_open_rounded,
                              color: colors.accent,
                            ),
                            title: Text(
                              source.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              source.issue ??
                                  (source.scannedAt == null
                                      ? '等待扫描'
                                      : '${library.entries.where((e) => e.rootId == source.id && !e.directory && e.available).length} 个视频 · 已缓存目录'),
                              maxLines: 2,
                              style: TextStyle(
                                fontSize: 12,
                                color: source.issue == null
                                    ? colors.secondary
                                    : colors.warning,
                              ),
                            ),
                            trailing: _rootMenu(source),
                            onTap: () => _navigate(source.id, ''),
                          ),
                        const Divider(),
                      ],
                    ),
                  ),
                if (!grouped && root != null) ...[
                  Padding(
                    padding: const EdgeInsets.only(left: 12, right: 12),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: '返回上一层目录',
                          onPressed: () => _navigate(
                            _path.isEmpty ? null : root.id,
                            parentPath(_path),
                          ),
                          icon: const Icon(Icons.arrow_back_rounded, size: 20),
                        ),
                        Expanded(
                          child: SingleChildScrollView(
                            controller: _breadcrumbs,
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                TextButton(
                                  onPressed: () => _navigate(null, ''),
                                  child: const Text('媒体库'),
                                ),
                                for (var i = 0; i < levels.length; i++) ...[
                                  Icon(
                                    Icons.chevron_right_rounded,
                                    size: 15,
                                    color: colors.secondary,
                                  ),
                                  TextButton(
                                    onPressed: () =>
                                        _navigate(root.id, levels[i]),
                                    child: Text(
                                      i == 0 ? root.name : segments[i - 1],
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                        _rootMenu(root),
                      ],
                    ),
                  ),
                  if (root.issue != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              root.issue!,
                              style: TextStyle(
                                color: colors.warning,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: () => library.add(reauthorize: root),
                            child: const Text('重新授权'),
                          ),
                        ],
                      ),
                    ),
                  // Each horizontal strip represents one real directory level.
                  for (final level in levels)
                    if (library
                        .children(root.id, level, directories: true)
                        .isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2, bottom: 2),
                        child: SizedBox(
                          height: 36,
                          child: ListView.separated(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            scrollDirection: Axis.horizontal,
                            itemCount: library
                                .children(root.id, level, directories: true)
                                .length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(width: 8),
                            itemBuilder: (context, i) {
                              final folder = library.children(
                                root.id,
                                level,
                                directories: true,
                              )[i];
                              final selected =
                                  _path == folder.path ||
                                  _path.startsWith('${folder.path}/');
                              return ChoiceChip(
                                label: Text(folder.name),
                                visualDensity: VisualDensity.compact,
                                selected: selected,
                                showCheckmark: false,
                                onSelected: (_) =>
                                    _navigate(root.id, folder.path),
                              );
                            },
                          ),
                        ),
                      ),
                ],
                if (_showSearch)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            key: ValueKey('folder-search-$_root-$_path'),
                            initialValue: _query,
                            onChanged: (value) =>
                                setState(() => _query = value),
                            decoration: InputDecoration(
                              isDense: true,
                              prefixIcon: const Icon(
                                Icons.search_rounded,
                                size: 20,
                              ),
                              hintText: grouped
                                  ? '搜索剧集'
                                  : root == null
                                  ? '搜索已导入的视频'
                                  : '搜索当前文件夹',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilterChip(
                          label: const Text('未播放'),
                          selected: _unwatched,
                          onSelected: (value) =>
                              setState(() => _unwatched = value),
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
                  child: Text(
                    '${grouped
                        ? config.collectionTitle ?? '剧集'
                        : root == null
                        ? '已导入'
                        : _path.isEmpty
                        ? root.name
                        : leafName(_path)} · ${items.length} 个视频',
                    style: TextStyle(color: colors.secondary, fontSize: 12),
                  ),
                ),
                if (items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 28,
                    ),
                    child: Center(
                      child: Column(
                        children: [
                          Icon(
                            folders.isNotEmpty
                                ? Icons.folder_copy_outlined
                                : Icons.video_library_outlined,
                            color: colors.secondary,
                            size: 32,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            folders.isNotEmpty
                                ? '选择上方文件夹，浏览其中的视频'
                                : _query.isNotEmpty || _unwatched
                                ? '没有符合条件的视频'
                                : '这里还没有视频',
                            style: TextStyle(color: colors.secondary),
                          ),
                          if (root == null && !_watching)
                            TextButton.icon(
                              onPressed: library.scanning
                                  ? null
                                  : () => library.add(),
                              icon: const Icon(Icons.add_rounded),
                              label: const Text('选择媒体根目录 · 保留原文件'),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          SliverFixedExtentList(
            itemExtent: _rowHeight,
            delegate: SliverChildBuilderDelegate((context, index) {
              final media = items[index];
              final current = media.resumeKey == config.current?.resumeKey;
              return _VideoRow(
                key: ValueKey(media.resumeKey),
                media: media,
                entry: library.entry(media),
                thumbnails: config.thumbnails,
                revision: library.revision,
                title: folderMediaTitle(media, config.metadata),
                record: _record(media),
                current: current,
                playback: current ? config.playback : null,
                playbackList: _watching,
                onTap: () => config.onOpen(media),
                onMetadata: () => config.onMetadata(media),
              );
            }, childCount: items.length),
          ),
          SliverToBoxAdapter(child: SizedBox(height: _watching ? 28 : 120)),
        ],
      );
      return sideList
          ? Column(
              children: [
                toolbar,
                Expanded(child: content),
              ],
            )
          : content;
    },
  );

  Widget _rootMenu(FolderRoot root) => PopupMenuButton<String>(
    tooltip: '目录操作',
    onSelected: (value) =>
        value == 'scan' ? library.scan(root) : library.add(reauthorize: root),
    itemBuilder: (_) => [
      PopupMenuItem(
        value: 'scan',
        enabled: !library.scanning,
        child: const Text('重新扫描'),
      ),
      PopupMenuItem(
        value: 'grant',
        enabled: !library.scanning,
        child: const Text('重新授权原目录'),
      ),
    ],
  );
}

class _VideoRow extends StatefulWidget {
  const _VideoRow({
    super.key,
    required this.media,
    required this.entry,
    required this.thumbnails,
    required this.revision,
    required this.title,
    required this.record,
    required this.current,
    this.playback,
    required this.playbackList,
    required this.onTap,
    required this.onMetadata,
  });
  final LocalMedia media;
  final FolderEntry? entry;
  final ThumbnailCache thumbnails;
  final String title;
  final int revision;
  final PlaybackRecord? record;
  final PlaybackSession? playback;
  final bool current, playbackList;
  final VoidCallback onTap, onMetadata;
  @override
  State<_VideoRow> createState() => _VideoRowState();
}

class _VideoRowState extends State<_VideoRow> {
  ThumbnailRequest? _request;
  File? _file;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_VideoRow old) {
    super.didUpdateWidget(old);
    if (old.entry?.cacheVersion != widget.entry?.cacheVersion ||
        (_file == null && old.revision != widget.revision)) {
      _request?.cancel();
      _file = null;
      _load();
    }
  }

  void _load() {
    final entry = widget.entry;
    if (entry == null && widget.media.relativeImportPath == null) return;
    final request = entry == null
        ? widget.thumbnails.requestImported(widget.media)
        : widget.thumbnails.request(entry);
    _request = request;
    unawaited(
      request.result.then((file) {
        if (mounted && identical(_request, request)) {
          setState(() => _file = file);
        }
      }),
    );
  }

  @override
  void dispose() {
    _request?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playback = widget.playback;
    if (playback == null) return _buildRow(context);
    return ListenableBuilder(
      listenable: playback,
      builder: (context, _) {
        final frame = playback.frame;
        final matches = playback.media?.resumeKey == widget.media.resumeKey;
        return _buildRow(
          context,
          matches && frame.duration > Duration.zero ? frame : null,
        );
      },
    );
  }

  Widget _buildRow(BuildContext context, [PlaybackFrame? frame]) {
    final colors = OrvexColors.of(context);
    final record = widget.record;
    final position = frame?.position ?? record?.position;
    final duration =
        frame?.duration ??
        record?.duration ??
        Duration(
          milliseconds: widget.entry?.duration ?? _request?.duration ?? 0,
        );
    final status = widget.current
        ? '当前播放'
        : record?.completed == true
        ? '已看完'
        : record != null
        ? '看到 ${formatTime(record.position)}'
        : '未播放';
    final size = widget.entry?.size ?? 0;
    final metadata = [
      if (duration > Duration.zero) formatTime(duration),
      if (size > 0)
        size >= 1073741824
            ? '${(size / 1073741824).toStringAsFixed(1)} GB'
            : '${(size / 1048576).toStringAsFixed(1)} MB',
    ].join(' · ');
    return LayoutBuilder(
      builder: (context, constraints) => Semantics(
        selected: widget.current,
        child: InkWell(
          onTap: widget.onTap,
          hoverColor: colors.accent.withValues(alpha: 0.055),
          focusColor: colors.accent.withValues(alpha: 0.1),
          child: Stack(
            fit: StackFit.expand,
            children: [
              AnimatedContainer(
                duration: OrvexMetrics.duration(context),
                padding: widget.playbackList
                    ? const EdgeInsets.fromLTRB(16, 12, 4, 12)
                    : const EdgeInsets.fromLTRB(20, 10, 8, 10),
                color: widget.current
                    ? colors.accent.withValues(alpha: 0.055)
                    : null,
                child: Row(
                  children: [
                    SizedBox(
                      width: widget.playbackList
                          ? (constraints.maxWidth * 0.35).clamp(116.0, 156.0)
                          : constraints.maxWidth < 380
                          ? 110
                          : 136,
                      child: AspectRatio(
                        aspectRatio: 16 / 9,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(
                            OrvexMetrics.smallRadius,
                          ),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ColoredBox(
                                color: colors.elevated,
                                child: _file == null
                                    ? (_request != null &&
                                              !_request!.completer.isCompleted
                                          ? const Center(
                                              child: SizedBox(
                                                width: 18,
                                                height: 18,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 1.5,
                                                    ),
                                              ),
                                            )
                                          : Tooltip(
                                              message:
                                                  _request?.issue ?? '视频预览',
                                              child: Icon(
                                                _request?.issue == null
                                                    ? Icons
                                                          .play_circle_outline_rounded
                                                    : Icons
                                                          .image_not_supported_outlined,
                                                color: colors.secondary
                                                    .withValues(alpha: 0.5),
                                                size: 28,
                                              ),
                                            ))
                                    : Image.file(
                                        _file!,
                                        fit: BoxFit.cover,
                                        cacheWidth: 480,
                                        errorBuilder: (_, _, _) => Icon(
                                          Icons.movie_outlined,
                                          color: colors.secondary,
                                        ),
                                      ),
                              ),
                              if (position != null &&
                                  duration.inMilliseconds > 0)
                                Positioned(
                                  bottom: 0,
                                  left: 0,
                                  right: 0,
                                  child: LinearProgressIndicator(
                                    value:
                                        (position.inMilliseconds /
                                                duration.inMilliseconds)
                                            .clamp(0, 1),
                                    minHeight: 2,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: OrvexMetrics.gap),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              height: 1.3,
                              fontWeight: FontWeight.w600,
                              color: widget.current
                                  ? colors.accent
                                  : colors.text,
                            ),
                          ),
                          const SizedBox(height: 6),
                          if (!widget.playbackList || metadata.isNotEmpty)
                            Text(
                              widget.playbackList
                                  ? metadata
                                  : [
                                      metadata,
                                      status,
                                    ].where((s) => s.isNotEmpty).join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(color: colors.secondary),
                            ),
                          if (widget.playbackList) ...[
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                if (widget.current) ...[
                                  Icon(
                                    Icons.play_arrow_rounded,
                                    size: 14,
                                    color: colors.accent,
                                  ),
                                  const SizedBox(width: 3),
                                ],
                                Expanded(
                                  child: Text(
                                    status,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: widget.current
                                              ? colors.accent
                                              : colors.secondary,
                                          fontWeight: widget.current
                                              ? FontWeight.w600
                                              : FontWeight.w400,
                                        ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '番剧资料',
                      onPressed: widget.onMetadata,
                      icon: Icon(
                        Icons.info_outline_rounded,
                        size: 18,
                        color: colors.secondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.playbackList && widget.current)
                Positioned(
                  left: 0,
                  top: 14,
                  bottom: 14,
                  width: 3,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.accent,
                      borderRadius: BorderRadius.circular(
                        OrvexMetrics.pillRadius,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
