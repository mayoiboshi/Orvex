/// User-selected text subtitle adjustments. The native renderer retains ASS
/// styling unless overrideAss is explicitly enabled.
class SubtitleStyle {
  const SubtitleStyle({
    this.delay = 0,
    this.scale = 1,
    this.position = 100,
    this.bold = false,
    this.italic = false,
    this.color = '#FFFFFFFF',
    this.outlineColor = '#FF000000',
    this.outlineSize = 3,
    this.overrideAss = false,
  });

  final double delay, scale, position, outlineSize;
  final bool bold, italic, overrideAss;
  final String color, outlineColor;

  SubtitleStyle copyWith({
    double? delay,
    double? scale,
    double? position,
    bool? bold,
    bool? italic,
    String? color,
    String? outlineColor,
    double? outlineSize,
    bool? overrideAss,
  }) => SubtitleStyle(
    delay: delay ?? this.delay,
    scale: scale ?? this.scale,
    position: position ?? this.position,
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    color: color ?? this.color,
    outlineColor: outlineColor ?? this.outlineColor,
    outlineSize: outlineSize ?? this.outlineSize,
    overrideAss: overrideAss ?? this.overrideAss,
  );

  Map<String, Object> toJson() => {
    'delay': delay,
    'scale': scale,
    'position': position,
    'bold': bold,
    'italic': italic,
    'color': color,
    'outlineColor': outlineColor,
    'outlineSize': outlineSize,
    'overrideAss': overrideAss,
  };

  factory SubtitleStyle.fromJson(Map<String, dynamic> json) {
    double number(String key, double fallback, double min, double max) {
      final v = json[key];
      return v is num && v.isFinite && v >= min && v <= max
          ? v.toDouble()
          : fallback;
    }

    String color(String key, String fallback) {
      final v = json[key];
      return v is String && RegExp(r'^#[0-9a-fA-F]{8}$').hasMatch(v)
          ? v.toUpperCase()
          : fallback;
    }

    return SubtitleStyle(
      delay: number('delay', 0, -10, 10),
      scale: number('scale', 1, .5, 2),
      position: number('position', 100, 0, 100),
      outlineSize: number('outlineSize', 3, 0, 8),
      bold: json['bold'] == true,
      italic: json['italic'] == true,
      overrideAss: json['overrideAss'] == true,
      color: color('color', '#FFFFFFFF'),
      outlineColor: color('outlineColor', '#FF000000'),
    );
  }
}

abstract interface class SubtitleStyleStore {
  Future<SubtitleStyle> read();
  Future<void> write(SubtitleStyle value);
}
