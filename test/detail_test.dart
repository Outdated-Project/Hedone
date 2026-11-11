import 'package:flutter_test/flutter_test.dart';
import 'package:hedone/core/app_model.dart';
import 'package:hedone/data/models.dart';
import 'package:hedone/data/repository.dart';
import 'package:hedone/features/detail.dart';
import 'package:hedone/features/browse.dart';
import 'package:hedone/ui/app_theme.dart';
import 'package:hedone/ui/design.dart';

import 'layout_test.dart' show FixtureTransport, MemoryPreferences;

class DetailFixture extends FixtureTransport {
  @override
  Future<dynamic> request(Map<String, dynamic> payload) async {
    if (payload['op'] == 'video') {
      return {
        'id': 1,
        'title': '详情布局回归测试',
        'description': '仅用于测试详情与评论在未启动播放器时的行为。',
        'episodes': List.generate(500, (i) => {'ep_num': i + 1}),
      };
    }
    return {
      'items': [],
      'pagination': {'pages': 1},
    };
  }
}

void main() {
  testWidgets(
    'repeated card taps open one route and interrupted entry does not start playback',
    (tester) async {
      final model = AppModel(Repository(DetailFixture()), MemoryPreferences());
      final observer = _RouteCounter();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          navigatorObservers: [observer],
          builder: (context, child) => AppTheme.scope(context, child!),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 240,
                height: 360,
                child: VideoTile(
                  model: model,
                  item: const VideoItem(
                    id: 1,
                    title: '共享封面测试',
                    cover: '',
                    episodes: 12,
                    tags: [],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final open = tester
          .widget<M3ECard>(
            find.descendant(
              of: find.byType(VideoTile),
              matching: find.byType(M3ECard),
            ),
          )
          .onPressed!;
      // Invoke two already-dispatched interactions; a pushed route correctly
      // blocks later hit tests on the originating card.
      open();
      open();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(observer.pushes, 2); // Home plus one detail.
      Navigator.of(tester.element(find.byType(DetailScreen))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(DetailScreen), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  testWidgets('detail and comments work without allocating a decoder', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 960);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final model = AppModel(Repository(DetailFixture()), MemoryPreferences());
    // MediaKit is intentionally not initialized. Browsing must not need it.
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        builder: (context, child) => AppTheme.scope(context, child!),
        home: DetailScreen(
          model: model,
          item: const VideoItem(
            id: 1,
            title: '详情布局回归测试',
            cover: '',
            episodes: 500,
            tags: [],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final picker = find.text('第 1 集 · 共 500 集');
    await tester.ensureVisible(picker);
    await tester.tap(picker);
    await tester.pumpAndSettle();
    expect(find.text('第 500 集'), findsNothing);
    expect(tester.takeException(), isNull);
    Navigator.of(tester.element(find.text('第 2 集'))).pop();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('评论'));
    await tester.tap(find.text('评论'));
    await tester.pumpAndSettle();
    expect(find.text('还没有评论'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
  });
}

class _RouteCounter extends NavigatorObserver {
  int pushes = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes++;
  }
}
