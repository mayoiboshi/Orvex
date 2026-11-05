import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../app/orvex_app.dart';
import '../../anime_metadata/application/anime_metadata_controller.dart';
import '../../anime_metadata/presentation/anime_metadata_sheet.dart';
import '../../media_sources/local_file_source.dart';
import '../../library/domain/playback_record.dart';
import '../../library/presentation/library_views.dart';
import '../application/playback_session.dart';
import '../domain/playback_engine.dart';
import 'playback_surface.dart';

class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key, this.startupError});
  final String? startupError;

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage>
    with WidgetsBindingObserver {
  late LocalFileSource _files;
  final _preferences = SharedPreferencesAsync();
  List<LocalMedia> _videos = [];
  List<PlaybackRecord> _history = [];
  bool _loadingLibrary = true;
  bool _showContinue = true;
  bool _showPlayer = false;
  Uri? _observedMedia;
  int _tab = 0;
  int _loadGeneration = 0;
  int _openGeneration = 0;
  String _query = '';
  String? _libraryError;
  bool _picking = false;
  bool _fullscreen = false;
  bool _foreground = true;
  late PlaybackSession _session;
  late AnimeMetadataController _metadata;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _files = ref.read(localFilesProvider);
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
      unawaited(_reload());
    }
    if ((Platform.isIOS || Platform.isAndroid) &&
        (state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden ||
            state == AppLifecycleState.detached)) {
      _foreground = false;
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
    if (_fullscreen) unawaited(defaultExitNativeFullscreen());
    super.dispose();
  }

  Future<void> _pick({bool subtitle = false}) async {
    if (_picking || widget.startupError != null) return;
    final currentMedia = _session.media;
    setState(() => _picking = true);
    try {
      final source = subtitle
          ? await _files.pickSubtitle()
          : await _files.pickVideo();
      if (!mounted || source == null) return;
      if (subtitle) {
        if (identical(currentMedia, _session.media)) {
          await _session.loadSubtitle(source);
        }
      } else {
        if (Platform.isIOS || Platform.isAndroid) {
          unawaited(_reload());
          // A large import can finish after the app was backgrounded. Leave
          // it in the imported list rather than starting playback unattended.
          if (!_foreground) return;
        }
        await _open(source);
      }
    } catch (error) {
      if (mounted) _session.reportError('文件未能打开：$error');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _onSessionChanged() {
    if (_observedMedia == _session.media?.uri) return;
    _observedMedia = _session.media?.uri;
    _showPlayer = _session.media != null;
    if (mounted) setState(() {});
  }

  void _onMetadataChanged() {
    if (mounted) setState(() {});
  }

  void _showMetadata(LocalMedia media) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: const Color(0xFF181A21),
      builder: (_) => AnimeMetadataSheet(media: media, metadata: _metadata),
    );
  }

  Future<void> _loadPreferences() async {
    try {
      final show = await _preferences.getBool('orvex.home.continue.v1') ?? true;
      if (mounted) setState(() => _showContinue = show);
    } catch (_) {
      if (mounted) setState(() => _libraryError = '首页偏好未能读取');
    }
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
      unawaited(_metadata.scan(_videos));
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loadingLibrary = false;
        _libraryError = '媒体库未能读取，请下拉重试';
      });
    }
  }

  Future<void> _open(LocalMedia media) async {
    final generation = ++_openGeneration;
    LocalMedia resolved;
    try {
      resolved = await _files.imports.resolve(media);
    } catch (error) {
      if (mounted && generation == _openGeneration) {
        _session.reportError('文件未能打开：$error');
      }
      return;
    }
    if (!mounted || generation != _openGeneration) return;
    setState(() => _showPlayer = true);
    if (_session.media?.resumeKey != resolved.resumeKey ||
        _session.engine == null) {
      await _session.open(resolved);
    } else {
      if (_session.frame.completed) await _session.seek(Duration.zero);
      if (!_session.frame.playing) await _session.togglePause();
    }
  }

  Future<void> _returnToLibrary() async {
    await _session.pauseForInterruption();
    if (!mounted) return;
    setState(() => _showPlayer = false);
    await _reload();
  }

  void _selectTab(int value) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _tab = value);
    unawaited(_reload());
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _session,
    builder: (context, _) {
      if (_fullscreen) return _fullscreenPlayer();
      final watching = _showPlayer && _session.media != null;
      return PopScope(
        canPop: !watching,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_returnToLibrary());
        },
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyO, meta: true): () =>
                _pick(),
            const SingleActivator(LogicalKeyboardKey.keyO, control: true): () =>
                _pick(),
            if (watching) ...{
              const SingleActivator(LogicalKeyboardKey.space): () =>
                  _session.togglePause(),
              const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                  _session.seek(
                    _session.frame.position - const Duration(seconds: 10),
                  ),
              const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                  _session.seek(
                    _session.frame.position + const Duration(seconds: 10),
                  ),
            },
          },
          child: Focus(
            autofocus: true,
            child: Scaffold(
              bottomNavigationBar: watching
                  ? null
                  : LibraryTabBar(selected: _tab, onSelected: _selectTab),
              body: SafeArea(
                bottom: watching,
                child: Column(
                  children: [
                    if (const bool.fromEnvironment(
                      'ORVEX_SILENT_SIMULATOR_TEST',
                    ))
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          '模拟器无声预览 · 声音待真机验收',
                          style: TextStyle(
                            color: Color(0xFFFFD294),
                            fontSize: 11,
                          ),
                        ),
                      ),
                    if (_picking) ...[
                      const LinearProgressIndicator(minHeight: 2),
                      const Padding(
                        padding: EdgeInsets.all(6),
                        child: Text('正在读取文件…', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                    if (widget.startupError ?? _libraryError ?? _session.error
                        case final String message)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                        child: _error(message),
                      ),
                    Expanded(
                      child: watching
                          ? _watchPage()
                          : LibraryViews(
                              tab: _tab,
                              videos: _videos,
                              history: _history,
                              loading: _loadingLibrary,
                              picking: _picking || widget.startupError != null,
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
                            ),
                    ),
                    if (!watching && _session.media != null) _returnToPlayer(),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _returnToPlayer() => Material(
    color: const Color(0xFF22232B),
    child: ListTile(
      dense: true,
      leading: const Icon(Icons.movie_outlined, color: libraryAccent),
      title: Text(
        mediaTitle(_session.media!.name),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '已暂停 · ${formatTime(_session.frame.position)}',
        style: const TextStyle(fontSize: 11, color: Color(0xFF93959F)),
      ),
      trailing: const Icon(Icons.open_in_full_rounded, size: 20),
      onTap: () => setState(() => _showPlayer = true),
    ),
  );

  Widget _watchPage() => SingleChildScrollView(
    padding: const EdgeInsets.all(20),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: '返回首页',
                  onPressed: () => _returnToLibrary(),
                  icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
                ),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    '正在播放',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: '打开本地视频',
                  onPressed: _picking ? null : () => _pick(),
                  icon: const Icon(Icons.add_rounded),
                ),
              ],
            ),
            const SizedBox(height: 24),
            _player(),
            const SizedBox(height: 14),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(
                Icons.auto_awesome_outlined,
                color: libraryAccent,
              ),
              title: Text(
                _metadata.subjectFor(_session.media!)?.title ?? '番剧资料',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: const Text(
                'Bangumi · 查看简介或更正匹配',
                style: TextStyle(color: Color(0xFF93959F), fontSize: 12),
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _showMetadata(_session.media!),
            ),
            const SizedBox(height: 20),
            const Text(
              '双击快进快退 · 横滑调整进度 · 长按临时 2 倍速',
              style: TextStyle(
                color: Color(0xFF93959F),
                fontSize: 12,
                height: 1.7,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '从字幕菜单添加外挂字幕；点击全屏，沉浸观看。',
              style: TextStyle(
                color: Color(0xFF93959F),
                fontSize: 12,
                height: 1.7,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _toggleFullscreen() async {
    if (!_session.ready) return;
    setState(() => _fullscreen = !_fullscreen);
    if (_fullscreen) {
      await defaultEnterNativeFullscreen();
    } else {
      await defaultExitNativeFullscreen();
    }
  }

  Widget _surface() => PlaybackSurface(
    key: ValueKey('${_session.media?.uri}:$_fullscreen'),
    session: _session,
    fullscreen: _fullscreen,
    onFullscreen: () => _toggleFullscreen(),
    onSubtitle: () => _pick(subtitle: true),
  );

  Widget _fullscreenPlayer() => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_toggleFullscreen());
    },
    child: Scaffold(
      backgroundColor: Colors.black,
      body: ListenableBuilder(
        listenable: _session,
        builder: (context, _) => Stack(
          children: [
            Positioned.fill(child: _surface()),
            if (_session.error case final String message)
              Positioned(top: 70, left: 20, right: 20, child: _error(message)),
          ],
        ),
      ),
    ),
  );

  Widget _player() => Container(
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: const Color(0xFF141720),
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: const Color(0xFF262B3A)),
    ),
    child: Column(
      children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: _session.engine == null
              ? const Center(child: CircularProgressIndicator())
              : _surface(),
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              const Icon(
                Icons.movie_outlined,
                size: 19,
                color: Color(0xFFA8B7FF),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _session.media?.name ?? '下一部，由你选择',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_session.media != null)
                IconButton(
                  tooltip: '关闭视频',
                  onPressed: () async {
                    await _session.close();
                    await _reload();
                  },
                  icon: const Icon(Icons.close_rounded, size: 20),
                ),
            ],
          ),
        ),
        if (_session.engine == null)
          const Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: Text(
              '00:00 / 00:00',
              style: TextStyle(fontSize: 12, color: Color(0xFF9298AB)),
            ),
          ),
      ],
    ),
  );

  Widget _error(String message) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: const Color(0xFF35232B),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(
          Icons.info_outline_rounded,
          color: Color(0xFFFFB8C5),
          size: 20,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: SelectableText(
            message,
            style: const TextStyle(color: Color(0xFFFFCCD5)),
          ),
        ),
      ],
    ),
  );
}
