import 'dart:math';

import '../data/models.dart';
import '../data/repository.dart';

/// A bounded, local profile. Repeated saves update an event instead of voting
/// again. Source weights are normalized independently so search spam cannot
/// outweigh watching. No account identifier or media URL is stored here.
class RecommendationProfile {
  final Map<int, ({VideoItem video, int at, double engagement})> _views = {};
  final Map<String, int> _searches = {};
  static const maxViews = 100, maxSearches = 40;

  void watch(VideoItem video, int positionMs, {DateTime? now}) {
    if (video.id <= 0 || positionMs < 5000) return;
    _views.remove(video.id);
    _views[video.id] = (
      video: VideoItem(
        id: video.id,
        title: String.fromCharCodes(video.title.runes.take(256)),
        cover: '',
        episodes: 0,
        tags: video.tags
            .take(16)
            .map((tag) => String.fromCharCodes(tag.runes.take(48)))
            .toList(),
      ),
      at: (now ?? DateTime.now()).millisecondsSinceEpoch,
      engagement: (positionMs / 120000).clamp(.15, 1.0),
    );
    while (_views.length > maxViews) {
      _views.remove(_views.keys.first);
    }
  }

  void search(String query, {DateTime? now}) {
    final text = query.trim().toLowerCase();
    if (text.isEmpty || text.length > 120) return;
    _searches.remove(text);
    _searches[text] = (now ?? DateTime.now()).millisecondsSinceEpoch;
    while (_searches.length > maxSearches) {
      _searches.remove(_searches.keys.first);
    }
  }

  void clear() {
    _views.clear();
    _searches.clear();
  }

  bool get isEmpty => _views.isEmpty && _searches.isEmpty;

  Json toJson() => {
    'views': [
      for (final entry in _views.values)
        {
          'video': {
            'id': entry.video.id,
            'title': entry.video.title,
            'tags': entry.video.tags,
          },
          'at': entry.at,
          'engagement': entry.engagement,
        },
    ],
    'searches': [
      for (final entry in _searches.entries)
        {'q': entry.key, 'at': entry.value},
    ],
  };

  void restore(Json value, {DateTime? now}) {
    clear();
    final time = (now ?? DateTime.now()).millisecondsSinceEpoch;
    bool valid(int at) =>
        at > 0 &&
        at <= time &&
        time - at < const Duration(days: 90).inMilliseconds;
    for (final row in objects(value['views']).take(maxViews)) {
      final video = VideoItem.fromJson(object(row['video']));
      final at = number(row['at']);
      final engagement = row['engagement'];
      if (video.id > 0 &&
          valid(at) &&
          engagement is num &&
          engagement.isFinite) {
        _views[video.id] = (
          video: video,
          at: at,
          engagement: engagement.toDouble().clamp(.15, 1),
        );
      }
    }
    for (final row in objects(value['searches']).take(maxSearches)) {
      final at = number(row['at']);
      final query = string(row['q']).trim();
      if (valid(at) && query.isNotEmpty && query.length <= 120) {
        _searches[query] = at;
      }
    }
  }

  static Set<String> tokens(String value) {
    final result = <String>{};
    final text = value.substring(0, min(value.length, 512)).toLowerCase();
    for (final match in RegExp(
      r'[a-z0-9]{2,}|[\u3400-\u9fff]+',
    ).allMatches(text)) {
      final word = match[0]!;
      if (RegExp(r'^[a-z0-9]').hasMatch(word) || word.length < 3) {
        result.add(word);
      } else {
        // Chinese bigrams match phrases without shipping a segmentation model.
        for (var i = 0; i < word.length - 1 && i < 120; i++) {
          result.add(word.substring(i, i + 2));
        }
      }
      if (result.length >= 128) break;
    }
    return result;
  }

  static Set<String> features(VideoItem video) => {
    ...tokens(video.title),
    for (final tag in video.tags.take(16)) ...tokens(tag),
  };

  Map<String, double> _interests(DateTime now) {
    final watch = <String, double>{}, search = <String, double>{};
    void add(
      Map<String, double> map,
      Set<String> terms,
      int at,
      double weight,
      int halfLife,
    ) {
      final days =
          max(0, now.millisecondsSinceEpoch - at) / Duration.millisecondsPerDay;
      final value =
          weight * pow(.5, days / halfLife) / max(1, sqrt(terms.length));
      for (final term in terms) {
        map.update(term, (v) => v + value, ifAbsent: () => value);
      }
    }

    for (final view in _views.values) {
      add(watch, features(view.video), view.at, view.engagement, 14);
    }
    for (final query in _searches.entries) {
      add(search, tokens(query.key), query.value, 1, 7);
    }
    final merged = <String, double>{};
    void merge(Map<String, double> map, double share) {
      final norm = sqrt(map.values.fold(0.0, (sum, v) => sum + v * v));
      if (norm == 0) return;
      for (final e in map.entries) {
        merged.update(
          e.key,
          (v) => v + share * e.value / norm,
          ifAbsent: () => share * e.value / norm,
        );
      }
    }

    merge(watch, search.isEmpty ? 1 : .65);
    merge(search, watch.isEmpty ? 1 : .35);
    return merged;
  }

  String? retrievalTopic(DateTime now) {
    final recent = _searches.entries
        .where(
          (e) =>
              now.millisecondsSinceEpoch - e.value <
              const Duration(days: 7).inMilliseconds,
        )
        .toList();
    if (recent.isNotEmpty) return recent.last.key;
    for (final view in _views.values.toList().reversed) {
      if (now.millisecondsSinceEpoch - view.at >
          const Duration(days: 14).inMilliseconds) {
        continue;
      }
      for (final tag in view.video.tags) {
        if (tag.trim().length >= 2 && tag.length <= 24) return tag.trim();
      }
    }
    return null;
  }

  List<VideoItem> rank(
    Iterable<VideoItem> candidates, {
    required Random random,
    DateTime? now,
  }) {
    final items = {
      for (final v in candidates)
        if (v.id > 0) v.id: v,
    }.values.take(96).toList();
    items.shuffle(random);
    if (isEmpty) return items;
    final time = now ?? DateTime.now();
    final interests = _interests(time);
    final terms = {for (final v in items) v.id: features(v)};
    final scores = <int, double>{};
    for (final v in items) {
      final f = terms[v.id]!;
      final affinity =
          f.fold(0.0, (sum, t) => sum + (interests[t] ?? 0)) /
          max(1, sqrt(f.length));
      final seen = _views[v.id];
      final penalty = seen == null
          ? 0.0
          : .4 *
                pow(
                  .5,
                  max(0, time.millisecondsSinceEpoch - seen.at) /
                      const Duration(days: 7).inMilliseconds,
                );
      scores[v.id] =
          .8 * affinity +
          .05 * (v.score.isFinite ? v.score.clamp(0, 10) / 10 : 0) +
          .15 * random.nextDouble() -
          penalty;
    }
    final ranked = <VideoItem>[];
    while (items.isNotEmpty) {
      // Every fifth slot explores an unseen candidate; the rest use a bounded
      // diversity penalty against the previous four selections.
      var best = 0;
      var bestScore = double.negativeInfinity;
      final explore = ranked.length % 5 == 4;
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        var score = explore
            ? random.nextDouble() - (_views.containsKey(item.id) ? 1 : 0)
            : scores[item.id]!;
        if (!explore) {
          for (final previous in ranked.skip(max(0, ranked.length - 4))) {
            final a = terms[item.id]!, b = terms[previous.id]!;
            final union = a.union(b).length;
            if (union > 0) score -= .12 * a.intersection(b).length / union;
          }
        }
        if (score > bestScore) {
          bestScore = score;
          best = i;
        }
      }
      ranked.add(items.removeAt(best));
    }
    return ranked;
  }
}

/// Fetching is separate from scoring; a failed optional recall never discards
/// a working feed. Generation checks keep stale refreshes out of dedup state.
class RecommendationFeed {
  RecommendationFeed(this.repository, this.profile);
  final Repository repository;
  final RecommendationProfile profile;
  final Set<int> _seen = {};
  Random _random = Random();
  int _generation = 0;

  Future<PageResult<VideoItem>> load(int page) async {
    if (page == 1) {
      _generation++;
      _seen.clear();
      _random = Random();
    }
    final generation = _generation;
    final topic = page == 1 ? profile.retrievalTopic(DateTime.now()) : null;
    final recall = topic == null
        ? Future.value(const PageResult<VideoItem>([], false))
        : repository
              .videos('search', 1, fields: {'q': topic})
              .catchError((Object _) => const PageResult<VideoItem>([], false));
    final results = await Future.wait([
      repository.videos('feed', page),
      recall,
    ]);
    if (generation != _generation) return const PageResult([], false);
    final ranked = profile.rank(
      [
        ...results[0].items,
        ...results[1].items,
      ].where((v) => !_seen.contains(v.id)),
      random: _random,
    );
    _seen.addAll(ranked.map((v) => v.id));
    return PageResult(ranked, results[0].hasMore && _seen.length < 1200);
  }
}
