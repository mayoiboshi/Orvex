class AnimeEpisode {
  const AnimeEpisode({
    required this.id,
    required this.sort,
    this.ep,
    this.name = '',
    this.chineseName = '',
    this.description = '',
    this.airdate = '',
    this.duration = '',
  });

  final int id;
  final num sort;
  final num? ep;
  final String name, chineseName, description, airdate, duration;

  String get title => chineseName.isNotEmpty ? chineseName : name;
  String get label => '第 ${sort % 1 == 0 ? sort.toInt() : sort} 话';
  bool matches(int number) => sort == number || ep == number;

  factory AnimeEpisode.fromJson(Map<String, dynamic> json) => AnimeEpisode(
    id: json['id'] as int,
    sort: json['sort'] as num,
    ep: json['ep'] as num?,
    name: (json['name'] as String? ?? '').trim(),
    chineseName: (json['name_cn'] as String? ?? '').trim(),
    description: (json['desc'] as String? ?? '').trim(),
    airdate: (json['airdate'] as String? ?? '').trim(),
    duration: (json['duration'] as String? ?? '').trim(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'sort': sort,
    'ep': ep,
    'name': name,
    'name_cn': chineseName,
    'desc': description,
    'airdate': airdate,
    'duration': duration,
  };
}
