import 'package:html/parser.dart' as html;

typedef Json = Map<String, dynamic>;
Json object(dynamic value) => value is Json ? value : <String, dynamic>{};
int number(dynamic value, [int fallback = 0]) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? fallback;
String string(dynamic value) => value is String ? value : '';
List<Json> objects(dynamic value) =>
    value is List ? value.whereType<Json>().toList() : [];
String plainText(dynamic value) {
  final document = html.parseFragment(string(value));
  for (final element in document.querySelectorAll(
    'script,style,iframe,object',
  )) {
    element.remove();
  }
  return document.text ?? '';
}

class VideoItem {
  const VideoItem({
    required this.id,
    required this.title,
    required this.cover,
    required this.episodes,
    required this.tags,
    this.score = 0,
  });
  factory VideoItem.fromJson(Json value) => VideoItem(
    id: number(value['id'] ?? value['video_id']),
    title: plainText(value['title']),
    cover: string(value['cover']),
    episodes: number(value['episode_count']),
    tags: value['tags'] is List
        ? (value['tags'] as List).whereType<String>().toList()
        : [],
    score: double.tryParse('${value['score']}') ?? 0,
  );
  final int id, episodes;
  final String title, cover;
  final List<String> tags;
  final double score;
  Json toJson() => {
    'id': id,
    'title': title,
    'cover': cover,
    'episode_count': episodes,
    'tags': tags,
    'score': score,
  };
}

class Episode {
  const Episode(this.number, this.title);
  factory Episode.fromJson(Json value) => Episode(
    int.tryParse('${value['ep_num']}') ?? 0,
    plainText(value['title']),
  );
  final int number;
  final String title;
}

class VideoDetail {
  VideoDetail.fromJson(Json value)
    : item = VideoItem.fromJson(value),
      description = plainText(value['description']),
      episodes = objects(value['episodes'])
          .map(Episode.fromJson)
          .where((e) => e.number > 0)
          .toList(),
      author = object(value['author']),
      liked = object(value['interaction'])['liked'] == true,
      collected = object(value['interaction'])['collected'] == true;
  final VideoItem item;
  final String description;
  final List<Episode> episodes;
  late final Map<int, int> episodePositions = {
    for (var i = 0; i < episodes.length; i++) episodes[i].number: i,
  };
  final Json author;
  final bool liked, collected;
}

class PageResult<T> {
  const PageResult(this.items, this.hasMore);
  final List<T> items;
  final bool hasMore;
}

class WatchEntry {
  const WatchEntry(this.video, this.episode, this.positionMs);
  factory WatchEntry.fromJson(Json json) => WatchEntry(
    VideoItem.fromJson(object(json['video'])),
    number(json['episode'], 1),
    number(json['position']),
  );
  final VideoItem video;
  final int episode, positionMs;
  Json toJson() => {
    'video': video.toJson(),
    'episode': episode,
    'position': positionMs,
  };
}
