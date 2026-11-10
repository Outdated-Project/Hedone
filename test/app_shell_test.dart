import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hghub/app.dart';
import 'package:hghub/core/app_model.dart';
import 'package:hghub/data/repository.dart';
import 'package:hghub/data/transport.dart';
import 'package:hghub/ui/design.dart';

import 'layout_test.dart' show MemoryPreferences, FixtureTransport;

class ExpiringTransport extends FixtureTransport {
  bool expired = false;
  @override
  Future<dynamic> request(Map<String, dynamic> payload) {
    if (expired) return Future.error(const ServiceConnectionRequired());
    return super.request(payload);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    for (final entry in {
      'Roboto Flex': 'robotoflex',
      'Noto Sans SC': 'notosanssc',
    }.entries) {
      final loader = FontLoader(entry.key)
        ..addFont(rootBundle.load('assets/fonts/${entry.value}.ttf'));
      await loader.load();
    }
  });

  for (final width in [320.0, 390.0, 1440.0]) {
    testWidgets('shell navigation and theme at $width', (tester) async {
      tester.view.physicalSize = Size(width, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      if (width == 320) {
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      }
      final model = AppModel(
        Repository(FixtureTransport()),
        MemoryPreferences(),
      );
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: HGhubApp(model: model),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('发现好故事'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('HG_CAPTURE_LAYOUTS')) {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory('build/qa').create(recursive: true);
          await File('build/qa/shell-${width.toInt()}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.text('设置').last);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('外观与动效'), findsOneWidget);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      for (final mode in ['dark', 'light', 'system']) {
        await model.setTheme(mode);
        await tester.pump();
        // The same surface must reach the scaffold and Expressive components,
        // including intermediate animation frames (the reported regression).
        for (var frame = 0; frame < 5; frame++) {
          await tester.pump(const Duration(milliseconds: 90));
          final context = tester.element(find.text('外观与动效'));
          final material = Theme.of(context);
          final expressive = M3ETheme.of(context);
          expect(
            material.scaffoldBackgroundColor,
            material.colorScheme.surface,
          );
          expect(expressive.colorScheme.surface, material.colorScheme.surface);
          expect(
            expressive.colorScheme.onSurface,
            material.colorScheme.onSurface,
          );
        }
        final theme = Theme.of(tester.element(find.text('外观与动效')));
        expect(
          theme.brightness,
          mode == 'light' ? Brightness.light : Brightness.dark,
        );
        final luminances = [
          theme.colorScheme.surface.computeLuminance(),
          theme.colorScheme.onSurface.computeLuminance(),
        ]..sort();
        expect(
          (luminances.last + .05) / (luminances.first + .05),
          greaterThan(7),
        );
        if (const bool.fromEnvironment('HG_CAPTURE_LAYOUTS')) {
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File('build/qa/settings-${width.toInt()}-$mode.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
    });
  }

  testWidgets(
    'navigation retargets without opacity jumps and respects reduced motion',
    (tester) async {
      tester.view.physicalSize = const Size(390, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = AppModel(
        Repository(FixtureTransport()),
        MemoryPreferences(),
      );
      await tester.pumpWidget(HGhubApp(model: model));
      await tester.pumpAndSettle();
      double opacity() => tester
          .widget<Opacity>(
            find
                .ancestor(
                  of: find.text('发现好故事'),
                  matching: find.byType(Opacity),
                )
                .first,
          )
          .opacity;
      await tester.tap(find.text('搜索').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      final before = opacity();
      expect(before, inExclusiveRange(0, 1));
      await tester.tap(find.text('设置').last);
      await tester.pump();
      expect(opacity(), closeTo(before, .00001));
      await model.setReducedMotion(true);
      await tester.pumpAndSettle();
      expect(find.text('发现好故事'), findsNothing);
      expect(find.text('外观与动效'), findsOneWidget);
      await tester.tap(find.text('发现').last);
      await tester.pump();
      expect(opacity(), 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
    },
  );

  testWidgets('expired service replaces an open detail route', (tester) async {
    final transport = ExpiringTransport();
    final model = AppModel(Repository(transport), MemoryPreferences());
    await tester.pumpWidget(HGhubApp(model: model));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final route = AuroraMotion.open<void>(
      tester.element(find.text('发现好故事')),
      const Scaffold(body: Text('route awaiting service')),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('route awaiting service'), findsOneWidget);
    transport.expired = true;
    await expectLater(
      model.repository.call('boot'),
      throwsA(isA<ServiceConnectionRequired>()),
    );
    await tester.pumpAndSettle();
    expect(find.text('route awaiting service'), findsNothing);
    expect(find.text('连接你的 Rust 服务'), findsOneWidget);
    await route;
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
  });

  test('expired service invalidates identity once and reconnects', () async {
    final transport = ExpiringTransport();
    final model = AppModel(Repository(transport), MemoryPreferences());
    await model.initialize();
    transport.expired = true;
    await expectLater(
      model.repository.call('boot'),
      throwsA(isA<ServiceConnectionRequired>()),
    );
    await expectLater(
      model.repository.call('boot'),
      throwsA(isA<ServiceConnectionRequired>()),
    );
    expect(model.serviceExpired, true);
    expect(model.identityRevision, 1);
    transport.expired = false;
    await model.initialize();
    expect(model.serviceExpired, false);
    model.dispose();
  });
}
