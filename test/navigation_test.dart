import 'package:flutter_test/flutter_test.dart';
import 'package:hedone/app.dart';
import 'package:hedone/core/app_model.dart';
import 'package:hedone/data/repository.dart';
import 'package:hedone/ui/app_navigation.dart';
import 'package:hedone/ui/design.dart';

import 'layout_test.dart' show FixtureTransport, MemoryPreferences;

void main() {
  for (final scenario in [
    (TargetPlatform.android, const Size(390, 844), false),
    (TargetPlatform.android, const Size(844, 390), false),
    (TargetPlatform.iOS, const Size(834, 1194), false),
    (TargetPlatform.android, const Size(1280, 800), true),
    (TargetPlatform.iOS, const Size(1194, 834), true),
    (TargetPlatform.windows, const Size(960, 1280), true),
    (TargetPlatform.linux, const Size(1440, 900), true),
    (TargetPlatform.macOS, const Size(1440, 900), true),
  ]) {
    testWidgets('navigation at $scenario', (tester) async {
      tester.view.physicalSize = scenario.$2;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = AppModel(
        Repository(FixtureTransport()),
        MemoryPreferences(),
      );
      await tester.pumpWidget(HedoneApp(model: model));
      await tester.pumpAndSettle();
      if (scenario.$3) {
        final rail = tester.widget<M3ENavigationRail>(
          find.byType(M3ENavigationRail),
        );
        expect(rail.type, M3ENavigationRailType.alwaysExpand);
        expect(find.byType(CapsuleNavigationBar), findsNothing);
        expect(find.byIcon(Icons.menu_open), findsNothing);
        expect(find.byIcon(Icons.menu), findsNothing);
      } else {
        expect(find.byType(M3ENavigationRail), findsNothing);
        final capsule = find.byType(CapsuleNavigationBar);
        expect(capsule, findsOneWidget);
        expect(
          tester.getSize(find.byType(M3ENavigationBar)).width,
          lessThanOrEqualTo(560),
        );
        expect(
          find.descendant(
            of: capsule,
            matching: find.byWidgetPredicate(
              (w) => w is Material && w.shape is StadiumBorder,
            ),
          ),
          findsOneWidget,
        );
      }
      await tester.tap(find.byIcon(Icons.search_rounded).hitTestable().last);
      await tester.pumpAndSettle();
      expect(find.byType(EditableText), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    }, variant: TargetPlatformVariant({scenario.$1}));
  }

  testWidgets('tablet rotation preserves search and keyboard keeps capsule', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(834, 1194);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final model = AppModel(Repository(FixtureTransport()), MemoryPreferences());
    await tester.pumpWidget(HedoneApp(model: model));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.search_rounded).hitTestable().last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).first, '未提交的搜索');
    final editor = tester.state(find.byType(EditableText).first);
    tester.view.viewInsets = const FakeViewPadding(bottom: 500);
    await tester.pumpAndSettle();
    expect(find.byType(CapsuleNavigationBar), findsOneWidget);
    tester.view.resetViewInsets();
    for (final size in [const Size(1194, 834), const Size(834, 1194)]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(EditableText).first), same(editor));
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText).first)
            .controller
            .text,
        '未提交的搜索',
      );
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });
}
