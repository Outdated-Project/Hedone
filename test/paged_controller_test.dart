import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hghub/core/paged_controller.dart';
import 'package:hghub/data/models.dart';

void main() {
  test(
    'refresh discards an older response and preserves the current request',
    () async {
      final pending = <Completer<PageResult<int>>>[];
      final controller = PagedController<int>((page) {
        final c = Completer<PageResult<int>>();
        pending.add(c);
        return c.future;
      });
      final first = controller.next();
      final refresh = controller.refresh();
      pending[0].complete(const PageResult([1], true));
      await first;
      expect(controller.items, isEmpty);
      expect(controller.loading, isTrue);
      pending[1].complete(const PageResult([2], false));
      await refresh;
      expect(controller.items, [2]);
      expect(controller.hasMore, isFalse);
      controller.dispose();
    },
  );
  test(
    'failed page is retried at the same page number without losing prior data',
    () async {
      final pages = <int>[];
      bool fail = true;
      final controller = PagedController<int>((page) async {
        pages.add(page);
        if (page == 2 && fail) {
          fail = false;
          throw Exception('offline');
        }
        return PageResult([page], page < 2);
      });
      await controller.next();
      await controller.next();
      expect(controller.items, [1]);
      expect(controller.error, isNotNull);
      await controller.next();
      expect(pages, [1, 2, 2]);
      expect(controller.items, [1, 2]);
      controller.dispose();
    },
  );
  test('disposed requests cannot notify listeners', () async {
    final pending = Completer<PageResult<int>>();
    final controller = PagedController<int>((_) => pending.future);
    final loading = controller.next();
    controller.dispose();
    pending.complete(const PageResult([1], false));
    await loading;
  });
  test('upstream rich text becomes text, never executable markup', () {
    expect(
      plainText('<script>bad()</script><p>A &amp; B</p><iframe>bad</iframe>'),
      'A & B',
    );
    expect(Episode.fromJson({'ep_num': '2', 'title': '第二集'}).number, 2);
    expect(
      VideoItem.fromJson({'video_id': 4, 'title': '标题', 'score': '8.5'}).id,
      4,
    );
  });
}
