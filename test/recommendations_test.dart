import 'dart:math';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hedone/core/app_model.dart';
import 'package:hedone/core/recommendations.dart';
import 'package:hedone/data/models.dart';
import 'package:hedone/data/repository.dart';

import 'layout_test.dart' show MemoryPreferences, FixtureTransport;

VideoItem video(int id, String title, [List<String> tags = const []]) =>
    VideoItem(id: id, title: title, cover: '', episodes: 10, tags: tags);

void main() {
  final now = DateTime.utc(2026, 11, 11);
  test('cold start shuffles real candidates and deduplicates IDs', () {
    final profile = RecommendationProfile();
    final candidates = List.generate(30, (i) => video(i + 1, '故事 $i'));
    final first = profile.rank(
      [...candidates, candidates.first],
      random: Random(1),
      now: now,
    );
    final second = profile.rank(candidates, random: Random(2), now: now);
    expect(first.map((e) => e.id).toSet(), candidates.map((e) => e.id).toSet());
    expect(first.length, 30);
    expect(
      first.map((e) => e.id).toList(),
      isNot(second.map((e) => e.id).toList()),
    );
  });
  test(
    'an obsolete refresh cannot contaminate the current dedup set',
    () async {
      final transport = _RaceTransport();
      final feed = RecommendationFeed(
        Repository(transport),
        RecommendationProfile(),
      );
      final old = feed.load(1);
      final current = feed.load(1);
      transport.newer.complete({
        'items': [video(2, 'new').toJson()],
        'pagination': {'pages': 3},
      });
      expect((await current).items.single.id, 2);
      transport.older.complete({
        'items': [video(1, 'old').toJson()],
      });
      expect((await old).items, isEmpty);
      expect((await feed.load(2)).items.single.id, 1);
    },
  );
  test('profile stores bounded text without cover addresses', () {
    final profile = RecommendationProfile();
    profile.watch(
      VideoItem(
        id: 1,
        title: 'x' * 1000,
        cover: 'https://private.example/signed',
        episodes: 1,
        tags: List.filled(30, 'y' * 200),
      ),
      60000,
      now: now,
    );
    final saved = object(objects(profile.toJson()['views']).single['video']);
    expect(saved.containsKey('cover'), isFalse);
    expect(string(saved['title']).length, 256);
    expect((saved['tags'] as List).length, 16);
  });
  test(
    'watch affinity outweighs unrelated search and short accidental views',
    () {
      final profile = RecommendationProfile();
      profile.watch(video(1, '星际探索', ['科幻']), 120000, now: now);
      profile.watch(video(2, '甜蜜恋爱', ['爱情']), 1000, now: now);
      for (var i = 0; i < 100; i++) {
        profile.search('爱情', now: now);
      }
      final ranked = profile.rank(
        [
          video(3, '星际探索', ['科幻']),
          video(4, '甜蜜恋爱', ['爱情']),
          video(5, '厨房美食'),
        ],
        random: Random(7),
        now: now,
      );
      expect(ranked.first.id, 3);
      expect(objects(profile.toJson()['searches']), hasLength(1));
      expect(objects(profile.toJson()['views']), hasLength(1));
    },
  );
  test(
    'recent interests replace old interests and seen items are penalized',
    () {
      final profile = RecommendationProfile();
      profile.watch(
        video(1, '古装权谋'),
        120000,
        now: now.subtract(const Duration(days: 80)),
      );
      profile.watch(video(2, '星际探索'), 120000, now: now);
      final ranked = profile.rank(
        [video(1, '古装权谋'), video(2, '星际探索'), video(3, '星际探索')],
        random: Random(1),
        now: now,
      );
      expect(ranked.first.id, 3);
    },
  );
  test('profile bounds survive serialization and corrupt input', () {
    final profile = RecommendationProfile();
    for (var i = 1; i <= 300; i++) {
      profile.watch(video(i, '故事 $i'), 60000, now: now);
      profile.search('主题 $i', now: now);
    }
    final copy = RecommendationProfile()..restore(profile.toJson(), now: now);
    expect(objects(copy.toJson()['views']), hasLength(100));
    expect(objects(copy.toJson()['searches']), hasLength(40));
    copy.restore({
      'views': [
        {'at': -1, 'video': video(1, 'bad').toJson()},
      ],
      'searches': [
        {
          'q': 'future',
          'at': now.add(const Duration(days: 1)).millisecondsSinceEpoch,
        },
      ],
    }, now: now);
    expect(copy.isEmpty, isTrue);
  });
  test(
    'profile persists by data source and clearing history removes signals',
    () async {
      final preferences = MemoryPreferences();
      final model = AppModel(Repository(FixtureTransport()), preferences);
      await model.initialize();
      await model.rememberSearch('星际');
      await model.remember(WatchEntry(video(1, '星际探索'), 1, 30000));
      final copy = AppModel(Repository(FixtureTransport()), preferences);
      await copy.initialize();
      expect(copy.recommendations.isEmpty, isFalse);
      await copy.clearHistory();
      expect(copy.recommendations.isEmpty, isTrue);
      model.dispose();
      copy.dispose();
    },
  );
  test('personal feed deduplicates pages and optional recall failures are isolated', () async {
    final profile = RecommendationProfile()..search('星际');
    final feed = RecommendationFeed(Repository(_RecallFailure()), profile);
    final first = await feed.load(1);
    expect(first.items, hasLength(4));
    expect((await feed.load(2)).items, isEmpty);
    expect((await feed.load(1)).items, hasLength(4));
  });
}

class _RaceTransport extends FixtureTransport {
  final older = Completer<dynamic>(), newer = Completer<dynamic>();
  var calls = 0;
  @override
  Future<dynamic> request(Json payload) {
    calls++;
    if (calls == 1) return older.future;
    if (calls == 2) return newer.future;
    return Future.value({
      'items': [video(1, 'old').toJson()],
    });
  }
}

class _RecallFailure extends FixtureTransport {
  @override
  Future<dynamic> request(Json payload) {
    if (payload['op'] == 'search') return Future.error(StateError('offline'));
    return super.request(payload);
  }
}
