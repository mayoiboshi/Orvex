import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../app/orvex_providers.dart';
import '../../../design/orvex_theme.dart';
import '../../../design/back_navigation.dart';
import '../../anime_metadata/application/anime_metadata_controller.dart';
import '../../anime_metadata/presentation/anime_metadata_sheet.dart';
import '../../anime_metadata/presentation/episode_details.dart';
import '../../media_sources/local_file_source.dart';
import '../../media_sources/imported_file_store.dart';
import '../../folder_library/folder_browser.dart';
import '../../folder_library/folder_library.dart';
import '../../library/domain/playback_record.dart';
import '../../library/domain/library_overview.dart';
import '../../library/domain/recent_work.dart';
import '../../library/infrastructure/recent_arrival_index.dart';
import '../../library/presentation/library_views.dart';
import '../../library/presentation/series_library.dart';
import '../application/playback_session.dart';
import '../domain/playback_engine.dart';
import 'playback_surface.dart';
import 'watch_information.dart';

class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key, this.startupError});
  final String? startupError;

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage>
    with WidgetsBindingObserver {
  OrvexColors get _colors => OrvexColors.of(context);
  late LocalFileSource _files;
  late FolderLibrary _folders;
  bool _autoNext = false;
  final _preferences = SharedPreferencesAsync();
  late final _arrivalIndex = RecentArrivalIndex(_preferences);
  Map<String, DateTime> _arrivals = const {};
  String? _homeWorkKey;
  List<LocalMedia> _videos = [];
  List<PlaybackRecord> _history = [];
  bool _loadingLibrary = true;
  bool _showContinue = true;
  bool _showPlayer = false;
  bool _keepLibraryVisible = false;
  ({
    LocalMedia? media,
    List<LocalMedia> playlist,
    bool hasEngine,
    String? error,
  })?
  _observedSession;
  int _tab = 0;
  int _loadGeneration = 0;
  int _openGeneration = 0;
  String _query = '';
  String? _seriesSelection;
  Timer? _catalogTimer;
  String? _libraryError;
  bool _picking = false;
  LibraryImportStatus? _importStatus;
  LibrarySort _librarySort = defaultLibrarySort;
  Future<void> _sortWrites = Future.value();
  int _sortRevision = 0;
  bool _compactLibrary = false;
  bool _fullscreen = false;
  bool _widePlayback = false;
  final _inlinePlayerKey = GlobalKey();
  final _watchBrowserKey = GlobalKey();
  bool _changingFullscreen = false;
  bool _foreground = true;
  ({int revision, List<LocalMedia> imports, List<LocalMedia> videos})?
  _catalogSnapshot;
  ({List<LocalMedia> catalog, List<RecentWork> works})? _recentWorkSnapshot;
  RecentWork? _playbackWork;
  late PlaybackSession _session;
  late AnimeMetadataController _metadata;

  List<LocalMedia> get _catalog {
    final revision = _folders.revision;
    final snapshot = _catalogSnapshot;
    if (snapshot != null &&
        snapshot.revision == revision &&
        identical(snapshot.imports, _videos)) {
      return snapshot.videos;
    }
    final videos = _folders.catalog(_videos);
    _catalogSnapshot = (revision: revision, imports: _videos, videos: videos);
    return videos;
  }

  List<RecentWork> get _recentWorks {
    final catalog = _catalog;
    final cached = _recentWorkSnapshot;
    if (cached != null && identical(cached.catalog, catalog)) {
      return cached.works;
    }
    final works = buildRecentWorks(
      catalog,
      added: _arrivals,
      matchFor: _metadata.matchFor,
      identify: _folders.identityFor,
    );
    _recentWorkSnapshot = (catalog: catalog, works: works);
    return works;
  }

  Future<void> _observeArrivals() async {
    if (_loadingLibrary || _folders.loading || _folders.scanning) return;
    try {
      final next = await _arrivalIndex.observe([
        ..._videos,
        for (final entry in _folders.entries)
          if (!entry.directory) entry.media,
      ]);
      if (mounted && !identical(next, _arrivals)) {
        setState(() {
          _arrivals = next;
          _recentWorkSnapshot = null;
        });
      }
    } catch (_) {
      // Keep browsing available and use modification time if this index fails.
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _files = ref.read(localFilesProvider);
    _folders = ref.read(folderLibraryProvider);
    _folders.addListener(_onFoldersChanged);
    _session = ref.read(sessionProvider);
    _metadata = ref.read(animeMetadataProvider);
    _metadata.addListener(_onMetadataChanged);
    _session.addListener(_onSessionChanged);
    _onSessionChanged();
    unawaited(_reload());
    unawaited(_loadPreferences());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _foreground = true;
      _session.allowAutoNext = _showPlayer;
      unawaited(_reload());
    }
    if ((Platform.isIOS || Platform.isAndroid) &&
        (state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden ||
            state == AppLifecycleState.detached)) {
      _foreground = false;
      ++_openGeneration;
      _session.allowAutoNext = false;
      unawaited(_session.pauseForInterruption());
    } else if (state != AppLifecycleState.resumed) {
      // Native file pickers may make the app inactive; keep playback intent.
      unawaited(_session.checkpoint());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session.removeListener(_onSessionChanged);
    _metadata.removeListener(_onMetadataChanged);
    _folders.removeListener(_onFoldersChanged);
    _catalogTimer?.cancel();
    if (_fullscreen) unawaited(defaultExitNativeFullscreen());
    super.dispose();
  }

  Future<void> _pick({bool subtitle = false}) async {
    if (_picking || widget.startupError != null) return;
    final currentMedia = _session.media;
    final originTab = _tab;
    final originOpen = _openGeneration;
    final libraryImport = !subtitle && _tab == 1 && !_showPlayer;
    String? fileName;
    var reused = false;
    setState(() {
      _picking = true;
      if (!subtitle) _importStatus = null;
    });
    void showTask(
      String title, {
      String? detail,
      double? fraction,
      bool failed = false,
      bool done = false,
    }) {
      if (!mounted) return;
      setState(
        () => _importStatus = (
          title: title,
          detail: [if (fileName != null) fileName!, ?detail].join(' · '),
          fraction: fraction,
          failed: failed,
          active: !failed && !done,
        ),
      );
    }

    try {
      final source = subtitle
          ? await _files.pickSubtitle()
          : await _files.pickVideo(
              onProgress: (update) {
                fileName = update.name;
                switch (update.phase) {
                  case VideoImportPhase.preparing:
                    showTask('正在准备', detail: '第 1 / 1 个文件');
                  case VideoImportPhase.copying:
                    showTask(
                      '正在复制',
                      detail: '第 1 / 1 个文件',
                      fraction: update.fraction,
                    );
                  case VideoImportPhase.checking:
                    showTask('正在校验并整理', detail: '第 1 / 1 个文件');
                  case VideoImportPhase.reused:
                    reused = true;
                }
              },
            );
      if (!mounted || source == null) return;
      if (subtitle) {
        if (identical(currentMedia, _session.media)) {
          await _session.loadSubtitle(source);
          if (mounted && _session.subtitleIssue.isNotEmpty) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(_session.subtitleIssue)));
          }
        }
      } else {
        if (Platform.isIOS || Platform.isAndroid) {
          fileName ??= source.name;
          showTask('正在更新媒体库', detail: '第 1 / 1 个文件');
          await _reload();
          if (!mounted) return;
          showTask(
            reused ? '已在媒体库中' : '导入完成',
            detail: reused ? '已复用 1 个文件' : '成功 1 个',
            done: true,
          );
          // A large import can finish after the app was backgrounded. Leave
          // it in the imported list rather than starting playback unattended.
          if (!_foreground ||
              libraryImport ||
              _tab != originTab ||
              _openGeneration != originOpen) {
            return;
          }
        } else {
          setState(() => _importStatus = null);
        }
        await _open(source);
      }
    } catch (error) {
      if (mounted) {
        if (!subtitle) {
          showTask(
            '导入失败',
            detail: fileName == null ? '$error' : '失败 1 个 · $error',
            failed: true,
          );
        }
        if (!libraryImport && (subtitle || _tab != 1)) {
          _session.reportError('文件未能打开：$error');
        }
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _onSessionChanged() {
    // Position, buffering and tracks belong to the widgets that display them.
    final next = (
      media: _session.media,
      playlist: _session.playlist,
      hasEngine: _session.engine != null,
      error: _session.error,
    );
    if (_observedSession == next) return;
    if (_observedSession?.media?.uri != next.media?.uri) {
      _showPlayer = next.media != null && !_keepLibraryVisible;
    }
    _observedSession = next;
    if (mounted) setState(() {});
  }

  void _onFoldersChanged() {
    _catalogTimer?.cancel();
    _catalogTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      unawaited(_metadata.scan(_catalog));
      unawaited(_observeArrivals());
      setState(() {});
    });
  }

  void _onMetadataChanged() {
    if (mounted) setState(() => _recentWorkSnapshot = null);
  }

  void _showMetadata(LocalMedia media, {List<LocalMedia>? group}) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,

      builder: (_) => AnimeMetadataSheet(
        media: media,
        metadata: _metadata,
        group: group ?? _folders.seriesMembers(media, _videos),
      ),
    );
  }

  Future<void> _loadPreferences() async {
    try {
      final show = await _preferences.getBool('orvex.home.continue.v1') ?? true;
      _autoNext =
          await _preferences.getBool('orvex.player.autoNext.v1') ?? false;
      _session.autoNext = _autoNext;
      if (mounted) setState(() => _showContinue = show);
    } catch (_) {
      if (mounted) setState(() => _libraryError = '首页偏好未能读取');
    }
    final revision = _sortRevision;
    try {
      final saved = (await _preferences.getString('orvex.library.sort.v1'))
          ?.split(':');
      if (!mounted ||
          revision != _sortRevision ||
          revision != 0 ||
          saved?.length != 2) {
        return;
      }
      final field = LibrarySortField.values
          .where((field) => field.name == saved![0])
          .firstOrNull;
      if (field != null && const ['asc', 'desc'].contains(saved![1])) {
        setState(
          () => _librarySort = (field: field, descending: saved[1] == 'desc'),
        );
      }
    } catch (_) {
      // A missing preference leaves the library on its default order.
    }
  }

  void _setLibrarySort(LibrarySort sort) {
    ++_sortRevision;
    setState(() => _librarySort = sort);
    _sortWrites = _sortWrites
        .then(
          (_) => _preferences.setString(
            'orvex.library.sort.v1',
            '${sort.field.name}:${sort.descending ? 'desc' : 'asc'}',
          ),
        )
        .catchError((Object _) {
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('排序偏好未能保存')));
          }
        });
  }

  Future<void> _setShowContinue(bool value) async {
    try {
      await _preferences.setBool('orvex.home.continue.v1', value);
      if (mounted) setState(() => _showContinue = value);
    } catch (_) {
      if (mounted) setState(() => _libraryError = '首页偏好保存失败，请重试');
    }
  }

  Future<void> _reload() async {
    final generation = ++_loadGeneration;
    try {
      final videos = await _files.imports.listVideos();
      final history = await ref
          .read(historyStoreProvider)
          .list(importedVideos: videos);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _videos = videos;
        _history = history;
        _loadingLibrary = false;
        _libraryError = null;
      });
      unawaited(_metadata.scan(_catalog));
      unawaited(_observeArrivals());
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loadingLibrary = false;
        _libraryError = '媒体库未能读取，请下拉重试';
      });
    }
  }

  Future<void> _open(LocalMedia media, {RecentWork? work}) async {
    final generation = ++_openGeneration;
    LocalMedia resolved;
    try {
      resolved = media.folderRoot != null
          ? media
          : await _files.imports.resolve(media);
    } catch (error) {
      if (mounted && generation == _openGeneration) {
        _session.reportError('文件未能打开：$error');
      }
      return;
    }
    if (!mounted || generation != _openGeneration || !_foreground) return;
    final reuse =
        _session.media?.resumeKey == resolved.resumeKey &&
        _session.engine != null;
    _session.allowAutoNext = _foreground;
    setState(() {
      _keepLibraryVisible = false;
      _showPlayer = true;
      if (!reuse || work != null) _playbackWork = work;
    });
    if (!reuse) {
      final queue =
          work?.files ??
          (_folders.identityFor(resolved).episodic
              ? _folders.seriesMembers(resolved, _videos)
              : resolved.folderRoot == null
              ? (_videos.any((v) => v.resumeKey == resolved.resumeKey)
                    ? _videos
                    : [resolved])
              : _folders.playlist(resolved));
      final catalog = _catalog;
      unawaited(
        _metadata.scan([
          ...catalog,
          if (!catalog.any((m) => m.resumeKey == resolved.resumeKey)) resolved,
        ]),
      );
      await _session.open(resolved, queue: queue);
    } else {
      if (work != null) _session.replacePlaylist(work.files);
      if (_session.frame.completed) await _session.seek(Duration.zero);
      if (!_session.frame.playing) await _session.togglePause();
    }
  }

  Future<void> _returnToLibrary() async {
    if (!_showPlayer) return;
    ++_openGeneration;
    _session.allowAutoNext = false;
    setState(() {
      _keepLibraryVisible = true;
      _showPlayer = false;
    });
    await _session.pauseForInterruption();
    if (mounted) await _reload();
  }

  void _selectTab(int value) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _tab = value;
      _homeWorkKey = null;
    });
    unawaited(_reload());
  }

  @override
  Widget build(BuildContext context) => OrvexBackStack(
    pages: [
      orvexNavigationPage(
        context: context,
        key: const ValueKey('library-page'),
        child: _buildShell(watching: false),
      ),
      if (_homeWorkKey case final String key)
        orvexNavigationPage(
          context: context,
          key: ValueKey(key),
          child: _homeWorkPage(key),
        ),
      if (_showPlayer && _session.media != null)
        orvexNavigationPage(
          context: context,
          key: const ValueKey('watch-page'),
          allowSnapshotting: false,
          child: _fullscreen
              ? _fullscreenPlayer()
              : _buildShell(watching: true),
        ),
    ],
    onRemoved: (page) {
      if (page.key == const ValueKey('watch-page')) {
        unawaited(_returnToLibrary());
      } else if (_homeWorkKey case final String key
          when page.key == ValueKey(key)) {
        setState(() => _homeWorkKey = null);
      }
    },
  );

  Widget _buildShell({required bool watching}) {
    final homeHasResume =
        _tab == 0 &&
        _showContinue &&
        _history.any(
          (record) =>
              record.canContinue &&
              record.media.resumeKey == _session.media?.resumeKey,
        );
    final sidebar =
        !watching &&
        (Platform.isMacOS || Platform.isWindows || Platform.isLinux) &&
        MediaQuery.sizeOf(context).width >= 1000;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyO, meta: true): () =>
            _pick(),
        const SingleActivator(LogicalKeyboardKey.keyO, control: true): () =>
            _pick(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: _colors.background,
          extendBody: !watching && !sidebar,
          bottomNavigationBar: watching || sidebar
              ? null
              : LibraryTabBar(selected: _tab, onSelected: _selectTab),
          body: SafeArea(
            bottom: watching,
            child: Row(
              children: [
                if (sidebar) ...[
                  LibrarySidebar(selected: _tab, onSelected: _selectTab),
                  const VerticalDivider(width: 1),
                ],
                Expanded(
                  child: Column(
                    children: [
                      if (const bool.fromEnvironment(
                        'ORVEX_SILENT_SIMULATOR_TEST',
                      ))
                        Padding(
                          padding: EdgeInsets.symmetric(vertical: 4),
                          child: Text(
                            '模拟器无声预览 · 声音待真机验收',
                            style: TextStyle(
                              color: _colors.warning,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      if (widget.startupError ?? _libraryError ?? _session.error
                          case final String message)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                          child: _error(message),
                        ),
                      Expanded(
                        child: watching
                            ? _watchPage()
                            : _tab == 1
                            ? _seriesLibrary()
                            : LibraryViews(
                                tab: _tab,
                                videos: _catalog,
                                history: _history,
                                loading: _loadingLibrary,
                                picking:
                                    _picking || widget.startupError != null,
                                showContinue: _showContinue,
                                query: _query,
                                onQuery: (value) =>
                                    setState(() => _query = value),
                                onImport: () => _pick(),
                                onOpen: (media) => unawaited(_open(media)),
                                onTab: _selectTab,
                                onRefresh: _reload,
                                onShowContinue: (value) =>
                                    unawaited(_setShowContinue(value)),
                                metadata: _metadata,
                                onMetadata: _showMetadata,
                                appearance: ref.read(appearanceProvider),
                                thumbnails: _tab == 0
                                    ? ref.read(thumbnailCacheProvider)
                                    : null,
                                recentWorks: _tab == 0 ? _recentWorks : null,
                                onOpenWork: (work) =>
                                    setState(() => _homeWorkKey = work.key),
                              ),
                      ),
                      if (!watching && _session.media != null && !homeHasResume)
                        Padding(
                          padding: EdgeInsets.only(bottom: sidebar ? 0 : 100),
                          child: _returnToPlayer(),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _returnToPlayer() => Material(
    color: _colors.elevated,
    child: ListTile(
      dense: true,
      leading: Icon(Icons.movie_outlined, color: _colors.accent),
      title: Text(
        mediaTitle(_session.media!.name),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: ListenableBuilder(
        listenable: _session,
        builder: (context, _) => Text(
          '${_session.frame.playing ? '正在播放' : '已暂停'} · ${formatTime(_session.frame.position)}',
          style: TextStyle(
            fontSize: 11,
            color: OrvexColors.of(context).secondary,
          ),
        ),
      ),
      trailing: const Icon(Icons.open_in_full_rounded, size: 20),
      onTap: () => setState(() {
        _keepLibraryVisible = false;
        _showPlayer = true;
        _session.allowAutoNext = _foreground;
      }),
    ),
  );

  Widget _seriesLibrary() => SeriesLibrary(
    library: _folders,
    thumbnails: ref.read(thumbnailCacheProvider),
    imported: _videos,
    history: _history,
    metadata: _metadata,
    onOpen: (media) => unawaited(_open(media)),
    onImport: _picking || widget.startupError != null ? null : () => _pick(),
    onMetadata: _showMetadata,
    arrivals: _arrivals,
    sort: _librarySort,
    onSort: _setLibrarySort,
    compact: _compactLibrary,
    onCompact: (compact) => setState(() => _compactLibrary = compact),
    importStatus: _importStatus,
    onDismissImport: () => setState(() => _importStatus = null),
    selection: _seriesSelection,
    onSelection: (key) => _seriesSelection = key,
  );

  Widget _homeWorkPage(String key) {
    final work = _recentWorks.where((item) => item.key == key).firstOrNull;
    final subject = work?.subject;
    return Scaffold(
      backgroundColor: _colors.background,
      appBar: AppBar(
        leading: BackButton(
          onPressed: () => setState(() => _homeWorkKey = null),
        ),
        title: Text(subject?.title ?? '作品详情'),
        actions: [
          if (work != null)
            IconButton(
              tooltip: '番剧资料',
              onPressed: () =>
                  _showMetadata(work.representative, group: work.files),
              icon: const Icon(Icons.info_outline_rounded),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: work == null
            ? const Center(child: Text('暂无可用的单集'))
            : FolderBrowser(
                library: _folders,
                thumbnails: ref.read(thumbnailCacheProvider),
                imported: _videos,
                history: _history,
                metadata: _metadata,
                collection: work.files,
                collectionTitle: subject?.title,
                onOpen: (media) => unawaited(_open(media, work: work)),
                onImport: () => _pick(),
                onMetadata: (media) => _showMetadata(media, group: work.files),
              ),
      ),
    );
  }

  RecentWork? _playbackWorkFor(LocalMedia media) {
    final work = _playbackWork;
    return work != null &&
            work.files.any((item) => item.resumeKey == media.resumeKey)
        ? work
        : null;
  }

  Widget _folderBrowser({Widget? header}) => FolderBrowser(
    key: _watchBrowserKey,
    library: _folders,
    thumbnails: ref.read(thumbnailCacheProvider),
    imported: _videos,
    history: _history,
    metadata: _metadata,
    current: _session.media,
    playback: _session,
    collection: _playbackWork != null
        ? _session.playlist
        : _session.media != null &&
              _folders.identityFor(_session.media!).episodic
        ? _folders.seriesMembers(_session.media!, _videos)
        : null,
    collectionTitle:
        _playbackWork?.subject?.title ??
        (_session.media == null
            ? null
            : _folders.identityFor(_session.media!).title),
    header: header,
    onOpen: (media) => unawaited(_open(media, work: _playbackWorkFor(media))),
    onImport: () => _pick(),
    onMetadata: _showPlaybackMetadata,
  );

  void _showPlaybackMetadata(LocalMedia media) =>
      _showMetadata(media, group: _playbackWorkFor(media)?.files);

  Widget _watchPage() {
    final media = _session.media!;
    final root = _folders.root(media.folderRoot ?? '');
    final subject = _metadata.subjectFor(media);
    final identity = _folders.identityFor(media);
    final episodeNumber = identity.episode;
    final title =
        subject?.title ??
        (identity.title.isNotEmpty ? identity.title : mediaTitle(media.name));
    return LayoutBuilder(
      builder: (context, constraints) {
        final desktop =
            Platform.isMacOS || Platform.isWindows || Platform.isLinux;
        final display = View.of(context).display;
        final tablet =
            Platform.isIOS &&
            display.size.shortestSide / display.devicePixelRatio >= 600;
        final allowWide = (desktop || tablet) && constraints.maxWidth >= 1000;
        final sideBySide = allowWide && !_widePlayback;
        final pageWidth = desktop
            ? constraints.maxWidth.clamp(0.0, sideBySide ? 1440.0 : 1100.0)
            : constraints.maxWidth;
        final sideWidth = (pageWidth * 0.31).clamp(336.0, 392.0);
        final mainWidth = sideBySide
            ? pageWidth - sideWidth - OrvexMetrics.gap
            : pageWidth;
        final spacious = pageWidth >= 600;
        final edgeToEdge = tablet || sideBySide;
        final gutter = edgeToEdge || !spacious
            ? 0.0
            : pageWidth >= 1000
            ? OrvexMetrics.page
            : OrvexMetrics.gap;
        final maxVideoHeight = (constraints.maxHeight - 80)
            .clamp(140.0, 700.0)
            .toDouble();
        final videoWidth = (mainWidth - gutter * 2)
            .clamp(0.0, maxVideoHeight * 16 / 9)
            .toDouble();
        final header = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 12, 10),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '返回首页',
                    onPressed: () => _returnToLibrary(),
                    icon: const Icon(
                      Icons.arrow_back_ios_new_rounded,
                      size: 20,
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          root?.name ?? '本地文件',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: _colors.secondary),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '视频操作',
                    icon: Icon(
                      Icons.more_horiz_rounded,
                      size: OrvexMetrics.iconSize,
                      color: _colors.secondary,
                    ),
                    onSelected: (value) {
                      if (value == 'close') {
                        unawaited(_session.close());
                        return;
                      }
                      showDialog<void>(
                        context: context,
                        builder: (dialogContext) => AlertDialog(
                          title: const Text('文件详情'),
                          content: SelectableText(
                            '${media.name}\n\n${root == null ? '本地文件' : '${root.name} / ${_folders.entry(media)?.parent ?? ''}'}',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(dialogContext),
                              child: const Text('关闭'),
                            ),
                          ],
                        ),
                      );
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'details', child: Text('文件详情')),
                      PopupMenuItem(value: 'close', child: Text('关闭视频')),
                    ],
                  ),
                  IconButton(
                    tooltip: '播放手势帮助',
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: const Text('播放操作'),
                        content: Text(
                          Platform.isIOS || Platform.isAndroid
                              ? '单击显示或隐藏控制栏。左右双击快退或快进 10 秒；中央长按临时 2 倍速。左侧上下滑动调亮度（设备支持时），右侧调音量。'
                              : '单击显示或隐藏控制栏；双击全屏。空格播放或暂停，左右方向键快退或快进。',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(dialogContext),
                            child: const Text('知道了'),
                          ),
                        ],
                      ),
                    ),
                    icon: const Icon(Icons.help_outline_rounded, size: 20),
                  ),
                  IconButton(
                    tooltip: '打开本地视频',
                    onPressed: _picking ? null : () => _pick(),
                    icon: const Icon(
                      Icons.add_rounded,
                      size: OrvexMetrics.iconSize,
                    ),
                  ),
                ],
              ),
            ),
            Align(
              alignment: edgeToEdge ? Alignment.centerLeft : Alignment.center,
              child: SizedBox(
                width: videoWidth,
                child: _player(
                  radius: edgeToEdge || !spacious
                      ? 0
                      : OrvexMetrics.smallRadius,
                  allowWide: allowWide,
                ),
              ),
            ),
            WatchInformation(
              title: title,
              episode: episodeNumber == null ? '' : '第 $episodeNumber 集',
              episodeDetails: subject == null || episodeNumber == null
                  ? null
                  : EpisodeDetails(
                      key: ValueKey((
                        media.resumeKey,
                        subject.id,
                        episodeNumber,
                        _metadata.automatic,
                      )),
                      metadata: _metadata,
                      media: media,
                      subjectId: subject.id,
                      number: episodeNumber,
                      automatic: _metadata.automatic,
                    ),
              progress: ListenableBuilder(
                listenable: _session,
                builder: (context, _) => Text(
                  _session.loading
                      ? '正在打开…'
                      : '${formatTime(_session.frame.position)} / ${formatTime(_session.frame.duration)}',
                ),
              ),
              linked: subject != null,
              onMetadata: () => _showPlaybackMetadata(media),
              onPrevious: _session.hasPrevious
                  ? () => _session.previous()
                  : null,
              onNext: _session.hasNext ? () => _session.next() : null,
              autoNext: _autoNext,
              onAutoNext: (value) => _setAutoNext(value),
            ),
          ],
        );
        return Center(
          child: SizedBox(
            width: pageWidth,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (sideBySide) ...[
                  Expanded(
                    child: SingleChildScrollView(
                      key: const PageStorageKey('watch-info-scroll'),
                      child: header,
                    ),
                  ),
                  const SizedBox(width: OrvexMetrics.gap),
                  SizedBox(
                    width: sideWidth,
                    child: DecoratedBox(
                      key: const ValueKey('watch-episodes-panel'),
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(color: _colors.divider),
                        ),
                      ),
                      child: _folderBrowser(),
                    ),
                  ),
                ] else
                  Expanded(child: _folderBrowser(header: header)),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _setAutoNext(bool value) async {
    setState(() {
      _autoNext = value;
      _session.autoNext = value;
    });
    try {
      await _preferences.setBool('orvex.player.autoNext.v1', value);
    } catch (_) {
      _session.reportError('自动播放设置未能保存');
    }
  }

  Future<void> _toggleFullscreen() async {
    if (!_session.ready || _changingFullscreen) return;
    _changingFullscreen = true;
    final entering = !_fullscreen;
    try {
      if (entering) {
        await defaultEnterNativeFullscreen();
      } else {
        await defaultExitNativeFullscreen();
      }
      if (mounted) {
        setState(() => _fullscreen = entering);
      } else if (entering) {
        await defaultExitNativeFullscreen();
      }
    } catch (_) {
      if (mounted) _session.reportError('无法切换全屏，请重试');
    } finally {
      _changingFullscreen = false;
    }
  }

  Widget _surface({bool allowWide = false}) => PlaybackSurface(
    key: ValueKey('${_session.media?.uri}:$_fullscreen'),
    session: _session,
    fullscreen: _fullscreen,
    onFullscreen: () => _toggleFullscreen(),
    onSubtitle: () => _pick(subtitle: true),
    onBack: () => _returnToLibrary(),
    title: _session.media == null
        ? null
        : folderMediaTitle(_session.media!, _metadata),
    wide: _widePlayback,
    onToggleWide: allowWide
        ? () => setState(() => _widePlayback = !_widePlayback)
        : null,
  );

  Widget _fullscreenPlayer() => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_toggleFullscreen());
    },
    child: AnnotatedRegion<SystemUiOverlayStyle>(
      value: OrvexTheme.systemOverlay(Brightness.dark)
          .copyWith(systemNavigationBarColor: OrvexColors.player.background),
      child: Scaffold(
        backgroundColor: OrvexColors.player.background,
        body: Stack(
          children: [
            Positioned.fill(child: _surface()),
            if (_session.error case final String message)
              Positioned(top: 70, left: 20, right: 20, child: _error(message)),
          ],
        ),
      ),
    ),
  );

  Widget _player({required double radius, bool allowWide = false}) => Container(
    // Keep the video/control subtree alive when it moves between layouts.
    key: _inlinePlayerKey,
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: OrvexColors.player.background,
      borderRadius: BorderRadius.circular(radius),
    ),
    child: AspectRatio(
      aspectRatio: 16 / 9,
      child: _session.engine == null
          ? const Center(child: CircularProgressIndicator())
          : _surface(allowWide: allowWide),
    ),
  );

  Widget _error(String message) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: _colors.error.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(OrvexMetrics.controlRadius),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline_rounded, color: _colors.error, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: SelectableText(
            message,
            style: TextStyle(color: _colors.error),
          ),
        ),
      ],
    ),
  );
}
