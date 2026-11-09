import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../player/domain/playback_engine.dart';
import '../../../design/orvex_theme.dart';
import '../application/anime_metadata_controller.dart';
import '../domain/anime_subject.dart';

class AnimeMetadataSheet extends StatefulWidget {
  const AnimeMetadataSheet({
    super.key,
    required this.media,
    required this.metadata,
    this.group = const [],
  });
  final LocalMedia media;
  final AnimeMetadataController metadata;
  final List<LocalMedia> group;

  @override
  State<AnimeMetadataSheet> createState() => _AnimeMetadataSheetState();
}

class _AnimeMetadataSheetState extends State<AnimeMetadataSheet> {
  OrvexColors get _colors => OrvexColors.of(context);
  late final TextEditingController _query;
  List<AnimeSubject> _results = [];
  bool _busy = false;
  bool _expandedSummary = false;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _query = TextEditingController(
      text: widget.metadata.queryFor(widget.media),
    );
    _results = widget.metadata.matchFor(widget.media)?.candidates ?? [];
  }

  @override
  void dispose() {
    _generation++;
    _query.dispose();
    super.dispose();
  }

  Future<void> _search({bool localOnly = false}) async {
    final query = _query.text.trim();
    if (query.length < 2 || _busy) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final results = await widget.metadata.search(
        query,
        localOnly: localOnly,
        isCurrent: () => mounted && generation == _generation,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _results = results.subjects;
        if (_results.isEmpty) {
          _error = results.local
              ? '本地索引未找到此作品，可试试其他别名。'
              : '未找到条目，试试中文名、原名或其他别名。';
        }
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = '$error');
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _select(AnimeSubject? subject) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.metadata.selectMany(
        widget.group.isEmpty ? [widget.media] : widget.group,
        subject,
      );
      if (mounted) setState(() => _results = []);
    } catch (_) {
      if (mounted) setState(() => _error = '关联未能保存，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _complete() async {
    if (_busy) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.metadata.completeFromBangumi(
        widget.media,
        isCurrent: () => mounted && generation == _generation,
      );
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = '在线补全失败，已保留本地资料。\n$error');
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedPadding(
    duration: OrvexMetrics.duration(context),
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: FractionallySizedBox(
      heightFactor: 0.91,
      child: ListenableBuilder(
        listenable: widget.metadata,
        builder: (context, _) {
          final match = widget.metadata.matchFor(widget.media);
          final subject = match?.subject;
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 30),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '番剧资料',
                        style: TextStyle(
                          fontSize: 23,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭番剧资料',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  widget.media.name,
                  style: TextStyle(
                    color: _colors.secondary,
                    fontSize: 12,
                    height: 1.6,
                  ),
                ),
                if (widget.group.length > 1)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '更正或取消关联将应用于同组 ${widget.group.length} 个视频',
                      style: TextStyle(color: _colors.secondary, fontSize: 12),
                    ),
                  ),
                const SizedBox(height: 22),
                if (subject != null) ...[
                  _subject(subject),
                  const SizedBox(height: 12),
                  Text(
                    match!.manual
                        ? '已手动关联'
                        : subject.relatedSearchNames.isNotEmpty
                        ? '已自动匹配 · Bangumi 主线关联'
                        : '已自动匹配',
                    style: TextStyle(color: _colors.accent, fontSize: 12),
                  ),
                  if (subject.fromLocalIndex || match.usedLocalIndex)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        !subject.fromLocalIndex
                            ? '通过本地索引识别 · 已有 Bangumi 在线资料'
                            : subject.bangumiId != null
                            ? '已使用本地番剧索引（bangumi-data），部分资料待联网补全。'
                            : '已使用本地番剧索引（bangumi-data），可手动搜索其他资料。',
                        style: TextStyle(
                          color: _colors.secondary,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  const SizedBox(height: 20),
                  if (subject.summary.isNotEmpty) ...[
                    const Text(
                      '剧情简介',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      subject.summary,
                      maxLines: _expandedSummary ? null : 6,
                      overflow: _expandedSummary
                          ? TextOverflow.visible
                          : TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _colors.text,
                        height: 1.8,
                        fontSize: 14,
                      ),
                    ),
                    if (subject.summary.length > 180)
                      TextButton(
                        onPressed: () => setState(
                          () => _expandedSummary = !_expandedSummary,
                        ),
                        child: Text(_expandedSummary ? '收起简介' : '展开简介'),
                      ),
                    const SizedBox(height: 18),
                  ],
                  if (subject.bangumiId != null)
                    OutlinedButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: subject.sourceUrl),
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已复制 Bangumi 条目链接')),
                          );
                        }
                      },
                      icon: const Icon(Icons.link_rounded, size: 18),
                      label: Text('Bangumi · #${subject.id} · 复制链接'),
                    ),
                  if (subject.fromLocalIndex && subject.bangumiId != null)
                    TextButton.icon(
                      onPressed: _busy ? null : _complete,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('从 Bangumi 补全资料'),
                    ),
                  const SizedBox(height: 22),
                ] else ...[
                  Text(switch (match?.status) {
                    AnimeMatchStatus.queued => '正在从 Bangumi 匹配资料…',
                    AnimeMatchStatus.needsReview =>
                      match?.usedLocalIndex == true
                          ? '本地索引找到不够确定的候选，请确认作品。'
                          : '发现多个或不够确定的结果，请选择正确条目。',
                    AnimeMatchStatus.notFound
                        when match?.usedLocalIndex == true =>
                      '本地索引未找到此作品，视频仍可正常播放。',
                    AnimeMatchStatus.failed =>
                      match?.error ?? '自动匹配暂未完成，请搜索重试。',
                    AnimeMatchStatus.ignored => '此视频已设为不关联，可在下方重新搜索。',
                    _ => '尚未匹配到番剧，可修改片名后搜索。',
                  }, style: TextStyle(color: _colors.text, height: 1.7)),
                  const SizedBox(height: 22),
                ],
                Divider(color: _colors.divider),
                const SizedBox(height: 16),
                Text(
                  subject == null ? '搜索番剧' : '匹配有误？搜索更换',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _query,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  decoration: InputDecoration(
                    hintText: '输入中文名、原名或别名',
                    filled: true,
                    fillColor: _colors.elevated,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(
                        OrvexMetrics.controlRadius,
                      ),
                      borderSide: BorderSide.none,
                    ),
                    suffixIcon: IconButton(
                      tooltip: '搜索 Bangumi',
                      onPressed: _busy ? null : _search,
                      icon: const Icon(Icons.search_rounded),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '仅查询片名，不上传视频、字幕或文件路径。',
                  style: TextStyle(
                    color: _colors.secondary,
                    fontSize: 11,
                    height: 1.6,
                  ),
                ),
                if (widget.metadata.localIndex != null)
                  TextButton.icon(
                    onPressed: _busy ? null : () => _search(localOnly: true),
                    icon: const Icon(Icons.storage_rounded, size: 18),
                    label: const Text('搜索本地番剧索引'),
                  ),
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 14),
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      _error!,
                      style: TextStyle(color: _colors.error),
                    ),
                  ),
                for (final result in _results) ...[
                  const SizedBox(height: 12),
                  Material(
                    color: _colors.surface,
                    borderRadius: BorderRadius.circular(
                      OrvexMetrics.controlRadius,
                    ),
                    child: ListTile(
                      contentPadding: const EdgeInsets.all(12),
                      leading: SizedBox(
                        width: 42,
                        height: 62,
                        child: _poster(result),
                      ),
                      title: Text(
                        result.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        [
                          [
                            if (result.fromLocalIndex) '本地番剧索引',
                            if (result.platform.isNotEmpty) result.platform,
                            if (result.date.isNotEmpty) result.date,
                            if (result.episodes > 0) '${result.episodes} 集',
                          ].join(' · '),
                          result.name,
                        ].where((value) => value.isNotEmpty).join('\n'),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.5,
                          color: _colors.secondary,
                        ),
                      ),
                      trailing: const Icon(Icons.add_link_rounded, size: 22),
                      onTap: _busy ? null : () => _select(result),
                    ),
                  ),
                ],
                const SizedBox(height: 22),
                TextButton.icon(
                  onPressed: _busy ? null : () => _select(null),
                  icon: const Icon(Icons.link_off_rounded, size: 18),
                  label: Text(widget.group.length > 1 ? '不关联此剧集' : '不关联此视频'),
                ),
                const SizedBox(height: 12),
                Text(
                  '在线资料与封面：Bangumi（bgm.tv）',
                  style: TextStyle(color: _colors.secondary, fontSize: 11),
                ),
              ],
            ),
          );
        },
      ),
    ),
  );

  Widget _subject(AnimeSubject subject) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 92,
        height: 138,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(OrvexMetrics.smallRadius),
          child: _poster(subject),
        ),
      ),
      const SizedBox(width: 18),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              subject.title,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            if (subject.name != subject.title)
              Text(
                subject.name,
                style: TextStyle(
                  color: _colors.secondary,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            const SizedBox(height: 10),
            Text(
              [
                subject.date,
                if (subject.episodes > 0) '${subject.episodes} 集',
                if (subject.score > 0) '★ ${subject.score.toStringAsFixed(1)}',
              ].where((s) => s.isNotEmpty).join(' · '),
              style: TextStyle(
                color: _colors.accent,
                fontSize: 12,
                height: 1.6,
              ),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _poster(AnimeSubject subject) {
    final fallback = ColoredBox(
      color: _colors.elevated,
      child: Icon(Icons.movie_outlined, color: _colors.secondary),
    );
    final path = widget.metadata.posterPath(subject.id);
    return path == null
        ? fallback
        : Image.file(
            File(path),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => fallback,
          );
  }
}
