import 'package:flutter_test/flutter_test.dart';
import 'package:hghub/core/app_model.dart';
import 'package:hghub/data/models.dart';
import 'package:hghub/data/repository.dart';
import 'package:hghub/features/detail.dart';
import 'package:hghub/ui/app_theme.dart';
import 'package:hghub/ui/design.dart';

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
