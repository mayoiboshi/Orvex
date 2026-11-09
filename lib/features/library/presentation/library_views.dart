import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../design/appearance_controller.dart';
import '../../../design/glass.dart';
import '../../../design/orvex_theme.dart';
import '../../player/domain/playback_defaults.dart';
import '../../player/domain/playback_engine.dart';
import '../../player/infrastructure/playback_preferences.dart';
import '../../anime_metadata/application/anime_metadata_controller.dart';
import '../../anime_metadata/domain/anime_filename.dart';
import '../../anime_metadata/domain/anime_subject.dart';
import '../../anime_metadata/infrastructure/bangumi_data_index.dart';
import '../../folder_library/folder_models.dart';
import '../../folder_library/thumbnail_cache.dart';
import '../../player/presentation/playback_surface.dart';
import '../application/history_browser.dart';
import '../domain/playback_record.dart';
import '../domain/recent_work.dart';
import 'library_browse_style.dart';

class LibraryViews extends StatelessWidget {
  const LibraryViews({
    super.key,
    required this.tab,
    required this.videos,
    required this.history,
    this.historyBrowser,
    required this.loading,
    required this.picking,
    required this.showContinue,
    required this.query,
    required this.onQuery,
    required this.onImport,
    required this.onOpen,
    this.onOpenWithIntent,
    this.playbackPreferences,
    required this.onTab,
    required this.onRefresh,
    required this.onShowContinue,
    required this.metadata,
    required this.onMetadata,
    required this.appearance,
    this.thumbnails,
    this.recentWorks,
    this.onOpenWork,
  });

  final int tab;
  final List<LocalMedia> videos;
  final List<PlaybackRecord> history;
  final HistoryBrowser? historyBrowser;
  final bool loading, picking, showContinue;
  final String query;
  final ValueChanged<String> onQuery;
  final VoidCallback onImport;
  final ValueChanged<LocalMedia> onOpen;
  final void Function(LocalMedia, PlaybackOpenIntent)? onOpenWithIntent;
  final PlaybackPreferences? playbackPreferences;
  final ValueChanged<int> onTab;
  final Future<void> Function() onRefresh;
  final ValueChanged<bool> onShowContinue;
  final AnimeMetadataController metadata;
  final void Function(LocalMedia media, {List<LocalMedia>? group}) onMetadata;
  final AppearanceController appearance;
  final ThumbnailCache? thumbnails;
  final List<RecentWork>? recentWorks;
  final ValueChanged<RecentWork>? onOpenWork;

  List<PlaybackRecord> get continuing =>
      history.where((record) => record.canContinue).toList();

  void _openWithIntent(LocalMedia media, PlaybackOpenIntent intent) {
    final open = onOpenWithIntent;
    if (open == null) {
      onOpen(media);
    } else {
      open(media, intent);
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final home = tab == 0;
      final inset = home
          ? (constraints.maxWidth * 0.04).clamp(
              OrvexMetrics.space,
              OrvexMetrics.section * 2,
            )
          : constraints.maxWidth < 600
          ? OrvexMetrics.page
          : 36.0;
      // With extendBody, Scaffold includes the measured bottom bar in padding.
      final bottom = MediaQuery.paddingOf(context).bottom + OrvexMetrics.page;
      if (tab == 3) {
        final pageInset = libraryBrowseInset(constraints.maxWidth);
        return SingleChildScrollView(
          key: const PageStorageKey('library-tab-3'),
          padding: EdgeInsets.fromLTRB(
            pageInset,
            OrvexMetrics.page,
            pageInset,
            bottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(context),
              const SizedBox(height: OrvexMetrics.section),
              _settings(context),
            ],
          ),
        );
      }
      return RefreshIndicator(
        onRefresh: onRefresh,
        child: tab == 2
            ? _history(
                context,
                libraryBrowseInset(constraints.maxWidth),
                bottom,
              )
            : SingleChildScrollView(
                key: PageStorageKey('library-tab-$tab'),
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(
                  inset,
                  OrvexMetrics.page,
                  inset,
                  bottom,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: 1160),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _header(context),
                        SizedBox(
                          height: tab == 0
                              ? OrvexMetrics.page
                              : OrvexMetrics.section,
                        ),
                        if (loading) ...[
                          const LinearProgressIndicator(minHeight: 2),
                          const SizedBox(height: 20),
                        ],
                        switch (tab) {
                          1 => _library(context),
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
                if (tab == 1)
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
              2 => '查看观看进度，继续上次播放。',
              3 => '按你的方式，享受每一次播放。',
              _ => '喜欢的内容，触手可及。',
            }, style: Theme.of(context).textTheme.bodySmall),
          ],
        );

  Widget _homeHeader(BuildContext context) {
    final colors = OrvexColors.of(context);
    final text = Theme.of(context).textTheme;
    final title = Text('首页', style: text.headlineLarge);
    final count = continuing.length;
    final summary = Text(
      loading
          ? '正在读取媒体…'
          : videos.isEmpty
          ? '添加视频，建立你的媒体库。'
          : '${videos.length} 部视频${showContinue && count > 0 ? ' · $count 部可继续观看' : ' · 随时开始观看'}',
      style: text.bodySmall?.copyWith(color: colors.secondary),
    );
    final button = IconButton.styleFrom(
      minimumSize: const Size.square(OrvexMetrics.hitSize),
      padding: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(OrvexMetrics.smallRadius),
      ),
    );
    final actions = GlassSurface(
      radius: OrvexMetrics.controlRadius,
      padding: const EdgeInsets.all(4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '搜索媒体库',
            onPressed: () => onTab(1),
            style: button.copyWith(
              foregroundColor: WidgetStatePropertyAll(colors.secondary),
            ),
            icon: const Icon(Icons.search_rounded, size: OrvexMetrics.iconSize),
          ),
          IconButton(
            tooltip: '打开本地视频',
            onPressed: picking ? null : onImport,
            style: button.copyWith(
              backgroundColor: WidgetStatePropertyAll(
                colors.accent.withValues(alpha: 0.07),
              ),
              foregroundColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.disabled)
                    ? colors.secondary
                    : colors.accent,
              ),
            ),
            icon: const Icon(Icons.add_rounded, size: OrvexMetrics.iconSize),
          ),
        ],
      ),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const OrvexBrand(),
              const SizedBox(height: OrvexMetrics.gap),
              title,
              const SizedBox(height: 4),
              summary,
            ],
          ),
        ),
        const SizedBox(width: OrvexMetrics.gap),
        actions,
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
    final works = recentWorks?.take(8).toList();
    final recent = works == null
        ? videos.take(8).toList()
        : works.map((work) => work.representative).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showContinue) ...[
          _section(context, '继续观看', action: '播放记录', onTap: () => onTab(2)),
          const SizedBox(height: OrvexMetrics.small),
        ],
        _homeResume(context, resume, others),
        if (recent.isNotEmpty) ...[
          const SizedBox(height: OrvexMetrics.section),
          _section(context, '最近添加', action: '全部', onTap: () => onTab(1)),
          const SizedBox(height: OrvexMetrics.small),
          _posterGrid(
            context,
            recent,
            home: true,
            grouped: {
              for (final work in works ?? const <RecentWork>[])
                if (work.subject != null) work.representative.resumeKey: work,
            },
          ),
        ],
        const SizedBox(height: OrvexMetrics.section),
        _section(context, '我的媒体库', action: '查看全部', onTap: () => onTab(1)),
        const SizedBox(height: OrvexMetrics.small),
        _homeLibrary(context),
      ],
    );
  }

  Widget _homeResume(
    BuildContext context,
    PlaybackRecord? resume,
    List<PlaybackRecord> others,
  ) {
    final hero = _hero(context, resume);
    if (others.isEmpty) return hero;
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final sideBySide =
            constraints.maxWidth >= 950 && scaler.scale(14) <= 20;
        final heroWidth = constraints.maxWidth * 0.61;
        final railWidth = sideBySide
            ? constraints.maxWidth - heroWidth - OrvexMetrics.space
            : constraints.maxWidth;
        final cardWidth = sideBySide
            ? (railWidth / 2.6).clamp(128.0, 168.0)
            : (railWidth * 0.42).clamp(148.0, 224.0);
        final timeLines = cardWidth < 176 || scaler.scale(12) > 17 ? 2 : 1;
        final rail = SizedBox(
          height:
              cardWidth * 9 / 16 +
              scaler.scale(14) * 2.6 +
              scaler.scale(12) * 1.4 * timeLines +
              OrvexMetrics.section +
              6,
          child: ListView.separated(
            key: const ValueKey('home-continue-rail'),
            scrollDirection: Axis.horizontal,
            itemCount: others.length,
            separatorBuilder: (_, _) => const SizedBox(width: OrvexMetrics.gap),
            itemBuilder: (context, index) => SizedBox(
              width: cardWidth,
              child: _continueCard(context, others[index]),
            ),
          ),
        );
        return sideBySide
            ? Row(
                children: [
                  SizedBox(width: heroWidth, child: hero),
                  const SizedBox(width: OrvexMetrics.space),
                  Expanded(child: rail),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  hero,
                  const SizedBox(height: OrvexMetrics.space),
                  rail,
                ],
              );
      },
    );
  }

  Widget _homeLibrary(BuildContext context) {
    final colors = OrvexColors.of(context);
    final text = Theme.of(context).textTheme;
    final previews = videos.take(3).toList();
    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(OrvexMetrics.cardRadius),
        side: BorderSide(color: colors.divider),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const ValueKey('home-library'),
        onTap: () => onTab(1),
        child: Padding(
          padding: const EdgeInsets.all(OrvexMetrics.space),
          child: Row(
            children: [
              if (previews.isEmpty)
                _tileIcon(context, Icons.video_library_outlined)
              else
                SizedBox(
                  width: 42 + (previews.length - 1) * 16,
                  height: 58,
                  child: Stack(
                    children: [
                      for (var i = previews.length - 1; i >= 0; i--)
                        Positioned(
                          left: i * 16.0,
                          top: i * 4.0,
                          bottom: i * 4.0,
                          width: 42,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: colors.surface,
                              borderRadius: BorderRadius.circular(
                                OrvexMetrics.smallRadius,
                              ),
                              border: Border.all(color: colors.divider),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(2),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(
                                  OrvexMetrics.small,
                                ),
                                child: _cover(previews[i], poster: true),
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
                      style: text.bodySmall?.copyWith(color: colors.secondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: OrvexMetrics.gap),
              Icon(
                Icons.chevron_right_rounded,
                size: OrvexMetrics.iconSize,
                color: colors.secondary,
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
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: GlassSurface(
          key: const ValueKey('home-resume-card'),
          radius: OrvexMetrics.cardRadius,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final wide =
                  width >= 560 &&
                  MediaQuery.textScalerOf(context).scale(14) <= 22;
              final inset = wide ? OrvexMetrics.space : OrvexMetrics.gap;
              final posterWidth = (width * 0.24).clamp(
                72.0,
                wide ? 128.0 : 112.0,
              );
              final progress = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _homeProgress(context, record.progress),
                  const SizedBox(height: OrvexMetrics.small),
                  Wrap(
                    spacing: OrvexMetrics.gap,
                    runSpacing: 4,
                    children: [
                      Text(
                        '${formatTime(record.position)} / ${formatTime(record.duration)}',
                        style: text.bodySmall,
                      ),
                      Text(
                        '已观看 ${(record.progress * 100).round()}%',
                        style: text.bodySmall?.copyWith(
                          color: colors.secondary,
                        ),
                      ),
                    ],
                  ),
                ],
              );
              final play = FilledButton.icon(
                key: const ValueKey('home-resume'),
                onPressed: () =>
                    _openWithIntent(record.media, PlaybackOpenIntent.resume),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, OrvexMetrics.hitSize),
                  padding: const EdgeInsets.symmetric(
                    horizontal: OrvexMetrics.gap,
                  ),
                  shape: const StadiumBorder(),
                ),
                icon: const Icon(
                  Icons.play_arrow_rounded,
                  size: OrvexMetrics.iconSize,
                ),
                label: const Text('继续播放'),
              );
              return Padding(
                padding: EdgeInsets.all(inset),
                child: Row(
                  children: [
                    SizedBox(
                      width: posterWidth,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(
                          OrvexMetrics.coverRadius,
                        ),
                        child: AspectRatio(
                          aspectRatio: 2 / 3,
                          child: _cover(
                            record.media,
                            poster: true,
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: wide ? OrvexMetrics.page : OrvexMetrics.gap,
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            subject?.title ?? _mediaTitle(record.media),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: wide ? text.titleLarge : text.titleMedium,
                          ),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: OrvexMetrics.gap,
                            runSpacing: 4,
                            children: [
                              Text(
                                episode.isEmpty ? '本地媒体' : episode,
                                style: text.labelMedium?.copyWith(
                                  color: colors.accent,
                                ),
                              ),
                              Text(
                                _mediaCaption(record.media),
                                style: text.bodySmall,
                              ),
                            ],
                          ),
                          const SizedBox(height: OrvexMetrics.space),
                          if (wide)
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 600),
                              child: Row(
                                children: [
                                  Expanded(child: progress),
                                  const SizedBox(width: OrvexMetrics.space),
                                  play,
                                ],
                              ),
                            )
                          else ...[
                            progress,
                            const SizedBox(height: OrvexMetrics.gap),
                            play,
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _continueCard(BuildContext context, PlaybackRecord record) => InkWell(
    key: ValueKey('home-continue-${record.media.resumeKey}'),
    borderRadius: BorderRadius.circular(OrvexMetrics.coverRadius),
    onTap: () => _openWithIntent(record.media, PlaybackOpenIntent.resume),
    onLongPress: () => onMetadata(record.media),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(OrvexMetrics.coverRadius),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: LocalVideoArtwork(
              media: record.media,
              cache: thumbnails,
              entry: thumbnails?.library.entry(record.media),
              fallback: _cover(record.media, fit: BoxFit.contain),
            ),
          ),
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
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
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
    Map<String, RecentWork> grouped = const {},
  }) => LayoutBuilder(
    builder: (context, constraints) {
      final available = constraints.maxWidth;
      final gap = home && available < 600
          ? OrvexMetrics.gap
          : OrvexMetrics.space;
      final largeText = MediaQuery.textScalerOf(context).scale(14) > 21;
      final target = available >= 950
          ? 172.0
          : available >= 740
          ? 200.0
          : 140.0;
      final columns = home
          ? ((available + gap) / (target + gap + (largeText ? 32 : 0)))
                .floor()
                .clamp(1, 6)
          : (available / 174).floor().clamp(2, 6);
      final width = (available - (columns - 1) * gap) / columns;
      final durations = <String, Duration>{
        if (home)
          for (final record in history)
            if (record.duration > Duration.zero)
              record.media.resumeKey: record.duration,
      };
      return Wrap(
        spacing: gap,
        runSpacing: home ? OrvexMetrics.section : 22,
        children: [
          for (final media in items)
            _posterTile(
              context,
              media,
              width: width,
              home: home,
              work: grouped[media.resumeKey],
              duration: durations[media.resumeKey],
            ),
        ],
      );
    },
  );

  Widget _posterTile(
    BuildContext context,
    LocalMedia media, {
    required double width,
    required bool home,
    RecentWork? work,
    Duration? duration,
  }) {
    final series = work?.subject;
    final standalone = home && series == null
        ? _standalonePosterSubject(media)
        : null;
    final subject = series ?? standalone;
    final captionSubject = home ? subject ?? metadata.subjectFor(media) : null;
    final caption = captionSubject == null
        ? _mediaCaption(media)
        : _subjectCaption(captionSubject, includeSource: false);
    void showMetadata() => onMetadata(media, group: work?.files);
    return SizedBox(
      width: width,
      child: InkWell(
        key: home
            ? ValueKey('home-recent-${work?.key ?? media.resumeKey}')
            : null,
        borderRadius: BorderRadius.circular(OrvexMetrics.coverRadius),
        onTap: () {
          if (work != null && onOpenWork != null) {
            onOpenWork!(work);
          } else {
            onOpen(media);
          }
        },
        onLongPress: showMetadata,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(OrvexMetrics.coverRadius),
              child: AspectRatio(
                aspectRatio: !home || subject != null ? 2 / 3 : 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    home
                        ? _recentArtwork(
                            media,
                            duration,
                            series: series,
                            standalone: standalone,
                          )
                        : _cover(media, poster: true),
                    Positioned(
                      top: home ? 2 : 6,
                      right: home ? 2 : 6,
                      child: home
                          ? PosterInfoButton(
                              tooltip: '番剧资料',
                              onPressed: showMetadata,
                            )
                          : GlassIconButton(
                              immersive: true,
                              icon: Icons.info_outline_rounded,
                              tooltip: '番剧资料',
                              onPressed: showMetadata,
                            ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(height: home ? OrvexMetrics.small : 10),
            if (home)
              SizedBox(
                height: MediaQuery.textScalerOf(context).scale(14) * 1.3 * 2,
                child: Text(
                  subject?.title ?? _recentTitle(media),
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
            if (caption.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                caption,
                maxLines: home ? null : 1,
                overflow: home ? null : TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
            if (subject != null) ...[
              SizedBox(height: caption.isEmpty ? 4 : 2),
              Text(
                '已收录 ${work?.files.length ?? 1} 个视频',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _history(BuildContext context, double inset, double bottom) {
    final browser = historyBrowser;
    final latest = {
      for (final record in history) record.media.resumeKey: record,
    };
    return browser == null
        ? _historyList(context, inset, bottom, null, latest)
        : ListenableBuilder(
            listenable: browser,
            builder: (context, _) =>
                _historyList(context, inset, bottom, browser, latest),
          );
  }

  Widget _historyList(
    BuildContext context,
    double inset,
    double bottom,
    HistoryBrowser? browser,
    Map<String, PlaybackRecord> latest,
  ) {
    final records = browser?.records ?? history;
    final total = browser == null ? history.length : browser.total;
    final waiting = browser == null
        ? loading
        : total == null && (loading || browser.refreshing);
    final indices = {
      for (var i = 0; i < records.length; i++) records[i].media.resumeKey: i,
    };
    final refreshFailed =
        browser != null &&
        (browser.refreshFailed || (total == null && !waiting));
    return _HistoryScroll(
      browser: browser,
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(inset, OrvexMetrics.page, inset, 0),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _header(context),
                const SizedBox(height: OrvexMetrics.section),
                if (waiting)
                  const LinearProgressIndicator(minHeight: 2)
                else if (total == 0 && !refreshFailed)
                  _emptyState(
                    context,
                    Icons.history_rounded,
                    '还没有播放记录',
                    '从媒体库播放视频后，可在这里查看进度并继续观看。',
                    action: FilledButton.icon(
                      onPressed: () => onTab(1),
                      icon: const Icon(Icons.video_library_outlined),
                      label: const Text('前往媒体库'),
                    ),
                  ),
                if (total != null && total > 0) ...[
                  _section(context, '最近播放', detail: '$total 条记录'),
                  const SizedBox(height: OrvexMetrics.gap),
                ],
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: inset),
          sliver: SliverList.builder(
            itemCount: records.length,
            findChildIndexCallback: (key) =>
                indices[(key as ValueKey<String>).value],
            itemBuilder: (context, index) {
              final record = records[index];
              final current = latest[record.media.resumeKey];
              final currentTime = current?.updatedAt;
              final previousTime = record.updatedAt;
              final updated =
                  currentTime != null &&
                  (previousTime == null || currentTime.isAfter(previousTime));
              return Padding(
                key: ValueKey(record.media.resumeKey),
                padding: const EdgeInsets.only(bottom: OrvexMetrics.small),
                child: _recordTile(context, updated ? current! : record),
              );
            },
          ),
        ),
        if (browser != null &&
            (refreshFailed || browser.appendFailed || browser.appending))
          SliverToBoxAdapter(
            child: Center(
              child: browser.appending
                  ? const Padding(
                      padding: EdgeInsets.all(OrvexMetrics.gap),
                      child: SizedBox.square(
                        dimension: OrvexMetrics.iconSize,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : TextButton.icon(
                      onPressed: refreshFailed
                          ? onRefresh
                          : () => browser.loadMore(retry: true),
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(
                        refreshFailed ? '读取记录失败 · 重试' : '加载更多记录失败 · 重试',
                      ),
                    ),
            ),
          ),
        SliverToBoxAdapter(child: SizedBox(height: bottom)),
      ],
    );
  }

  Widget _recordTile(BuildContext context, PlaybackRecord record) {
    final media = record.media;
    final theme = Theme.of(context).textTheme;
    final colors = OrvexColors.of(context);
    final library = thumbnails?.library;
    final episode =
        library?.identityFor(media).episode ??
        AnimeFilename.parse(media.name).episode;
    final status = record.completed ? '已看完' : '未看完';
    final position = formatTime(record.position);
    final hasDuration = record.duration > Duration.zero;
    final time = hasDuration
        ? '$position / ${formatTime(record.duration)}'
        : position;
    final recent = _historyDate(context, record.updatedAt);
    void open() => onOpen(media);
    return GlassSurface(
      child: InkWell(
        onTap: open,
        onLongPress: () => onMetadata(media),
        child: LayoutBuilder(
          builder: (context, constraints) => Padding(
            padding: const EdgeInsets.all(OrvexMetrics.gap),
            child: Row(
              children: [
                SizedBox(
                  width: constraints.maxWidth < 320 ? 80 : 112,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(
                      OrvexMetrics.smallRadius,
                    ),
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          LocalVideoArtwork(
                            media: media,
                            cache: thumbnails,
                            entry: library?.entry(media),
                            fallback: _cover(media, fit: BoxFit.contain),
                          ),
                          if (hasDuration)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: LinearProgressIndicator(
                                value: record.progress,
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
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        playbackMediaTitle(media, metadata, episode),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text('$status · $time', style: theme.bodySmall),
                      Text(recent, style: theme.labelSmall),
                    ],
                  ),
                ),
                const SizedBox(width: OrvexMetrics.small),
                IconButton(
                  tooltip: record.completed
                      ? '重新播放'
                      : record.canContinue
                      ? '继续播放'
                      : '播放视频',
                  color: colors.accent,
                  onPressed: record.completed
                      ? () => _openWithIntent(media, PlaybackOpenIntent.restart)
                      : record.canContinue
                      ? () => _openWithIntent(media, PlaybackOpenIntent.resume)
                      : open,
                  icon: const Icon(Icons.play_arrow_rounded),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _historyDate(BuildContext context, DateTime? timestamp) {
    if (timestamp == null) return '最近播放时间未知';
    final local = timestamp.toLocal();
    final now = DateTime.now();
    final localizations = MaterialLocalizations.of(context);
    final day = DateUtils.isSameDay(local, now)
        ? '今天'
        : DateUtils.isSameDay(local, DateTime(now.year, now.month, now.day - 1))
        ? '昨天'
        : localizations.formatCompactDate(local);
    final time = localizations.formatTimeOfDay(
      TimeOfDay.fromDateTime(local),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    return '$day $time';
  }

  Widget _cover(
    LocalMedia media, {
    bool poster = false,
    BoxFit fit = BoxFit.cover,
  }) => MediaCover(
    media: media,
    poster: poster,
    fit: fit,
    posterPath: metadata.posterPath(metadata.subjectFor(media)?.id ?? 0),
  );

  AnimeSubject? _standalonePosterSubject(LocalMedia media) {
    final match = metadata.matchFor(media);
    final subject = match?.subject;
    if (match?.status != AnimeMatchStatus.matched || subject == null) {
      return null;
    }
    final platform = subject.platform.trim();
    return platform == '剧场版' ||
            (platform.toUpperCase() == 'WEB' && subject.episodes == 1)
        ? subject
        : null;
  }

  Widget _recentArtwork(
    LocalMedia media,
    Duration? duration, {
    required AnimeSubject? series,
    required AnimeSubject? standalone,
  }) {
    if (series != null) {
      return MediaCover(
        media: media,
        poster: true,
        posterPath: metadata.posterPath(series.id),
      );
    }
    final entry = thumbnails?.library.entry(media);
    final preview = LocalVideoArtwork(
      media: media,
      cache: thumbnails,
      entry: entry,
      fallback: MediaCover(media: media),
      showDuration: true,
      knownDuration: duration ?? Duration(milliseconds: entry?.duration ?? 0),
    );
    final poster = standalone == null
        ? null
        : metadata.posterPath(standalone.id);
    if (poster == null) return preview;
    return MediaCover(
      media: media,
      poster: true,
      posterPath: poster,
      missingArtwork: preview,
    );
  }

  String _recentTitle(LocalMedia media) {
    final subject = metadata.subjectFor(media);
    if (subject == null) return mediaTitle(media.name);
    final episode =
        thumbnails?.library.identityFor(media).episode ??
        AnimeFilename.parse(media.name).episode;
    return episode == null ? subject.title : '${subject.title} · 第 $episode 集';
  }

  String _mediaTitle(LocalMedia media) {
    final subject = metadata.subjectFor(media);
    if (subject == null) return mediaTitle(media.name);
    final episode = AnimeFilename.parse(media.name).episodeLabel;
    return episode.isEmpty ? subject.title : '${subject.title} · $episode';
  }

  String _mediaCaption(LocalMedia media) {
    final match = metadata.matchFor(media);
    final subject = match?.subject;
    if (subject != null) return _subjectCaption(subject);
    return switch (match?.status) {
      AnimeMatchStatus.queued => '正在匹配番剧…',
      AnimeMatchStatus.needsReview => '匹配待确认',
      AnimeMatchStatus.failed => '匹配失败 · 可重试',
      _ => '${media.name.split('.').last.toUpperCase()} · 本地视频',
    };
  }

  String _subjectCaption(AnimeSubject subject, {bool includeSource = true}) {
    final details = [
      if (subject.date.length >= 4) subject.date.substring(0, 4),
      if (subject.score > 0) '★ ${subject.score.toStringAsFixed(1)}',
    ];
    if (includeSource) {
      details.add(subject.fromLocalIndex ? '本地番剧索引' : 'Bangumi');
    }
    return details.join(' · ');
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
      const SizedBox(height: OrvexMetrics.gap),
      _group([
        PopupMenuButton<ThemeMode>(
          key: const ValueKey('theme-picker'),
          tooltip: '选择主题',
          position: PopupMenuPosition.under,
          onSelected: appearance.setMode,
          itemBuilder: (context) => [
            for (final mode in ThemeMode.values)
              CheckedPopupMenuItem(
                key: ValueKey('theme-${mode.name}'),
                value: mode,
                checked: appearance.mode == mode,
                child: Text(_themeLabel(mode)),
              ),
          ],
          child: ListTile(
            contentPadding: _settingsRowPadding,
            title: Row(
              children: [
                const Expanded(child: Text('主题')),
                const SizedBox(width: OrvexMetrics.small),
                Expanded(
                  child: Text(
                    _themeLabel(appearance.mode),
                    textAlign: TextAlign.end,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const SizedBox(width: OrvexMetrics.small),
                const Icon(
                  Icons.expand_more_rounded,
                  size: OrvexMetrics.iconSize,
                ),
              ],
            ),
          ),
        ),
        _settingsDivider,
        SwitchListTile.adaptive(
          contentPadding: _settingsRowPadding,
          key: const ValueKey('reduce-transparency'),
          value: appearance.reduceTransparency,
          onChanged: appearance.setReduceTransparency,
          title: const Text('减少透明效果'),
          subtitle: Text(
            appearance.systemReduceTransparency
                ? '系统已启用减少透明度，关闭此项仍遵循系统设置。'
                : '让应用内的玻璃表面使用不透明背景。',
          ),
        ),
        if (appearance.error != null)
          Padding(
            padding: const EdgeInsets.all(OrvexMetrics.space),
            child: Text(
              appearance.error!,
              style: TextStyle(color: OrvexColors.of(context).error),
            ),
          ),
      ]),
      if (playbackPreferences case final preferences?)
        _playbackSettings(context, preferences),
      const SizedBox(height: OrvexMetrics.section),
      _section(context, '首页'),
      const SizedBox(height: OrvexMetrics.gap),
      _group([
        SwitchListTile.adaptive(
          contentPadding: _settingsRowPadding,
          title: const Text('显示继续观看'),
          subtitle: const Text('在首页显示可续播的视频。'),
          value: showContinue,
          onChanged: onShowContinue,
        ),
      ]),
      const SizedBox(height: OrvexMetrics.section),
      _section(context, '资料匹配'),
      const SizedBox(height: OrvexMetrics.gap),
      _group([
        SwitchListTile.adaptive(
          contentPadding: _settingsRowPadding,
          key: const ValueKey('automatic-bangumi'),
          title: const Text('自动匹配番剧'),
          value: metadata.automatic,
          onChanged: metadata.setAutomatic,
        ),
        if (metadata.localIndex != null) ...[
          _settingsDivider,
          SwitchListTile.adaptive(
            contentPadding: _settingsRowPadding,
            key: const ValueKey('offline-bangumi-fallback'),
            title: const Text('离线备用匹配'),
            subtitle: const Text('无网络或在线资料源不可用时，使用内置番剧索引匹配基础资料。'),
            value: metadata.offlineFallback,
            onChanged: metadata.setOfflineFallback,
          ),
        ],
        _settingsDivider,
        Padding(
          padding: const EdgeInsets.all(OrvexMetrics.space),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              '来源为 Bangumi。在线查询使用整理后的片名，匹配资料缓存在此设备。可通过封面上的资料按钮更正匹配。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
      ]),
      const SizedBox(height: OrvexMetrics.section),
      _section(context, '关于'),
      const SizedBox(height: OrvexMetrics.gap),
      const _SettingsAbout(),
    ],
  );

  String _themeLabel(ThemeMode mode) => switch (mode) {
    ThemeMode.system => '跟随系统',
    ThemeMode.light => '浅色',
    ThemeMode.dark => '深色',
  };

  Widget _playbackSettings(
    BuildContext context,
    PlaybackPreferences preferences,
  ) => ListenableBuilder(
    listenable: preferences,
    builder: (context, _) {
      final values = preferences.defaults;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: OrvexMetrics.section),
          _section(context, '播放'),
          const SizedBox(height: OrvexMetrics.gap),
          _group([
            _preferenceChoice(
              '重新打开视频',
              values.reopen,
              ReopenBehavior.values,
              (value) => value.label,
              (value) =>
                  preferences.update((old) => old.copyWith(reopen: value)),
            ),
            _settingsDivider,
            _preferenceChoice(
              '默认播放速度',
              values.rate,
              playbackRates,
              (value) => '$value×',
              (value) => preferences.update((old) => old.copyWith(rate: value)),
            ),
            _settingsDivider,
            SwitchListTile.adaptive(
              contentPadding: _settingsRowPadding,
              title: const Text('自动播放下一集'),
              subtitle: const Text('仅在播放队列有明确的相邻剧集时启用。'),
              value: preferences.autoNext,
              onChanged: preferences.setAutoNext,
            ),
            _settingsDivider,
            _preferenceChoice(
              '默认画面适配',
              values.fit,
              PlaybackFit.values,
              (value) => value.label,
              (value) => preferences.update((old) => old.copyWith(fit: value)),
              note: '填满画面可能裁切边缘。',
            ),
            _settingsDivider,
            ListTile(
              contentPadding: _settingsRowPadding,
              title: const Text('操作与手势'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => _playbackControls(preferences),
                ),
              ),
            ),
          ]),
          const SizedBox(height: OrvexMetrics.section),
          _section(context, '字幕与音轨'),
          const SizedBox(height: OrvexMetrics.gap),
          _group([
            _preferenceChoice(
              '字幕偏好',
              values.subtitleLanguage,
              TrackLanguage.values,
              (value) => value.label,
              (value) => preferences.update(
                (old) => old.copyWith(subtitleLanguage: value),
              ),
              note: '按内嵌轨道的语言标签匹配。已记住的字幕优先。',
            ),
            _settingsDivider,
            _preferenceChoice(
              '音轨偏好',
              values.audioLanguage,
              TrackLanguage.values,
              (value) => value.label,
              (value) => preferences.update(
                (old) => old.copyWith(audioLanguage: value),
              ),
              note: '没有匹配的语言时，沿用文件默认音轨。',
            ),
          ]),
          if (preferences.error case final error?)
            Padding(
              padding: const EdgeInsets.all(OrvexMetrics.space),
              child: Text(
                error,
                style: TextStyle(color: OrvexColors.of(context).error),
              ),
            ),
        ],
      );
    },
  );

  Widget _playbackControls(PlaybackPreferences preferences) => Scaffold(
    appBar: AppBar(title: const Text('操作与手势')),
    body: SafeArea(
      top: false,
      child: LayoutBuilder(
        builder: (context, constraints) => ListenableBuilder(
          listenable: preferences,
          builder: (context, _) {
            final mobile = switch (Theme.of(context).platform) {
              TargetPlatform.iOS || TargetPlatform.android => true,
              _ => false,
            };
            return ListView(
              padding: EdgeInsets.symmetric(
                horizontal: libraryBrowseInset(constraints.maxWidth),
                vertical: OrvexMetrics.page,
              ),
              children: [
                _group([
                  _preferenceChoice(
                    '快进快退步长',
                    preferences.defaults.skipSeconds,
                    playbackSkipSteps,
                    (value) => '$value 秒',
                    (value) => preferences.update(
                      (old) => old.copyWith(skipSeconds: value),
                    ),
                    note: mobile ? '用于跳转按钮、方向键和双击跳转。' : '用于跳转按钮和方向键。',
                  ),
                  if (mobile) ...[
                    _settingsDivider,
                    SwitchListTile.adaptive(
                      contentPadding: _settingsRowPadding,
                      title: const Text('触屏播放手势'),
                      subtitle: const Text('控制双击跳转、滑动和中央长按临时倍速。亮度手势仅在设备支持时生效。'),
                      value: preferences.defaults.touchGestures,
                      onChanged: (value) => preferences.update(
                        (old) => old.copyWith(touchGestures: value),
                      ),
                    ),
                  ],
                ]),
                if (preferences.error case final error?)
                  Padding(
                    padding: const EdgeInsets.all(OrvexMetrics.space),
                    child: Text(
                      error,
                      style: TextStyle(color: OrvexColors.of(context).error),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    ),
  );

  Widget _preferenceChoice<T>(
    String title,
    T selected,
    List<T> choices,
    String Function(T) label,
    ValueChanged<T> onSelected, {
    String? note,
  }) => PopupMenuButton<T>(
    key: ValueKey(title),
    tooltip: title,
    position: PopupMenuPosition.under,
    onSelected: onSelected,
    itemBuilder: (_) => [
      for (final choice in choices)
        CheckedPopupMenuItem(
          key: ValueKey((title, label(choice))),
          value: choice,
          checked: choice == selected,
          child: Text(label(choice)),
        ),
    ],
    child: ListTile(
      contentPadding: _settingsRowPadding,
      title: Row(
        children: [
          Expanded(child: Text(title)),
          const SizedBox(width: OrvexMetrics.small),
          Expanded(child: Text(label(selected), textAlign: TextAlign.end)),
          const SizedBox(width: OrvexMetrics.small),
          const Icon(Icons.expand_more_rounded, size: OrvexMetrics.iconSize),
        ],
      ),
      subtitle: note == null ? null : Text(note),
    ),
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
              ? Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: OrvexColors.of(context).text,
                )
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
    Widget? action,
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
          if (action != null) ...[
            const SizedBox(height: OrvexMetrics.page),
            action,
          ],
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

const _settingsRowPadding = EdgeInsets.symmetric(
  horizontal: OrvexMetrics.space,
);

const _settingsDivider = Divider(
  indent: OrvexMetrics.space,
  endIndent: OrvexMetrics.space,
);

class _SettingsAbout extends StatefulWidget {
  const _SettingsAbout();

  @override
  State<_SettingsAbout> createState() => _SettingsAboutState();
}

class _SettingsAboutState extends State<_SettingsAbout> {
  late final _version = _readVersion();

  Future<String?> _readVersion() async {
    try {
      final version = (await PackageInfo.fromPlatform()).version.trim();
      return version.isEmpty ? null : version;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<String?>(
    future: _version,
    builder: (context, snapshot) {
      final version = snapshot.data;
      return GlassSurface(
        child: Column(
          children: [
            ListTile(
              contentPadding: _settingsRowPadding,
              title: const Text('Orvex'),
              subtitle: Text(
                version != null
                    ? '版本 $version'
                    : snapshot.connectionState == ConnectionState.done
                    ? '版本暂不可用'
                    : '正在读取版本…',
              ),
            ),
            _settingsDivider,
            ListTile(
              contentPadding: _settingsRowPadding,
              title: const Text('数据来源'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => showDialog<void>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: const Text('数据来源'),
                  content: const SingleChildScrollView(
                    child: SelectableText(
                      '在线资料与封面：Bangumi（bgm.tv）\n\n'
                      '内置番剧索引：bangumi-data 及其贡献者\n$bangumiDataSource\n\n'
                      '许可：CC BY 4.0\n$bangumiDataLicense\n\n'
                      'Orvex 提取名称、译名、作品类型、首播时间和资讯站点 ID，转换为内置检索格式。',
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Clipboard.setData(
                        const ClipboardData(
                          text: '$bangumiDataSource\n$bangumiDataLicense',
                        ),
                      ),
                      child: const Text('复制项目与许可链接'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('关闭'),
                    ),
                  ],
                ),
              ),
            ),
            _settingsDivider,
            ListTile(
              contentPadding: _settingsRowPadding,
              title: const Text('开源许可'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => showLicensePage(
                context: context,
                applicationName: 'Orvex',
                applicationVersion: version,
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _HistoryScroll extends StatefulWidget {
  const _HistoryScroll({required this.browser, required this.slivers});

  final HistoryBrowser? browser;
  final List<Widget> slivers;

  @override
  State<_HistoryScroll> createState() => _HistoryScrollState();
}

class _HistoryScrollState extends State<_HistoryScroll> {
  final _scroll = ScrollController();
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_schedulePrefetch);
    _schedulePrefetch();
  }

  @override
  void didUpdateWidget(_HistoryScroll oldWidget) {
    super.didUpdateWidget(oldWidget);
    _schedulePrefetch();
  }

  void _schedulePrefetch() {
    if (_scheduled || widget.browser == null) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted ||
          !_scroll.hasClients ||
          ModalRoute.of(context)?.isCurrent == false) {
        return;
      }
      final position = _scroll.position;
      if (position.hasContentDimensions &&
          position.extentAfter <=
              position.viewportDimension * HistoryBrowser.prefetchViewports) {
        unawaited(widget.browser?.loadMore());
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollMetricsNotification>(
        onNotification: (event) {
          if (event.depth == 0) _schedulePrefetch();
          return false;
        },
        child: CustomScrollView(
          key: const PageStorageKey('library-tab-2'),
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: widget.slivers,
        ),
      );
}

String mediaTitle(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

String playbackMediaTitle(
  LocalMedia media,
  AnimeMetadataController metadata,
  int? episode,
) {
  final match = metadata.matchFor(media);
  final subject = match?.status == AnimeMatchStatus.matched
      ? match?.subject
      : null;
  final title = subject?.title.trim();
  if (title == null || title.isEmpty) return media.name;
  final standalone =
      subject!.platform == '剧场版' ||
      (subject.platform != 'TV' && subject.episodes == 1);
  return episode == null || standalone ? title : '$title · 第 $episode 集';
}

class LocalVideoArtwork extends StatefulWidget {
  const LocalVideoArtwork({
    super.key,
    required this.media,
    required this.cache,
    required this.entry,
    required this.fallback,
    this.showDuration = false,
    this.knownDuration = Duration.zero,
  });

  final LocalMedia media;
  final ThumbnailCache? cache;
  final FolderEntry? entry;
  final Widget fallback;
  final bool showDuration;
  final Duration knownDuration;

  @override
  State<LocalVideoArtwork> createState() => _LocalVideoArtworkState();
}

class _LocalVideoArtworkState extends State<LocalVideoArtwork> {
  ThumbnailRequest? _request;
  File? _preview;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(LocalVideoArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cache != widget.cache ||
        oldWidget.media.uri != widget.media.uri ||
        oldWidget.media.resumeKey != widget.media.resumeKey ||
        oldWidget.entry?.cacheVersion != widget.entry?.cacheVersion) {
      _load();
    }
  }

  void _load() {
    _request?.cancel();
    _request = null;
    _preview = null;
    final cache = widget.cache;
    if (cache == null) return;
    final entry = widget.entry;
    final request = entry != null
        ? cache.request(entry)
        : widget.media.relativeImportPath != null
        ? cache.requestImported(widget.media)
        : null;
    if (request == null) return;
    _request = request;
    unawaited(
      request.result.then((preview) {
        if (mounted && identical(_request, request) && preview != null) {
          setState(() => _preview = preview);
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
    final preview = _preview;
    final artwork = preview == null
        ? widget.fallback
        : ColoredBox(
            color: OrvexColors.of(context).elevated,
            child: Image.file(
              preview,
              fit: BoxFit.contain,
              cacheWidth: 480,
              frameBuilder: (context, child, frame, _) =>
                  frame == null ? widget.fallback : child,
              errorBuilder: (_, _, _) => widget.fallback,
            ),
          );
    final duration = widget.knownDuration > Duration.zero
        ? widget.knownDuration
        : Duration(milliseconds: _request?.duration ?? 0);
    if (!widget.showDuration || duration < const Duration(seconds: 1)) {
      return artwork;
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        artwork,
        PositionedDirectional(
          end: OrvexMetrics.small,
          bottom: OrvexMetrics.small,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: OrvexColors.player.overlay,
              borderRadius: BorderRadius.circular(OrvexMetrics.small),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              child: Text(
                formatTime(duration),
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: OrvexColors.player.text),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class PosterInfoButton extends StatelessWidget {
  const PosterInfoButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    this.solidBackground = false,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final bool solidBackground;

  @override
  Widget build(BuildContext context) {
    const colors = OrvexColors.player;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        minimumSize: const Size.square(OrvexMetrics.hitSize),
        padding: EdgeInsets.zero,
      ),
      icon: DecoratedBox(
        decoration: BoxDecoration(
          color: solidBackground ? colors.surface : colors.overlay,
          shape: BoxShape.circle,
        ),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Icon(Icons.info_outline_rounded, size: 16, color: colors.text),
        ),
      ),
    );
  }
}

class MediaCover extends StatelessWidget {
  const MediaCover({
    super.key,
    required this.media,
    this.poster = false,
    this.fit = BoxFit.cover,
    this.posterPath,
    this.missingArtwork,
  });
  final LocalMedia media;
  final bool poster;
  final BoxFit fit;
  final String? posterPath;
  final Widget? missingArtwork;
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
    final path = posterPath;
    if (path == null) return missingArtwork ?? fallback;
    final image = Image.file(
      File(path),
      fit: fit,
      cacheWidth: 600,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => missingArtwork ?? fallback,
      frameBuilder: (_, child, frame, _) => frame == null ? fallback : child,
    );
    return fit == BoxFit.contain
        ? ColoredBox(color: colors.elevated, child: image)
        : image;
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
  static const maxWidth = 500.0;

  @override
  Widget build(BuildContext context) {
    final colors = OrvexColors.of(context);
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(
        OrvexMetrics.gap,
        4,
        OrvexMetrics.gap,
        OrvexMetrics.small,
      ),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: maxWidth),
          child: GlassSurface(
            subtle: true,
            radius: OrvexMetrics.navigationRadius,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final horizontal =
                    constraints.maxWidth >= 396 &&
                    MediaQuery.textScalerOf(context).scale(11) <= 16;
                return IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var index = 0; index < _tabLabels.length; index++)
                        Expanded(
                          child: _tabItem(
                            index,
                            horizontal: horizontal,
                            colors: colors,
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _tabItem(
    int index, {
    required bool horizontal,
    required OrvexColors colors,
  }) {
    final active = selected == index;
    final foreground = active ? colors.accent : colors.secondary;
    final radius = BorderRadius.circular(OrvexMetrics.pillRadius);
    final icon = Icon(
      active ? _tabSelectedIcons[index] : _tabIcons[index],
      size: OrvexMetrics.iconSize,
      color: foreground,
    );
    final label = Text(
      _tabLabels[index],
      maxLines: horizontal ? 1 : 2,
      textAlign: TextAlign.center,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: horizontal ? 12 : 11,
        height: 1.2,
        leadingDistribution: TextLeadingDistribution.even,
        fontWeight: active ? FontWeight.w600 : FontWeight.w400,
        color: foreground,
      ),
    );
    return Semantics(
      selected: active,
      button: true,
      child: Material(
        color: active
            ? colors.accent.withValues(alpha: 0.09)
            : Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          key: ValueKey('tab-$index'),
          onTap: () => onSelected(index),
          borderRadius: radius,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: OrvexMetrics.hitSize),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
              child: Align(
                heightFactor: 1,
                child: horizontal
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          icon,
                          const SizedBox(width: 6),
                          Flexible(child: label),
                        ],
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [icon, const SizedBox(height: 3), label],
                      ),
              ),
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
