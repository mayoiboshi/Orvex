import 'dart:io';

import 'package:flutter/material.dart';

import '../../player/domain/playback_engine.dart';
import '../../anime_metadata/application/anime_metadata_controller.dart';
import '../../anime_metadata/domain/anime_filename.dart';
import '../../anime_metadata/domain/anime_subject.dart';
import '../../player/presentation/playback_surface.dart';
import '../domain/playback_record.dart';

const libraryAccent = Color(0xFFF4B763);
const _muted = Color(0xFF93959F);
const _panel = Color(0xFF181A21);

class LibraryViews extends StatelessWidget {
  const LibraryViews({
    super.key,
    required this.tab,
    required this.videos,
    required this.history,
    required this.loading,
    required this.picking,
    required this.showContinue,
    required this.query,
    required this.onQuery,
    required this.onImport,
    required this.onOpen,
    required this.onTab,
    required this.onRefresh,
    required this.onShowContinue,
    required this.metadata,
    required this.onMetadata,
  });

  final int tab;
  final List<LocalMedia> videos;
  final List<PlaybackRecord> history;
  final bool loading;
  final bool picking;
  final bool showContinue;
  final String query;
  final ValueChanged<String> onQuery;
  final VoidCallback onImport;
  final ValueChanged<LocalMedia> onOpen;
  final ValueChanged<int> onTab;
  final Future<void> Function() onRefresh;
  final ValueChanged<bool> onShowContinue;
  final AnimeMetadataController metadata;
  final ValueChanged<LocalMedia> onMetadata;

  List<PlaybackRecord> get continuing =>
      history.where((record) => record.canContinue).toList();

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final padding = constraints.maxWidth < 600 ? 24.0 : 44.0;
      return RefreshIndicator(
        onRefresh: onRefresh,
        color: libraryAccent,
        child: SingleChildScrollView(
          key: PageStorageKey('library-tab-$tab'),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(padding, 20, padding, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1200),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _header(context),
                  const SizedBox(height: 28),
                  if (loading) ...[
                    const LinearProgressIndicator(minHeight: 2),
                    const SizedBox(height: 20),
                  ],
                  switch (tab) {
                    1 => _library(context),
                    2 => _history(context),
                    3 => _settings(context),
                    _ => _home(context),
                  },
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _header(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Row(
        children: [
          Icon(
            Icons.play_circle_filled_rounded,
            size: 17,
            color: libraryAccent,
          ),
          SizedBox(width: 7),
          Text(
            'ORVEX',
            style: TextStyle(
              color: _muted,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 3,
            ),
          ),
        ],
      ),
      const SizedBox(height: 16),
      Row(
        children: [
          Expanded(
            child: Text(
              const ['首页', '媒体库', '播放记录', '设置'][tab],
              style: const TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w700,
                letterSpacing: -1,
              ),
            ),
          ),
          if (tab == 0)
            IconButton(
              tooltip: '搜索媒体库',
              onPressed: () => onTab(1),
              icon: const Icon(Icons.search_rounded),
            ),
          if (tab != 3)
            IconButton.filledTonal(
              tooltip: '打开本地视频',
              onPressed: picking ? null : onImport,
              style: IconButton.styleFrom(
                backgroundColor: const Color(0xFF30281F),
                foregroundColor: libraryAccent,
              ),
              icon: const Icon(Icons.add_rounded),
            ),
        ],
      ),
      const SizedBox(height: 7),
      Text(switch (tab) {
        1 => '${videos.length} 部本地视频，随时开场',
        2 => '每一段故事，都有迹可循',
        3 => '让放映，更合你心意',
        _ => '你的故事，接着看。',
      }, style: const TextStyle(color: _muted, fontSize: 14)),
    ],
  );

  Widget _home(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _hero(context),
      if (showContinue) ...[
        const SizedBox(height: 30),
        _section('继续观看', action: '全部', onTap: () => onTab(2)),
        const SizedBox(height: 14),
        if (continuing.isEmpty)
          _quietCard(Icons.history_rounded, '好故事，不必一次看完', '播放进度会自动保留，下次从这里继续。')
        else
          SizedBox(
            height: 204,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: continuing.length,
              separatorBuilder: (_, _) => const SizedBox(width: 14),
              itemBuilder: (_, index) {
                final record = continuing[index];
                return SizedBox(width: 254, child: _continueCard(record));
              },
            ),
          ),
      ],
      const SizedBox(height: 30),
      _section('我的媒体库', action: '查看全部', onTap: () => onTab(1)),
      const SizedBox(height: 14),
      Material(
        color: _panel,
        borderRadius: BorderRadius.circular(18),
        child: ListTile(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 8,
          ),
          leading: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFF332A20),
              borderRadius: BorderRadius.circular(13),
            ),
            child: const Icon(Icons.folder_rounded, color: libraryAccent),
          ),
          title: const Text(
            '本地视频',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            '${videos.length} 部视频',
            style: const TextStyle(color: _muted),
          ),
          trailing: const Icon(Icons.chevron_right_rounded, color: _muted),
          onTap: () => onTab(1),
        ),
      ),
      if (videos.isNotEmpty) ...[
        const SizedBox(height: 30),
        _section('最近添加', action: '全部', onTap: () => onTab(1)),
        const SizedBox(height: 14),
        _posterGrid(videos.take(8).toList()),
      ],
    ],
  );

  Widget _hero(BuildContext context) {
    final record = showContinue && continuing.isNotEmpty
        ? continuing.first
        : null;
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: Container(
        constraints: const BoxConstraints(minHeight: 274),
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
            colors: [Color(0xFF39302C), Color(0xFF24232A), Color(0xFF151820)],
          ),
        ),
        child: Stack(
          children: [
            const Positioned.fill(child: _CinemaArtwork()),
            Padding(
              padding: const EdgeInsets.all(26),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 540),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      record == null ? '属于你的私人影院' : '接着上次的故事',
                      style: const TextStyle(
                        color: libraryAccent,
                        fontSize: 12,
                        letterSpacing: 1,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 22),
                    Text(
                      record == null
                          ? '好故事，\n从这里开始。'
                          : _mediaTitle(record.media),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 30,
                        height: 1.35,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.7,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      record == null
                          ? '导入喜欢的视频，留一段时间给自己。'
                          : '已观看 ${formatTime(record.position)} · 共 ${formatTime(record.duration)}',
                      style: const TextStyle(
                        color: Color(0xFFBAB7B5),
                        fontSize: 12,
                        height: 1.6,
                      ),
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: picking
                          ? null
                          : () => record == null
                                ? onImport()
                                : onOpen(record.media),
                      style: FilledButton.styleFrom(
                        backgroundColor: libraryAccent,
                        foregroundColor: const Color(0xFF211A12),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 14,
                        ),
                        minimumSize: const Size(0, 46),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: Icon(
                        record == null
                            ? Icons.add_rounded
                            : Icons.play_arrow_rounded,
                        size: 21,
                      ),
                      label: Text(
                        record == null ? '导入视频' : '继续播放',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _continueCard(PlaybackRecord record) => InkWell(
    borderRadius: BorderRadius.circular(14),
    onTap: () => onOpen(record.media),
    onLongPress: () => onMetadata(record.media),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Stack(
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: MediaCover(
                  media: record.media,
                  posterPath: metadata.posterPath(
                    metadata.subjectFor(record.media)?.id ?? 0,
                  ),
                ),
              ),
              const Positioned.fill(
                child: Center(
                  child: Icon(
                    Icons.play_circle_fill_rounded,
                    size: 38,
                    color: Colors.white70,
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LinearProgressIndicator(
                  value: record.progress,
                  color: libraryAccent,
                  backgroundColor: Colors.white12,
                  minHeight: 3,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Text(
          _mediaTitle(record.media),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          '${formatTime(record.position)} / ${formatTime(record.duration)}',
          style: const TextStyle(color: _muted, fontSize: 12),
        ),
      ],
    ),
  );

  Widget _library(BuildContext context) {
    final filtered = videos
        .where(
          (media) =>
              '${media.name} ${metadata.subjectFor(media)?.allNames.join(' ') ?? ''}'
                  .toLowerCase()
                  .contains(query.toLowerCase()),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextFormField(
          initialValue: query,
          onChanged: onQuery,
          decoration: InputDecoration(
            hintText: '搜索视频名称',
            hintStyle: const TextStyle(color: _muted),
            prefixIcon: const Icon(Icons.search_rounded, color: _muted),
            filled: true,
            fillColor: _panel,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
        const SizedBox(height: 12),
        _metadataStatus(),
        const SizedBox(height: 18),
        _section('全部视频', detail: '${filtered.length} 部'),
        const SizedBox(height: 16),
        if (videos.isEmpty)
          _emptyState(
            Icons.video_library_outlined,
            '收藏，从第一部开始',
            '把“文件”里的视频导入 Orvex，\n在这里整理你的私人片库。',
            import: true,
          )
        else if (filtered.isEmpty)
          _emptyState(Icons.search_rounded, '没有找到视频', '试试其他名称，或导入新的视频。')
        else
          _posterGrid(filtered),
      ],
    );
  }

  Widget _posterGrid(List<LocalMedia> items) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = (constraints.maxWidth / 155).floor().clamp(2, 6);
      final width = (constraints.maxWidth - (columns - 1) * 16) / columns;
      return Wrap(
        spacing: 16,
        runSpacing: 24,
        children: [
          for (final media in items)
            SizedBox(
              width: width,
              child: InkWell(
                borderRadius: BorderRadius.circular(13),
                onTap: () => onOpen(media),
                onLongPress: () => onMetadata(media),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(13),
                      child: AspectRatio(
                        aspectRatio: 2 / 3,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            MediaCover(
                              media: media,
                              poster: true,
                              posterPath: metadata.posterPath(
                                metadata.subjectFor(media)?.id ?? 0,
                              ),
                            ),
                            Positioned(
                              top: 0,
                              right: 0,
                              child: IconButton(
                                tooltip: '番剧资料',
                                onPressed: () => onMetadata(media),
                                icon: const Icon(
                                  Icons.info_outline_rounded,
                                  size: 20,
                                ),
                                style: IconButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  backgroundColor: Colors.black38,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _mediaTitle(media),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _mediaCaption(media),
                      style: const TextStyle(color: _muted, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );

  Widget _history(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (history.isEmpty)
        _emptyState(
          Icons.history_rounded,
          '下一段故事，等你开始',
          '播放过的视频会留在这里，\n想重温时，随时回来。',
          import: true,
        )
      else ...[
        _section('最近播放', detail: '${history.length} 部'),
        const SizedBox(height: 16),
        for (final record in history) ...[
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => onOpen(record.media),
            onLongPress: () => onMetadata(record.media),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  SizedBox(
                    width: 104,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: AspectRatio(
                        aspectRatio: 16 / 9,
                        child: MediaCover(
                          media: record.media,
                          posterPath: metadata.posterPath(
                            metadata.subjectFor(record.media)?.id ?? 0,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _mediaTitle(record.media),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          record.completed
                              ? '已看完'
                              : '看到 ${formatTime(record.position)}',
                          style: const TextStyle(color: _muted, fontSize: 12),
                        ),
                        const SizedBox(height: 7),
                        LinearProgressIndicator(
                          value: record.progress,
                          minHeight: 2,
                          color: libraryAccent,
                          backgroundColor: Colors.white10,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.play_arrow_rounded, color: libraryAccent),
                ],
              ),
            ),
          ),
          const Divider(color: Color(0xFF25272E), height: 14),
        ],
      ],
    ],
  );

  String _mediaTitle(LocalMedia media) {
    final subject = metadata.subjectFor(media);
    if (subject == null) return mediaTitle(media.name);
    final episode = AnimeFilename.parse(media.name).episodeLabel;
    return episode.isEmpty ? subject.title : '${subject.title} · $episode';
  }

  String _mediaCaption(LocalMedia media) {
    final match = metadata.matchFor(media);
    final subject = match?.subject;
    if (subject != null) {
      return [
        if (subject.date.length >= 4) subject.date.substring(0, 4),
        if (subject.score > 0) '★ ${subject.score.toStringAsFixed(1)}',
        'Bangumi',
      ].join(' · ');
    }
    return switch (match?.status) {
      AnimeMatchStatus.queued => '正在匹配番剧…',
      AnimeMatchStatus.needsReview => '匹配待确认',
      AnimeMatchStatus.failed => '匹配失败 · 可重试',
      _ => '${media.name.split('.').last.toUpperCase()} · 本地视频',
    };
  }

  Widget _metadataStatus() => Row(
    children: [
      if (metadata.busy) ...[
        const SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(strokeWidth: 1.5),
        ),
        const SizedBox(width: 8),
      ] else ...[
        const Icon(Icons.auto_awesome_outlined, size: 14, color: libraryAccent),
        const SizedBox(width: 8),
      ],
      Expanded(
        child: Text(
          metadata.error ??
              (metadata.busy
                  ? 'Bangumi 正在匹配番剧资料'
                  : metadata.automatic
                  ? 'Bangumi 自动匹配 · 点击封面上的 ⓘ 查看资料'
                  : 'Bangumi 自动匹配已关闭'),
          style: const TextStyle(color: _muted, fontSize: 11, height: 1.6),
        ),
      ),
      if (metadata.error != null ||
          videos.any(
            (media) =>
                metadata.matchFor(media)?.status == AnimeMatchStatus.failed,
          ))
        TextButton(
          onPressed: metadata.busy ? null : () => metadata.retry(),
          child: const Text('重试', style: TextStyle(fontSize: 12)),
        ),
    ],
  );

  Widget _settings(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _section('首页'),
      const SizedBox(height: 12),
      _group([
        SwitchListTile.adaptive(
          title: const Text('显示继续观看', style: TextStyle(fontSize: 15)),
          subtitle: const Text(
            '在首页接着上次的进度',
            style: TextStyle(color: _muted, fontSize: 12),
          ),
          activeTrackColor: libraryAccent,
          value: showContinue,
          onChanged: onShowContinue,
        ),
      ]),
      const SizedBox(height: 26),
      _section('番剧资料'),
      const SizedBox(height: 12),
      _group([
        SwitchListTile.adaptive(
          key: const ValueKey('automatic-bangumi'),
          title: const Text('自动匹配番剧', style: TextStyle(fontSize: 15)),
          subtitle: const Text(
            '向 Bangumi 查询整理后的片名，不上传媒体文件',
            style: TextStyle(color: _muted, fontSize: 12),
          ),
          activeTrackColor: libraryAccent,
          value: metadata.automatic,
          onChanged: metadata.setAutomatic,
        ),
        const Divider(height: 1, indent: 16, color: Color(0xFF292B32)),
        const ListTile(
          title: Text('数据来源：Bangumi', style: TextStyle(fontSize: 14)),
          subtitle: Text(
            '资料缓存在本机；点击视频封面上的 ⓘ 可纠正匹配',
            style: TextStyle(color: _muted, fontSize: 12),
          ),
        ),
      ]),
      const SizedBox(height: 26),
      _section('文件与播放'),
      const SizedBox(height: 12),
      _group([
        ListTile(
          leading: const Icon(
            Icons.create_new_folder_outlined,
            color: libraryAccent,
          ),
          title: const Text('导入本地视频', style: TextStyle(fontSize: 15)),
          trailing: const Icon(Icons.chevron_right_rounded, color: _muted),
          onTap: picking ? null : onImport,
        ),
        const Divider(height: 1, indent: 56, color: Color(0xFF292B32)),
        const ListTile(
          leading: Icon(Icons.subtitles_outlined, color: _muted),
          title: Text('外挂字幕', style: TextStyle(fontSize: 15)),
          subtitle: Text(
            '在播放界面添加 SRT、ASS、SSA 或 VTT',
            style: TextStyle(color: _muted, fontSize: 12),
          ),
        ),
        const Divider(height: 1, indent: 56, color: Color(0xFF292B32)),
        const ListTile(
          leading: Icon(Icons.bookmark_border_rounded, color: _muted),
          title: Text('自动保存播放进度', style: TextStyle(fontSize: 15)),
          subtitle: Text(
            '重新打开同一视频时，从上次继续',
            style: TextStyle(color: _muted, fontSize: 12),
          ),
        ),
      ]),
      const SizedBox(height: 26),
      _section('关于'),
      const SizedBox(height: 12),
      _group([
        const ListTile(
          leading: Icon(
            Icons.play_circle_outline_rounded,
            color: libraryAccent,
          ),
          title: Text('Orvex', style: TextStyle(fontSize: 15)),
          trailing: Text('0.1.0', style: TextStyle(color: _muted)),
        ),
        const Divider(height: 1, indent: 56, color: Color(0xFF292B32)),
        ListTile(
          leading: const Icon(Icons.description_outlined, color: _muted),
          title: const Text('开源许可', style: TextStyle(fontSize: 15)),
          trailing: const Icon(Icons.chevron_right_rounded, color: _muted),
          onTap: () => showLicensePage(
            context: context,
            applicationName: 'Orvex',
            applicationVersion: '0.1.0',
          ),
        ),
      ]),
      const SizedBox(height: 32),
      const Center(
        child: Text(
          '留一点时间，给喜欢的故事。',
          style: TextStyle(color: _muted, fontSize: 12),
        ),
      ),
    ],
  );

  Widget _group(List<Widget> children) => Material(
    color: _panel,
    borderRadius: BorderRadius.circular(16),
    clipBehavior: Clip.antiAlias,
    child: Column(children: children),
  );

  Widget _section(
    String title, {
    String? action,
    String? detail,
    VoidCallback? onTap,
  }) => Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
          ),
        ),
      ),
      if (detail != null)
        Text(detail, style: const TextStyle(color: _muted, fontSize: 12)),
      if (action != null)
        TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
            foregroundColor: libraryAccent,
            minimumSize: const Size(44, 40),
            padding: EdgeInsets.zero,
          ),
          child: Text(action, style: const TextStyle(fontSize: 12)),
        ),
    ],
  );

  Widget _quietCard(IconData icon, String title, String subtitle) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: _panel,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      children: [
        Icon(icon, color: _muted, size: 26),
        const SizedBox(width: 15),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                style: const TextStyle(
                  color: _muted,
                  fontSize: 12,
                  height: 1.6,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _emptyState(
    IconData icon,
    String title,
    String subtitle, {
    bool import = false,
  }) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 44),
    decoration: BoxDecoration(
      color: _panel,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Column(
      children: [
        Icon(icon, size: 42, color: libraryAccent),
        const SizedBox(height: 20),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: const TextStyle(color: _muted, height: 1.7, fontSize: 13),
        ),
        if (import) ...[
          const SizedBox(height: 26),
          FilledButton.icon(
            onPressed: picking ? null : onImport,
            icon: const Icon(Icons.add_rounded),
            label: const Text('导入视频'),
          ),
        ],
      ],
    ),
  );
}

String mediaTitle(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

/// Use a locally cached Bangumi cover, or original artwork when unmatched.
class MediaCover extends StatelessWidget {
  const MediaCover({
    super.key,
    required this.media,
    this.poster = false,
    this.posterPath,
  });
  final LocalMedia media;
  final bool poster;
  final String? posterPath;

  @override
  Widget build(BuildContext context) {
    const palettes = [
      [Color(0xFF465468), Color(0xFF1A2537)],
      [Color(0xFF7C6250), Color(0xFF302A32)],
      [Color(0xFF4B6867), Color(0xFF1C2F35)],
      [Color(0xFF655D7D), Color(0xFF272739)],
    ];
    final hash = media.name.codeUnits.fold(0, (sum, unit) => sum + unit);
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: palettes[hash % palettes.length],
        ),
      ),
      child: Stack(
        children: [
          const Positioned.fill(child: _CinemaArtwork(subtle: true)),
          if (poster)
            Center(
              child: Icon(
                Icons.movie_outlined,
                size: 34,
                color: Colors.white.withValues(alpha: 0.3),
              ),
            ),
          Positioned(
            top: 10,
            left: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                media.name.split('.').last.toUpperCase(),
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
    if (posterPath == null) return fallback;
    return Image.file(
      File(posterPath!),
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => fallback,
      frameBuilder: (context, child, frame, synchronous) =>
          frame == null ? fallback : child,
    );
  }
}

class _CinemaArtwork extends StatelessWidget {
  const _CinemaArtwork({this.subtle = false});
  final bool subtle;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _CinemaPainter(subtle));
}

class _CinemaPainter extends CustomPainter {
  const _CinemaPainter(this.subtle);
  final bool subtle;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width * 0.96, size.height * 0.29);
    final radius = size.height * 0.8;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFFF4B763).withValues(alpha: subtle ? 0.1 : 0.18),
            Colors.transparent,
          ],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
    for (var i = 0; i < 5; i++) {
      final rect = Rect.fromCenter(
        center: center,
        width: radius * (0.65 + i * 0.34),
        height: radius * (1.2 + i * 0.34),
      );
      canvas.drawOval(
        rect,
        Paint()
          ..color = Colors.white.withValues(alpha: subtle ? 0.04 : 0.07)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
    canvas.drawLine(
      Offset(size.width * 0.4, size.height),
      Offset(size.width, size.height * 0.05),
      Paint()
        ..color = libraryAccent.withValues(alpha: 0.08)
        ..strokeWidth = 28,
    );
  }

  @override
  bool shouldRepaint(_CinemaPainter oldDelegate) =>
      oldDelegate.subtle != subtle;
}

class LibraryTabBar extends StatelessWidget {
  const LibraryTabBar({
    super.key,
    required this.selected,
    required this.onSelected,
  });
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      color: Color(0xFF111319),
      border: Border(top: BorderSide(color: Color(0xFF23252C), width: 0.5)),
    ),
    child: SafeArea(
      top: false,
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 650),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                for (var index = 0; index < 4; index++)
                  Expanded(
                    child: Semantics(
                      selected: selected == index,
                      button: true,
                      label: const ['首页', '媒体库', '播放记录', '设置'][index],
                      excludeSemantics: true,
                      child: InkResponse(
                        key: ValueKey('tab-$index'),
                        onTap: () => onSelected(index),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                selected == index
                                    ? const [
                                        Icons.home_rounded,
                                        Icons.video_library_rounded,
                                        Icons.history_rounded,
                                        Icons.settings_rounded,
                                      ][index]
                                    : const [
                                        Icons.home_outlined,
                                        Icons.video_library_outlined,
                                        Icons.history_rounded,
                                        Icons.settings_outlined,
                                      ][index],
                                size: 25,
                                color: selected == index
                                    ? libraryAccent
                                    : _muted,
                              ),
                              const SizedBox(height: 5),
                              Text(
                                const ['首页', '媒体库', '播放记录', '设置'][index],
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: selected == index
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                  color: selected == index
                                      ? libraryAccent
                                      : _muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
