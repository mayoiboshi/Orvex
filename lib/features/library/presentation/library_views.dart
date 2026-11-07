import 'dart:io';

import 'package:flutter/material.dart';

import '../../../design/appearance_controller.dart';
import '../../../design/glass.dart';
import '../../../design/orvex_theme.dart';
import '../../player/domain/playback_engine.dart';
import '../../anime_metadata/application/anime_metadata_controller.dart';
import '../../anime_metadata/domain/anime_filename.dart';
import '../../anime_metadata/domain/anime_subject.dart';
import '../../player/presentation/playback_surface.dart';
import '../domain/playback_record.dart';

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
    required this.appearance,
  });

  final int tab;
  final List<LocalMedia> videos;
  final List<PlaybackRecord> history;
  final bool loading, picking, showContinue;
  final String query;
  final ValueChanged<String> onQuery;
  final VoidCallback onImport;
  final ValueChanged<LocalMedia> onOpen;
  final ValueChanged<int> onTab;
  final Future<void> Function() onRefresh;
  final ValueChanged<bool> onShowContinue;
  final AnimeMetadataController metadata;
  final ValueChanged<LocalMedia> onMetadata;
  final AppearanceController appearance;

  List<PlaybackRecord> get continuing =>
      history.where((record) => record.canContinue).toList();

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final inset = constraints.maxWidth < 600 ? OrvexMetrics.page : 36.0;
      return RefreshIndicator(
        onRefresh: onRefresh,
        child: SingleChildScrollView(
          key: PageStorageKey('library-tab-$tab'),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(inset, 20, inset, 120),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: tab == 3 ? 760 : 1160),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _header(context),
                  SizedBox(
                    height: tab == 0 ? OrvexMetrics.page : OrvexMetrics.section,
                  ),
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

  Widget _header(BuildContext context) => tab == 0
      ? _homeHeader(context)
      : Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const OrvexBrand(),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: Text(
                    const ['首页', '媒体库', '播放记录', '设置'][tab],
                    style: Theme.of(context).textTheme.headlineLarge,
                  ),
                ),
                if (tab == 0) ...[
                  GlassIconButton(
                    icon: Icons.search_rounded,
                    tooltip: '搜索媒体库',
                    onPressed: () => onTab(1),
                  ),
                  const SizedBox(width: 8),
                ],
                if (tab != 3)
                  GlassIconButton(
                    icon: Icons.add_rounded,
                    tooltip: '打开本地视频',
                    prominent: true,
                    onPressed: picking ? null : onImport,
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(switch (tab) {
              1 => '${videos.length} 部本地视频',
              2 => '从上次停下的地方，继续。',
              3 => '按你的方式，享受每一次播放。',
              _ => '喜欢的内容，触手可及。',
            }, style: Theme.of(context).textTheme.bodySmall),
          ],
        );

  Widget _homeHeader(BuildContext context) {
    final colors = OrvexColors.of(context);
    final text = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const OrvexBrand(),
              const SizedBox(height: OrvexMetrics.gap),
              Text(
                '首页',
                style: text.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                loading
                    ? '正在读取媒体…'
                    : videos.isEmpty
                    ? '添加视频，建立你的媒体库。'
                    : '${videos.length} 部视频${showContinue && continuing.isNotEmpty ? ' · ${continuing.length} 部可继续观看' : ' · 随时开始观看'}',
                style: text.bodySmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        const SizedBox(width: OrvexMetrics.space),
        GlassSurface(
          radius: OrvexMetrics.controlRadius,
          padding: const EdgeInsets.all(4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: '搜索媒体库',
                onPressed: () => onTab(1),
                icon: Icon(
                  Icons.search_rounded,
                  size: OrvexMetrics.iconSize,
                  color: colors.secondary,
                ),
              ),
              IconButton(
                tooltip: '打开本地视频',
                onPressed: picking ? null : onImport,
                style: IconButton.styleFrom(
                  backgroundColor: colors.accent.withValues(alpha: 0.07),
                  foregroundColor: colors.accent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(
                      OrvexMetrics.smallRadius,
                    ),
                  ),
                ),
                icon: const Icon(
                  Icons.add_rounded,
                  size: OrvexMetrics.iconSize,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _home(BuildContext context) {
    final resume = showContinue && continuing.isNotEmpty
        ? continuing.first
        : null;
    final others = showContinue
        ? continuing.skip(1).toList()
        : <PlaybackRecord>[];
    final recent = videos
        .where((video) => video.resumeKey != resume?.media.resumeKey)
        .take(8)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showContinue) ...[
          _section(context, '继续观看', action: '播放记录', onTap: () => onTab(2)),
          const SizedBox(height: 12),
        ],
        _hero(context, resume),
        if (others.isNotEmpty) ...[
          const SizedBox(height: OrvexMetrics.space),
          SizedBox(
            height:
                220 +
                (MediaQuery.textScalerOf(context).scale(14) / 14 - 1).clamp(
                      0,
                      3,
                    ) *
                    80,
            child: ListView.separated(
              key: const ValueKey('home-continue-rail'),
              scrollDirection: Axis.horizontal,
              itemCount: others.length,
              separatorBuilder: (_, _) =>
                  const SizedBox(width: OrvexMetrics.space),
              itemBuilder: (context, index) => SizedBox(
                width: 248,
                child: _continueCard(context, others[index]),
              ),
            ),
          ),
        ],
        const SizedBox(height: 24),
        _section(context, '我的媒体库', action: '查看全部', onTap: () => onTab(1)),
        const SizedBox(height: 12),
        _homeLibrary(context),
        if (recent.isNotEmpty) ...[
          const SizedBox(height: 24),
          _section(context, '最近添加', action: '全部', onTap: () => onTab(1)),
          const SizedBox(height: 14),
          _posterGrid(context, recent, home: true),
        ],
      ],
    );
  }

  Widget _homeLibrary(BuildContext context) {
    final colors = OrvexColors.of(context);
    final text = Theme.of(context).textTheme;
    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(OrvexMetrics.cardRadius),
        side: BorderSide(
          color: colors.divider.withValues(alpha: 0.7),
          width: 0.7,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const ValueKey('home-library'),
        onTap: () => onTab(1),
        child: Padding(
          padding: const EdgeInsets.all(OrvexMetrics.space),
          child: Row(
            children: [
              if (videos.isEmpty)
                _tileIcon(context, Icons.video_library_outlined)
              else
                SizedBox(
                  width: 76,
                  height: 56,
                  child: Stack(
                    children: [
                      for (var i = videos.take(3).length - 1; i >= 0; i--)
                        Positioned(
                          left: i * 14.0,
                          top: i * 2.0,
                          bottom: i * 2.0,
                          width: 38,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: colors.surface,
                              borderRadius: BorderRadius.circular(
                                OrvexMetrics.smallRadius,
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(2),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(
                                  OrvexMetrics.small,
                                ),
                                child: _cover(videos[i], poster: true),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              const SizedBox(width: OrvexMetrics.space),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('本地视频', style: text.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      '${videos.length} 部视频 · 保存在此设备',
                      style: text.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: OrvexMetrics.gap),
              Icon(
                Icons.arrow_forward_rounded,
                size: OrvexMetrics.iconSize,
                color: colors.accent,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _homeProgress(BuildContext context, double progress) => ClipRRect(
    borderRadius: BorderRadius.circular(OrvexMetrics.pillRadius),
    child: LinearProgressIndicator(
      value: progress,
      minHeight: 2,
      backgroundColor: OrvexColors.of(context).divider.withValues(alpha: 0.6),
      color: OrvexColors.of(context).accent.withValues(alpha: 0.9),
    ),
  );

  Widget _hero(BuildContext context, PlaybackRecord? record) {
    final colors = OrvexColors.of(context);
    final text = Theme.of(context).textTheme;
    if (record == null) {
      return GlassSurface(
        radius: OrvexMetrics.cardRadius,
        padding: const EdgeInsets.all(OrvexMetrics.section),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _tileIcon(context, Icons.video_library_outlined),
            const SizedBox(height: OrvexMetrics.space),
            Text('从这里开始观看', style: text.titleLarge),
            const SizedBox(height: OrvexMetrics.small),
            Text(
              '添加本地视频，字幕与观看进度会留在这里。',
              style: text.bodyMedium?.copyWith(color: colors.secondary),
            ),
            const SizedBox(height: OrvexMetrics.space),
            FilledButton.icon(
              onPressed: picking ? null : onImport,
              icon: const Icon(Icons.add_rounded, size: 20),
              label: const Text('导入视频'),
            ),
          ],
        ),
      );
    }
    final subject = metadata.subjectFor(record.media);
    final episode = AnimeFilename.parse(record.media.name).episodeLabel;
    return GlassSurface(
      radius: OrvexMetrics.cardRadius,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 640;
          final footerRow =
              wide && MediaQuery.textScalerOf(context).scale(12) <= 18;
          final progress = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${formatTime(record.position)} / ${formatTime(record.duration)}',
                style: text.bodySmall,
              ),
              const SizedBox(height: 3),
              Text(
                '已观看 ${(record.progress * 100).round()}%',
                style: text.labelSmall,
              ),
            ],
          );
          final play = FilledButton.icon(
            key: const ValueKey('home-resume'),
            onPressed: () => onOpen(record.media),
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, OrvexMetrics.hitSize),
              padding: const EdgeInsets.symmetric(
                horizontal: OrvexMetrics.space,
              ),
              shape: const StadiumBorder(),
            ),
            icon: const Icon(
              Icons.play_arrow_rounded,
              size: OrvexMetrics.iconSize,
            ),
            label: const Text('继续播放'),
          );
          return ConstrainedBox(
            constraints: BoxConstraints(minHeight: wide ? 196 : 190),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: wide ? 132 : 88,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: _cover(record.media, poster: true),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.all(
                        wide ? OrvexMetrics.page : OrvexMetrics.space,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            episode.isEmpty ? '本地媒体' : episode,
                            style: text.labelMedium?.copyWith(
                              color: colors.accent,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            subject?.title ?? _mediaTitle(record.media),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: text.titleLarge?.copyWith(
                              fontSize: wide ? 22 : 18,
                              height: 1.25,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _mediaCaption(record.media),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.labelSmall,
                          ),
                          const SizedBox(height: OrvexMetrics.space),
                          _homeProgress(context, record.progress),
                          const SizedBox(height: OrvexMetrics.gap),
                          if (footerRow)
                            Row(
                              children: [
                                Expanded(child: progress),
                                const SizedBox(width: OrvexMetrics.space),
                                play,
                              ],
                            )
                          else ...[
                            progress,
                            const SizedBox(height: OrvexMetrics.gap),
                            play,
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _continueCard(BuildContext context, PlaybackRecord record) => InkWell(
    key: ValueKey('home-continue-${record.media.resumeKey}'),
    borderRadius: BorderRadius.circular(OrvexMetrics.coverRadius),
    onTap: () => onOpen(record.media),
    onLongPress: () => onMetadata(record.media),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(OrvexMetrics.coverRadius),
          child: AspectRatio(aspectRatio: 16 / 9, child: _cover(record.media)),
        ),
        const SizedBox(height: OrvexMetrics.small),
        SizedBox(
          height: MediaQuery.textScalerOf(context).scale(14) * 1.3 * 2,
          child: Text(
            _mediaTitle(record.media),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(height: 1.3),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '${formatTime(record.position)} / ${formatTime(record.duration)}',
          style: Theme.of(context).textTheme.labelSmall,
        ),
        const SizedBox(height: OrvexMetrics.small),
        _homeProgress(context, record.progress),
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
          decoration: const InputDecoration(
            hintText: '搜索视频名称',
            prefixIcon: Icon(Icons.search_rounded),
          ),
        ),
        const SizedBox(height: 12),
        _metadataStatus(context),
        const SizedBox(height: 20),
        _section(context, '全部视频', detail: '${filtered.length} 部'),
        const SizedBox(height: 16),
        if (videos.isEmpty)
          _emptyState(
            context,
            Icons.video_library_outlined,
            '媒体库，等你开场',
            '导入本地视频，建立自己的片库。',
            import: true,
          )
        else if (filtered.isEmpty)
          _emptyState(
            context,
            Icons.search_rounded,
            '没有找到视频',
            '试试其他名称，或导入新的视频。',
          )
        else
          _posterGrid(context, filtered),
      ],
    );
  }

  Widget _posterGrid(
    BuildContext context,
    List<LocalMedia> items, {
    bool home = false,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = (constraints.maxWidth / 174).floor().clamp(2, 6);
      final width = (constraints.maxWidth - (columns - 1) * 16) / columns;
      return Wrap(
        spacing: 16,
        runSpacing: 22,
        children: [
          for (final media in items)
            SizedBox(
              width: width,
              child: InkWell(
                key: home ? ValueKey('home-recent-${media.resumeKey}') : null,
                borderRadius: BorderRadius.circular(OrvexMetrics.coverRadius),
                onTap: () => onOpen(media),
                onLongPress: () => onMetadata(media),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(
                        OrvexMetrics.coverRadius,
                      ),
                      child: AspectRatio(
                        aspectRatio: 2 / 3,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            _cover(media, poster: true),
                            Positioned(
                              top: 6,
                              right: 6,
                              child: home
                                  ? IconButton(
                                      tooltip: '番剧资料',
                                      onPressed: () => onMetadata(media),
                                      icon: DecoratedBox(
                                        decoration: BoxDecoration(
                                          color: OrvexColors.player.overlay,
                                          borderRadius: BorderRadius.circular(
                                            OrvexMetrics.pillRadius,
                                          ),
                                        ),
                                        child: Padding(
                                          padding: const EdgeInsets.all(6),
                                          child: Icon(
                                            Icons.info_outline_rounded,
                                            size: 18,
                                            color: OrvexColors.player.text,
                                          ),
                                        ),
                                      ),
                                    )
                                  : GlassIconButton(
                                      immersive: true,
                                      icon: Icons.info_outline_rounded,
                                      tooltip: '番剧资料',
                                      onPressed: () => onMetadata(media),
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (home)
                      SizedBox(
                        height:
                            MediaQuery.textScalerOf(context).scale(14) *
                            1.3 *
                            2,
                        child: Text(
                          _mediaTitle(media),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(height: 1.3),
                        ),
                      )
                    else
                      Text(
                        _mediaTitle(media),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    const SizedBox(height: 4),
                    Text(
                      _mediaCaption(media),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
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
          context,
          Icons.history_rounded,
          '下一段故事，等你开始',
          '播放记录会自动保存在此设备。',
          import: true,
        )
      else ...[
        _section(context, '最近播放', detail: '${history.length} 部'),
        const SizedBox(height: 14),
        for (final record in history) ...[
          _recordTile(context, record),
          const SizedBox(height: 10),
        ],
      ],
    ],
  );

  Widget _recordTile(
    BuildContext context,
    PlaybackRecord record,
  ) => GlassSurface(
    child: InkWell(
      onTap: () => onOpen(record.media),
      onLongPress: () => onMetadata(record.media),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            SizedBox(
              width: 96,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(OrvexMetrics.smallRadius),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: _cover(record.media),
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
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    record.completed
                        ? '已看完'
                        : '看到 ${formatTime(record.position)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: record.progress, minHeight: 2),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Icon(
              Icons.play_arrow_rounded,
              color: OrvexColors.of(context).accent,
            ),
          ],
        ),
      ),
    ),
  );

  Widget _cover(LocalMedia media, {bool poster = false}) => MediaCover(
    media: media,
    poster: poster,
    posterPath: metadata.posterPath(metadata.subjectFor(media)?.id ?? 0),
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

  Widget _metadataStatus(BuildContext context) => Row(
    children: [
      if (metadata.busy)
        const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 1.5),
        )
      else
        Icon(
          Icons.auto_awesome_outlined,
          size: 15,
          color: OrvexColors.of(context).accent,
        ),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          metadata.error ??
              (metadata.busy
                  ? 'Bangumi 正在匹配番剧资料'
                  : metadata.automatic
                  ? 'Bangumi 自动匹配 · ⓘ 查看或更正资料'
                  : 'Bangumi 自动匹配已关闭'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
      if (metadata.error != null ||
          videos.any(
            (media) =>
                metadata.matchFor(media)?.status == AnimeMatchStatus.failed,
          ))
        TextButton(
          onPressed: metadata.busy ? null : () => metadata.retry(),
          child: const Text('重试'),
        ),
    ],
  );

  Widget _settings(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _section(context, '外观'),
      const SizedBox(height: 12),
      _group([
        RadioGroup<ThemeMode>(
          groupValue: appearance.mode,
          onChanged: (value) {
            if (value != null) appearance.setMode(value);
          },
          child: Column(
            children: [
              for (final mode in ThemeMode.values)
                RadioListTile<ThemeMode>(
                  key: ValueKey('theme-${mode.name}'),
                  value: mode,
                  title: Text(switch (mode) {
                    ThemeMode.system => '跟随系统',
                    ThemeMode.light => '浅色',
                    ThemeMode.dark => '深色',
                  }),
                  secondary: Icon(switch (mode) {
                    ThemeMode.system => Icons.brightness_auto_outlined,
                    ThemeMode.light => Icons.light_mode_outlined,
                    ThemeMode.dark => Icons.dark_mode_outlined,
                  }),
                ),
            ],
          ),
        ),
        const Divider(indent: 18, endIndent: 18),
        SwitchListTile.adaptive(
          key: const ValueKey('reduce-transparency'),
          value: appearance.reduceTransparency,
          onChanged: appearance.setReduceTransparency,
          title: const Text('减少透明效果'),
          subtitle: Text(
            appearance.systemReduceTransparency ? '系统已启用减少透明度' : '使用更清晰的不透明表面',
          ),
        ),
        if (appearance.error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              appearance.error!,
              style: TextStyle(color: OrvexColors.of(context).error),
            ),
          ),
      ]),
      const SizedBox(height: 24),
      _section(context, '首页'),
      const SizedBox(height: 12),
      _group([
        SwitchListTile.adaptive(
          title: const Text('显示继续观看'),
          subtitle: const Text('在首页接着上次的进度'),
          value: showContinue,
          onChanged: onShowContinue,
        ),
      ]),
      const SizedBox(height: 24),
      _section(context, '番剧资料'),
      const SizedBox(height: 12),
      _group([
        SwitchListTile.adaptive(
          key: const ValueKey('automatic-bangumi'),
          title: const Text('自动匹配番剧'),
          subtitle: const Text('向 Bangumi 查询整理后的片名，不上传媒体文件'),
          value: metadata.automatic,
          onChanged: metadata.setAutomatic,
        ),
        const Divider(indent: 18, endIndent: 18),
        const ListTile(
          title: Text('数据来源：Bangumi'),
          subtitle: Text('资料缓存在本机；封面上的 ⓘ 可更正匹配'),
        ),
      ]),
      const SizedBox(height: 24),
      _section(context, '文件与播放'),
      const SizedBox(height: 12),
      _group([
        ListTile(
          leading: const Icon(Icons.create_new_folder_outlined),
          title: const Text('导入本地视频'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: picking ? null : onImport,
        ),
        const Divider(indent: 18, endIndent: 18),
        const ListTile(
          leading: Icon(Icons.subtitles_outlined),
          title: Text('外挂字幕'),
          subtitle: Text('在播放设置添加 SRT、ASS、SSA 或 VTT'),
        ),
        const Divider(indent: 18, endIndent: 18),
        const ListTile(
          leading: Icon(Icons.bookmark_border_rounded),
          title: Text('自动保存播放进度'),
          subtitle: Text('重新打开同一视频时，从上次继续'),
        ),
      ]),
      const SizedBox(height: 24),
      _section(context, '关于'),
      const SizedBox(height: 12),
      _group([
        const ListTile(
          leading: OrvexBrand(compact: true),
          title: Text('Orvex'),
          trailing: Text('0.1.0'),
        ),
        const Divider(indent: 18, endIndent: 18),
        ListTile(
          leading: const Icon(Icons.description_outlined),
          title: const Text('开源许可'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => showLicensePage(
            context: context,
            applicationName: 'Orvex',
            applicationVersion: '0.1.0',
          ),
        ),
      ]),
    ],
  );

  Widget _group(List<Widget> children) =>
      GlassSurface(child: Column(children: children));
  Widget _section(
    BuildContext context,
    String title, {
    String? action,
    String? detail,
    VoidCallback? onTap,
  }) => Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: tab == 0
              ? Theme.of(context).textTheme.titleMedium
              : Theme.of(context).textTheme.titleLarge,
        ),
      ),
      if (detail != null)
        Text(detail, style: Theme.of(context).textTheme.bodySmall),
      if (action != null)
        TextButton(
          onPressed: onTap,
          style: tab == 0
              ? TextButton.styleFrom(
                  foregroundColor: OrvexColors.of(context).secondary,
                  textStyle: Theme.of(context).textTheme.labelMedium,
                )
              : null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(action),
              if (tab == 0) ...[
                const SizedBox(width: 2),
                const Icon(Icons.chevron_right_rounded, size: 16),
              ],
            ],
          ),
        ),
    ],
  );
  Widget _tileIcon(BuildContext context, IconData icon) {
    final colors = OrvexColors.of(context);
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: colors.accent.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(OrvexMetrics.coverRadius),
      ),
      child: Icon(icon, color: colors.accent),
    );
  }

  Widget _emptyState(
    BuildContext context,
    IconData icon,
    String title,
    String subtitle, {
    bool import = false,
  }) => GlassSurface(
    radius: OrvexMetrics.panelRadius,
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
    child: SizedBox(
      width: double.infinity,
      child: Column(
        children: [
          _tileIcon(context, icon),
          const SizedBox(height: 18),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (import) ...[
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: picking ? null : onImport,
              icon: const Icon(Icons.add_rounded),
              label: const Text('导入视频'),
            ),
          ],
        ],
      ),
    ),
  );
}

String mediaTitle(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

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
    final colors = OrvexColors.of(context);
    final fallback = ColoredBox(
      color: colors.elevated,
      child: Stack(
        children: [
          Center(
            child: Icon(
              Icons.movie_outlined,
              size: poster ? 34 : 28,
              color: colors.secondary.withValues(alpha: 0.6),
            ),
          ),
          Positioned(
            top: 10,
            left: 10,
            child: Text(
              media.name.split('.').last.toUpperCase(),
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        ],
      ),
    );
    return posterPath == null
        ? fallback
        : Image.file(
            File(posterPath!),
            fit: BoxFit.cover,
            cacheWidth: 600,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => fallback,
            frameBuilder: (context, child, frame, _) =>
                frame == null ? fallback : child,
          );
  }
}

const _tabLabels = ['首页', '媒体库', '播放记录', '设置'];
const _tabIcons = [
  Icons.home_outlined,
  Icons.video_library_outlined,
  Icons.history_rounded,
  Icons.settings_outlined,
];
const _tabSelectedIcons = [
  Icons.home_rounded,
  Icons.video_library_rounded,
  Icons.history_rounded,
  Icons.settings_rounded,
];

class LibraryTabBar extends StatelessWidget {
  const LibraryTabBar({
    super.key,
    required this.selected,
    required this.onSelected,
  });
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = OrvexColors.of(context);
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: GlassSurface(
            blur: true,
            subtle: true,
            radius: OrvexMetrics.navigationRadius,
            padding: const EdgeInsets.all(4),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final horizontal =
                    constraints.maxWidth >= 460 &&
                    MediaQuery.textScalerOf(context).scale(11) <= 16;
                return Row(
                  children: [
                    for (var index = 0; index < 4; index++)
                      Expanded(
                        child: Semantics(
                          selected: selected == index,
                          button: true,
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              key: ValueKey('tab-$index'),
                              onTap: () => onSelected(index),
                              borderRadius: BorderRadius.circular(
                                OrvexMetrics.controlRadius,
                              ),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  minHeight: OrvexMetrics.hitSize,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 4,
                                    horizontal: 2,
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (horizontal)
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Icon(
                                              selected == index
                                                  ? _tabSelectedIcons[index]
                                                  : _tabIcons[index],
                                              size: OrvexMetrics.iconSize,
                                              color: selected == index
                                                  ? colors.accent
                                                  : colors.secondary,
                                            ),
                                            const SizedBox(width: 6),
                                            Text(
                                              _tabLabels[index],
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: selected == index
                                                    ? FontWeight.w600
                                                    : FontWeight.w400,
                                                color: selected == index
                                                    ? colors.accent
                                                    : colors.secondary,
                                              ),
                                            ),
                                          ],
                                        )
                                      else ...[
                                        Icon(
                                          selected == index
                                              ? _tabSelectedIcons[index]
                                              : _tabIcons[index],
                                          size: OrvexMetrics.iconSize,
                                          color: selected == index
                                              ? colors.accent
                                              : colors.secondary,
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          _tabLabels[index],
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: selected == index
                                                ? FontWeight.w600
                                                : FontWeight.w400,
                                            color: selected == index
                                                ? colors.accent
                                                : colors.secondary,
                                          ),
                                        ),
                                      ],
                                      const SizedBox(height: 3),
                                      AnimatedContainer(
                                        duration: OrvexMetrics.duration(
                                          context,
                                        ),
                                        curve: OrvexMetrics.curve,
                                        width: selected == index ? 12 : 0,
                                        height: 2,
                                        decoration: BoxDecoration(
                                          color: colors.accent,
                                          borderRadius: BorderRadius.circular(
                                            OrvexMetrics.pillRadius,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class LibrarySidebar extends StatelessWidget {
  const LibrarySidebar({
    super.key,
    required this.selected,
    required this.onSelected,
  });
  final int selected;
  final ValueChanged<int> onSelected;
  @override
  Widget build(BuildContext context) {
    final colors = OrvexColors.of(context);
    return SizedBox(
      width: 190,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 24, 14, 16),
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 30),
              child: OrvexBrand(),
            ),
            for (var index = 0; index < 4; index++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: selected == index
                      ? colors.accent.withValues(alpha: 0.1)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(OrvexMetrics.coverRadius),
                  child: ListTile(
                    key: ValueKey('tab-$index'),
                    selected: selected == index,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(
                        OrvexMetrics.coverRadius,
                      ),
                    ),
                    leading: Icon(
                      selected == index
                          ? _tabSelectedIcons[index]
                          : _tabIcons[index],
                      size: 22,
                      color: selected == index
                          ? colors.accent
                          : colors.secondary,
                    ),
                    title: Text(
                      _tabLabels[index],
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: selected == index
                            ? colors.accent
                            : colors.secondary,
                      ),
                    ),
                    onTap: () => onSelected(index),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
