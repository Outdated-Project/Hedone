import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hghub/core/async_lru.dart';
import 'package:hghub/core/paged_controller.dart';
import 'package:hghub/data/models.dart';
import 'package:hghub/ui/poster.dart';
import 'package:hghub/core/playback_session.dart';
import 'package:hghub/data/repository.dart';

import 'layout_test.dart' show FixtureTransport;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'closing an unused playback session does not create a native decoder',
    () async {
      final session = PlaybackSession(Repository(FixtureTransport()));
      await session.close();
      await session.close();
    },
  );
  test('coalesces pending loads and renews expired values', () async {
    var now = DateTime(2026);
    var calls = 0;
    final cache = AsyncLru<int, int>(
      capacity: 2,
      ttl: const Duration(seconds: 5),
      now: () => now,
    );
    final pending = Completer<int>();
    Future<int> load() {
      calls++;
      return pending.future;
    }

    final first = cache.obtain(1, load);
    final second = cache.obtain(1, load);
    expect(identical(first, second), true);
    pending.complete(7);
    expect(await first, 7);
    expect(calls, 1);
    now = now.add(const Duration(seconds: 6));
    expect(await cache.obtain(1, () async => 8), 8);
  });
  test(
    'recent reads survive eviction and old failures cannot erase new loads',
    () async {
      final cache = AsyncLru<int, int>(
        capacity: 2,
        ttl: const Duration(minutes: 1),
      );
      await cache.obtain(1, () async => 1);
      await cache.obtain(2, () async => 2);
      await cache.obtain(1, () async => throw StateError('unexpected reload'));
      await cache.obtain(3, () async => 3);
      expect(await cache.obtain(1, () async => -1), 1);
      expect(await cache.obtain(2, () async => 22), 22);
      final old = Completer<int>();
      final failed = cache.obtain(4, () => old.future);
      final assertion = expectLater(failed, throwsStateError);
      cache.clear();
      await cache.obtain(4, () async => 44);
      old.completeError(StateError('obsolete'));
      await assertion;
      expect(await cache.obtain(4, () async => -1), 44);
    },
  );
  test(
    'overlapping pages are deduplicated without consuming retry pages',
    () async {
      final controller = PagedController<int>(
        (page) async => switch (page) {
          1 => const PageResult([1, 2], true),
          2 => const PageResult([2, 3], true),
          _ => const PageResult([], true),
        },
        identity: (v) => v,
      );
      await controller.next();
      await controller.next();
      await controller.next();
      expect(controller.items, [1, 2, 3]);
      expect(controller.hasMore, false);
      await controller.refresh();
      expect(controller.items, [1, 2]);
      controller.dispose();
    },
  );
  test(
    'poster sizes are quantized and bounded for tall or unbounded layouts',
    () {
      expect(decodeExtent(120, 2, 768), 256);
      expect(decodeExtent(121, 2, 768), 256);
      expect(decodeExtent(9000, 3, 1280), 1280);
      expect(decodeExtent(double.infinity, 3, 768), 768);
    },
  );
}
