import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hedone/app.dart';
import 'package:hedone/core/app_model.dart';
import 'package:hedone/data/repository.dart';
import 'package:hedone/features/browse.dart';
import 'package:hedone/features/posts.dart';
import 'package:hedone/features/account.dart';
import 'package:hedone/features/settings.dart';
import 'package:hedone/ui/aurora_scene.dart';
import 'package:hedone/ui/design.dart';
import 'package:hedone/ui/responsive_image.dart';

import 'layout_test.dart' show FixtureTransport, MemoryPreferences;

void main() {
  testWidgets('crossfade keeps the background opaque and stacking stable', (
    tester,
  ) async {
    final clock = AnimationController(
      vsync: tester,
      duration: AuroraMotion.standard,
    );
    final transition = AuroraSceneTransition.settled(0, 3).retarget(2, 1);
    clock.value = .28;
    final before = _PaintProbe();
    AuroraSceneDelegate(
      animation: clock,
      transition: transition,
    ).paintChildren(before);
    expect(before.layers.first.$2, 1);
    expect(before.layers.where((layer) => layer.$2 < 1).length, 1);
    final retargeted = transition.retarget(0, clock.value);
    clock.value = 0;
    final after = _PaintProbe();
    AuroraSceneDelegate(
      animation: clock,
      transition: retargeted,
    ).paintChildren(after);
    expect(after.layers, before.layers);
    // Reconstruct source-over contributions for opaque, solid-color scenes.
    final contributions = List.filled(3, 0.0);
    for (final (index, opacity) in after.layers) {
      for (var i = 0; i < contributions.length; i++) {
        contributions[i] *= 1 - opacity;
      }
      contributions[index] += opacity;
    }
    expect(contributions.reduce((a, b) => a + b), closeTo(1, 1e-9));
    for (var i = 0; i < 3; i++) {
      expect(contributions[i], closeTo(retargeted.sample(i, 0).opacity, 1e-9));
    }
    clock.dispose();
  });

  testWidgets('reversing navigation preserves the painted pose and momentum', (
    tester,
  ) async {
    final clock = AnimationController(
      vsync: tester,
      duration: AuroraMotion.standard,
    );
    var transition = AuroraSceneTransition.settled(0, 3).retarget(2, 1);
    final keys = List.generate(3, (_) => GlobalKey());
    Widget scene() => Directionality(
      textDirection: TextDirection.ltr,
      child: Flow(
        delegate: AuroraSceneDelegate(animation: clock, transition: transition),
        children: List.generate(
          3,
          (i) => ColoredBox(key: keys[i], color: const Color(0xFF123456)),
        ),
      ),
    );
    await tester.pumpWidget(scene());
    clock.value = .22;
    await tester.pump();
    final boxes = keys
        .map((key) => key.currentContext!.findRenderObject()! as RenderBox)
        .toList();
    final origins = boxes.map((box) => box.localToGlobal(Offset.zero)).toList();
    final corners = boxes
        .map((box) => box.localToGlobal(box.size.bottomRight(Offset.zero)))
        .toList();
    final before = [
      transition.sample(0, clock.value),
      transition.sample(2, clock.value),
    ];
    transition = transition.retarget(0, clock.value);
    clock.value = 0;
    await tester.pumpWidget(scene());
    for (final i in [0, 2]) {
      expect(boxes[i].localToGlobal(Offset.zero), origins[i]);
      expect(
        boxes[i].localToGlobal(boxes[i].size.bottomRight(Offset.zero)),
        corners[i],
      );
      final pose = transition.sample(i, 0);
      final prior = before[i == 0 ? 0 : 1];
      expect(pose.opacity, prior.opacity);
      expect(pose.velocity, prior.velocity);
      expect(pose.scaleVelocity, prior.scaleVelocity);
      // Check the actual next-frame derivative, not only stored fields.
      final next = transition.sample(i, .000001);
      expect((next.dx - pose.dx) / .0000006, closeTo(prior.velocity, .01));
    }
    clock.forward();
    await tester.pumpAndSettle();
    expect(clock.isCompleted, true);
    expect(transition.sample(0, 1).scale, 1);
    expect(transition.sample(0, 1).dx, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    clock.dispose();
  });

  test('cover decoding preserves crop sharpness, aspect and pixel budget', () {
    final portrait = coverDecodeSize(
      2000,
      3000,
      900,
      400,
      3 * 1024 * 1024,
      BoxFit.cover,
    );
    expect(portrait.width, 900);
    expect(portrait.height, 1350);
    final large = coverDecodeSize(
      8000,
      12000,
      4000,
      6000,
      3 * 1024 * 1024,
      BoxFit.cover,
    );
    expect(large.width! * large.height!, lessThanOrEqualTo(3 * 1024 * 1024));
    expect(large.width! / large.height!, closeTo(2 / 3, .001));
    final small = coverDecodeSize(
      100,
      150,
      900,
      900,
      1024 * 1024,
      BoxFit.contain,
    );
    expect(small.width, 100);
    expect(small.height, 150);
  });
  for (final hz in [60, 90, 120, 165]) {
    testWidgets('navigation ticks at $hz Hz do not rebuild or lay out scenes', (
      tester,
    ) async {
      final clock = AnimationController(
        vsync: tester,
        duration: AuroraMotion.standard,
      );
      var builds = 0, layouts = 0;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Flow(
            delegate: AuroraSceneDelegate(
              animation: clock,
              transition: AuroraSceneTransition.settled(0, 2).retarget(1, 1),
            ),
            children: List.generate(
              2,
              (_) => Builder(
                builder: (_) {
                  builds++;
                  return _LayoutProbe(
                    onLayout: () => layouts++,
                    child: const ColoredBox(color: Color(0xFF123456)),
                  );
                },
              ),
            ),
          ),
        ),
      );
      final initialBuilds = builds, initialLayouts = layouts;
      clock.forward();
      final interval = Duration(microseconds: (1000000 / hz).round());
      for (var i = 0; i < (hz * .4).ceil(); i++) {
        await tester.pump(interval);
      }
      expect(builds, initialBuilds);
      expect(layouts, initialLayouts);
      await tester.pumpWidget(const SizedBox());
      clock.dispose();
    });
  }
  testWidgets(
    'navigation retains two pages and history does not rebuild MaterialApp',
    (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = AppModel(
        Repository(FixtureTransport()),
        MemoryPreferences(),
      );
      await tester.pumpWidget(HedoneApp(model: model));
      await tester.pumpAndSettle();
      final shell = tester.widget(find.byType(MaterialApp));
      await model.rememberSearch('测试');
      await tester.pump();
      expect(identical(tester.widget(find.byType(MaterialApp)), shell), true);
      for (final label in ['搜索', '社区', '片库', '设置', '发现']) {
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
        if (label == '搜索') {
          await tester.enterText(find.byType(EditableText).first, '未提交的搜索');
        }
        final retained = find.byWidgetPredicate(
          (w) =>
              w is BrowseScreen ||
              w is PostsScreen ||
              w is LibraryScreen ||
              w is SettingsScreen,
          skipOffstage: false,
        );
        expect(retained.evaluate().length, lessThanOrEqualTo(2));
      }
      await tester.tap(find.text('搜索').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText).first)
            .controller
            .text,
        '未提交的搜索',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
}

class _PaintProbe implements FlowPaintingContext {
  final layers = <(int, double)>[];
  @override
  Size get size => const Size(390, 844);
  @override
  int get childCount => 3;
  @override
  Size? getChildSize(int i) => i >= 0 && i < childCount ? size : null;
  @override
  void paintChild(int i, {Matrix4? transform, double opacity = 1}) =>
      layers.add((i, opacity));
}

class _LayoutProbe extends SingleChildRenderObjectWidget {
  const _LayoutProbe({required this.onLayout, required super.child});
  final VoidCallback onLayout;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderProbe(onLayout);
}

class _RenderProbe extends RenderProxyBox {
  _RenderProbe(this.onLayout);
  final VoidCallback onLayout;
  @override
  void performLayout() {
    onLayout();
    super.performLayout();
  }
}
