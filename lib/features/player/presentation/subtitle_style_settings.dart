import 'dart:async';

import 'package:flutter/material.dart';

import '../application/playback_session.dart';
import '../domain/playback_engine.dart';
import '../domain/subtitle_style.dart';

class SubtitleStyleSettings extends StatefulWidget {
  const SubtitleStyleSettings({
    super.key,
    required this.session,
    this.showTitle = true,
  });
  final PlaybackSession session;
  final bool showTitle;

  @override
  State<SubtitleStyleSettings> createState() => _SubtitleStyleSettingsState();
}

class _SubtitleStyleSettingsState extends State<SubtitleStyleSettings> {
  late SubtitleStyle _style = widget.session.subtitleStyle;
  bool _dragging = false;
  bool _draggingAssStyle = false;
  Timer? _previewTimer;

  bool get _assStyleLocked =>
      widget.session.currentSubtitleFormat == SubtitleTrackFormat.ass &&
      !_style.overrideAss;

  @override
  void didUpdateWidget(covariant SubtitleStyleSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session && _dragging) {
      _previewTimer?.cancel();
      _previewTimer = null;
      unawaited(
        oldWidget.session.previewSubtitleStyle(oldWidget.session.subtitleStyle),
      );
      _dragging = false;
    }
    if (_dragging && _draggingAssStyle && _assStyleLocked) {
      _previewTimer?.cancel();
      _previewTimer = null;
      _dragging = false;
      unawaited(
        widget.session.previewSubtitleStyle(widget.session.subtitleStyle),
      );
    }
    if (oldWidget.session != widget.session ||
        (!_dragging && !identical(_style, widget.session.subtitleStyle))) {
      _style = widget.session.subtitleStyle;
    }
  }

  @override
  void dispose() {
    _previewTimer?.cancel();
    if (_dragging) {
      unawaited(
        widget.session.previewSubtitleStyle(widget.session.subtitleStyle),
      );
    }
    super.dispose();
  }

  void _commit(SubtitleStyle value) {
    setState(() => _style = value);
    unawaited(widget.session.setSubtitleStyle(value));
  }

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    int divisions,
    String suffix,
    SubtitleStyle Function(double) change, {
    bool enabled = true,
    bool assStyle = false,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('$label  ${value.toStringAsFixed(label == '位置' ? 0 : 1)}$suffix'),
      Semantics(
        label: label,
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          label: '$label ${value.toStringAsFixed(1)}$suffix',
          semanticFormatterCallback: (next) =>
              '${next.toStringAsFixed(label == '位置' ? 0 : 1)}$suffix',
          onChanged: !enabled
              ? null
              : (next) {
                  setState(() {
                    _dragging = true;
                    _draggingAssStyle = assStyle;
                    _style = change(next);
                  });
                  _previewTimer ??= Timer(
                    const Duration(milliseconds: 120),
                    () {
                      _previewTimer = null;
                      if (mounted && _dragging) {
                        unawaited(widget.session.previewSubtitleStyle(_style));
                      }
                    },
                  );
                },
          onChangeEnd: !enabled
              ? null
              : (next) {
                  _previewTimer?.cancel();
                  _previewTimer = null;
                  _dragging = false;
                  _commit(change(next));
                },
        ),
      ),
    ],
  );

  static const _colors = <String, String>{
    '#FFFFFFFF': '白色',
    '#FF000000': '黑色',
    '#FFFFFF00': '黄色',
    '#FF00FFFF': '青色',
    '#FFFF0000': '红色',
    '#FF00FF00': '绿色',
  };

  Widget _color(
    String title,
    String value,
    ValueChanged<String> update, {
    bool enabled = true,
  }) => Row(
    children: [
      Expanded(child: Text(title)),
      DropdownButton<String>(
        value: _colors.containsKey(value) ? value : '#FFFFFFFF',
        items: [
          for (final color in _colors.entries)
            DropdownMenuItem(
              value: color.key,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: Color(
                        int.parse(color.key.substring(1), radix: 16),
                      ),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(color.value),
                ],
              ),
            ),
        ],
        onChanged: !enabled
            ? null
            : (next) {
                if (next != null) update(next);
              },
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (widget.showTitle) ...[
        const Text('字幕设置', style: TextStyle(fontSize: 18)),
        const SizedBox(height: 6),
      ],
      const Text(
        '文字字幕可调整；图片字幕及画面烧录字幕不支持样式调整。ASS 字幕默认保留原样，部分效果可能无法调整；改变大小、位置或强制覆盖可能影响排版和特效。',
      ),
      if (widget.session.subtitleStyleIssue.isNotEmpty)
        Text(
          widget.session.subtitleStyleIssue,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      _slider(
        '延迟',
        _style.delay,
        -10,
        10,
        200,
        ' 秒',
        (v) => _style.copyWith(delay: v),
      ),
      _slider(
        '大小',
        _style.scale,
        .5,
        2,
        30,
        '×',
        (v) => _style.copyWith(scale: v),
      ),
      _slider(
        '位置',
        _style.position,
        0,
        100,
        100,
        '%',
        (v) => _style.copyWith(position: v),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('覆盖 ASS 原有样式'),
        subtitle: const Text('关闭后恢复字幕文件自带的排版和样式。'),
        value: _style.overrideAss,
        onChanged: (v) => _commit(_style.copyWith(overrideAss: v)),
      ),
      if (_assStyleLocked)
        Semantics(
          liveRegion: true,
          child: const Text('当前字幕为 ASS/SSA；开启覆盖 ASS 原有样式后，粗斜体、颜色和描边设置才可调整。'),
        )
      else if (widget.session.currentSubtitleFormat ==
          SubtitleTrackFormat.unknown)
        const Text('当前字幕格式未知，可在字幕菜单手动选择具体轨道后识别；如果是 ASS/SSA，部分样式需开启覆盖后才会生效。')
      else if (widget.session.currentSubtitleFormat ==
          SubtitleTrackFormat.bitmap)
        const Text('当前为图片字幕，无法调整文字样式。'),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('粗体'),
        value: _style.bold,
        onChanged: _assStyleLocked
            ? null
            : (v) => _commit(_style.copyWith(bold: v)),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('斜体'),
        value: _style.italic,
        onChanged: _assStyleLocked
            ? null
            : (v) => _commit(_style.copyWith(italic: v)),
      ),
      _color(
        '文字颜色',
        _style.color,
        (v) => _commit(_style.copyWith(color: v)),
        enabled: !_assStyleLocked,
      ),
      _color(
        '描边颜色',
        _style.outlineColor,
        (v) => _commit(_style.copyWith(outlineColor: v)),
        enabled: !_assStyleLocked,
      ),
      _slider(
        '描边粗细',
        _style.outlineSize,
        0,
        8,
        16,
        '',
        (v) => _style.copyWith(outlineSize: v),
        enabled: !_assStyleLocked,
        assStyle: true,
      ),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          onPressed: () => _commit(const SubtitleStyle()),
          child: const Text('恢复默认'),
        ),
      ),
    ],
  );
}
