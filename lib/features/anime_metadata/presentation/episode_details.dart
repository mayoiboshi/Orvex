import 'package:flutter/material.dart';

import '../../../design/orvex_theme.dart';
import '../../player/domain/playback_engine.dart';
import '../application/anime_metadata_controller.dart';
import '../domain/anime_episode.dart';

class EpisodeDetails extends StatefulWidget {
  const EpisodeDetails({
    super.key,
    required this.metadata,
    required this.media,
    required this.subjectId,
    required this.number,
    required this.automatic,
  });

  final AnimeMetadataController metadata;
  final LocalMedia media;
  final int subjectId, number;
  final bool automatic;

  @override
  State<EpisodeDetails> createState() => _EpisodeDetailsState();
}

class _EpisodeDetailsState extends State<EpisodeDetails> {
  late var _result = _load();
  bool _saving = false;
  String? _saveError;

  Future<({AnimeEpisode? episode, bool manual, String? message})>
  _load() async {
    final saved = await widget.metadata.savedEpisode(
      widget.media,
      widget.subjectId,
    );
    if (saved != null) return (episode: saved, manual: true, message: null);
    if (!widget.automatic) return (episode: null, manual: false, message: null);
    final episodes = await widget.metadata.episodesFor(widget.subjectId);
    final matches = episodes.where((episode) => episode.matches(widget.number));
    if (matches.length == 1) {
      return (episode: matches.single, manual: false, message: null);
    }
    return (
      episode: null,
      manual: false,
      message: matches.isEmpty ? 'Bangumi 暂无对应集数' : '集号有多个候选，请手动确认',
    );
  }

  Future<void> _pick() async {
    final selected = await showModalBottomSheet<AnimeEpisode>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _EpisodePicker(
        load: () => widget.metadata.episodesFor(widget.subjectId),
      ),
    );
    if (mounted && selected != null) await _save(selected);
  }

  Future<void> _save(AnimeEpisode? episode) async {
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      await widget.metadata.saveEpisode(
        widget.media,
        widget.subjectId,
        episode,
      );
      if (mounted) setState(() => _result = _load());
    } catch (_) {
      if (mounted) setState(() => _saveError = '单集选择未能保存，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _result,
    builder: (context, snapshot) {
      final result = snapshot.data;
      final episode = result?.episode;
      final loading = snapshot.connectionState != ConnectionState.done;
      final colors = OrvexColors.of(context);
      final text = Theme.of(context).textTheme;
      final details = [
        if (episode != null) episode.label,
        if (episode != null && episode.airdate.isNotEmpty) episode.airdate,
        if (episode != null && episode.duration.isNotEmpty) episode.duration,
      ];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (episode != null) ...[
            Text(
              episode.title.isEmpty ? episode.label : episode.title,
              style: text.titleSmall,
            ),
            const SizedBox(height: OrvexMetrics.small),
            Text(
              details.join(' · '),
              style: text.bodySmall?.copyWith(color: colors.secondary),
            ),
            if (episode.description.isNotEmpty) ...[
              const SizedBox(height: OrvexMetrics.small),
              Text(episode.description, style: text.bodyMedium),
            ],
          ] else if (loading)
            Text('正在读取单集资料…', style: text.bodySmall)
          else if (snapshot.hasError)
            Text('单集资料暂未读取，可重试', style: text.bodySmall)
          else if (result?.message case final String message)
            Text(message, style: text.bodySmall),
          if (_saveError case final String error)
            Text(error, style: text.bodySmall?.copyWith(color: colors.error)),
          Wrap(
            spacing: OrvexMetrics.small,
            children: [
              TextButton(
                onPressed: _saving ? null : _pick,
                child: Text(
                  episode == null ? '选择 Bangumi 单集' : '更正 Bangumi 单集',
                ),
              ),
              if (result?.manual == true)
                TextButton(
                  onPressed: _saving ? null : () => _save(null),
                  child: const Text('清除手动选择'),
                ),
              if (snapshot.hasError)
                TextButton(
                  onPressed: _saving
                      ? null
                      : () => setState(() => _result = _load()),
                  child: const Text('重试'),
                ),
            ],
          ),
        ],
      );
    },
  );
}

class _EpisodePicker extends StatefulWidget {
  const _EpisodePicker({required this.load});

  final Future<List<AnimeEpisode>> Function() load;

  @override
  State<_EpisodePicker> createState() => _EpisodePickerState();
}

class _EpisodePickerState extends State<_EpisodePicker> {
  late final _episodes = widget.load();
  String _query = '';

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
    heightFactor: 0.85,
    child: Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: FutureBuilder(
        future: _episodes,
        builder: (context, snapshot) {
          final episodes = snapshot.data;
          if (snapshot.hasError) {
            return Center(child: Text('${snapshot.error}'));
          }
          if (episodes == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final query = _query.trim().toLowerCase();
          final number = int.tryParse(query);
          final results = query.isEmpty
              ? episodes
              : episodes
                    .where(
                      (episode) => number != null
                          ? episode.matches(number)
                          : '${episode.label} ${episode.name} ${episode.chineseName}'
                                .toLowerCase()
                                .contains(query),
                    )
                    .toList();
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: OrvexMetrics.page,
                ),
                child: TextField(
                  decoration: const InputDecoration(
                    labelText: '搜索集号或标题',
                    prefixIcon: Icon(Icons.search_rounded),
                  ),
                  onChanged: (value) => setState(() => _query = value),
                ),
              ),
              Expanded(
                child: results.isEmpty
                    ? const Center(child: Text('未找到单集'))
                    : ListView.builder(
                        itemCount: results.length,
                        itemBuilder: (context, index) {
                          final episode = results[index];
                          return ListTile(
                            title: Text(
                              episode.title.isEmpty
                                  ? episode.label
                                  : episode.title,
                            ),
                            subtitle: Text(episode.label),
                            onTap: () => Navigator.pop(context, episode),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    ),
  );
}
