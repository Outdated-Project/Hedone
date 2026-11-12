import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hedone/core/app_model.dart';
import 'package:hedone/data/repository.dart';
import 'package:hedone/data/transport.dart';
import 'package:hedone/features/settings.dart';
import 'package:hedone/features/lines.dart';
import 'package:hedone/features/network_diagnostics.dart';
import 'package:hedone/ui/action_list_item.dart';
import 'package:hedone/ui/app_theme.dart';
import 'package:hedone/ui/design.dart';

import 'layout_test.dart' show FixtureTransport, MemoryPreferences;

const first = 'https://huangguoai.com';
const second = 'https://huangguoai.ai';

class SettingsTransport extends FixtureTransport {
  final probe = Completer<dynamic>();
  final cache = Completer<dynamic>();
  final calls = <String>[];
  Map<String, dynamic> report = {
    'base': second,
    'dns': {'count': 10, 'has_fake_ip': false},
    'http': {'error': 'Io: TLS certificate error: no trusted root found'},
    'env': <String, dynamic>{},
    'transport': {'upstream_streaming': false, 'progressive_range': true},
  };

  @override
  Future<Map<String, dynamic>> initialize() async => {'base': second};

  @override
  Future<dynamic> request(Map<String, dynamic> payload) async {
    final op = payload['op'] as String;
    calls.add(op);
    return switch (op) {
      'line_state' => {
        'fixed': [
          {'name': '固定线路 1', 'url': first},
          {'name': '固定线路 2', 'url': second},
        ],
      },
      'line_set' => {'base': payload['url']},
      'line_mirrors' => {
        'items': [
          {'host': 'mirror.example', 'url': 'https://mirror.example'},
        ],
      },
      'line_probe' => probe.future,
      'cache_clear' => cache.future,
      'log_status' => {'enabled': false},
      'net_diag' => report,
      _ => super.request(payload),
    };
  }
}

Future<void> mount(
  WidgetTester tester,
  Widget child, {
  double width = 390,
  bool dark = true,
  bool reducedMotion = true,
  GlobalKey? boundary,
}) async {
  tester.view.physicalSize = Size(width, 960);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: dark ? AppTheme.dark : AppTheme.light,
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(width == 320 ? 2 : 1),
            disableAnimations: reducedMotion,
          ),
          child: AppTheme.scope(context, child!),
        ),
        home: child,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

Future<void> capture(
  WidgetTester tester,
  GlobalKey boundary,
  String name,
) async {
  if (!const bool.fromEnvironment('HG_CAPTURE_LAYOUTS')) return;
  await tester.runAsync(() async {
    final image =
        await (boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary)
            .toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory('build/qa').create(recursive: true);
    await File('build/qa/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('upstream HTTP error documents are not displayed as UI copy', () {
    final message = errorMessage('HTTP 404 Not Found: <html>nginx</html>');
    expect(message, contains('更换数据线路'));
    expect(message, isNot(contains('<html>')));
  });
  test('catalogue business failures explain that the server was reached', () {
    for (final error in ['获取视频列表失败', 'AnyhowException: 上游接口失败：获取视频列表失败']) {
      expect(errorMessage(error), contains('已连接到服务器'));
      expect(errorMessage(error), contains('更换数据线路'));
    }
  });
  setUpAll(() async {
    for (final entry in {
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
      'Google Sans': 'assets/fonts/googlesans.ttf',
      'Noto Sans SC': 'assets/fonts/notosanssc.ttf',
    }.entries) {
      await (FontLoader(
        entry.key,
      )..addFont(rootBundle.load(entry.value))).load();
    }
  });

  testWidgets('guest can select a line while connection probe is pending', (
    tester,
  ) async {
    final transport = SettingsTransport();
    final model = AppModel(Repository(transport), MemoryPreferences());
    await model.initialize();
    await mount(tester, LinesScreen(model: model));
    await tester.tap(find.text('检测连接'));
    await tester.pump();
    await tester.tap(find.text('固定线路 1'));
    await tester.pump();
    expect(model.base, first);
    expect(transport.calls.where((op) => op == 'line_set'), hasLength(1));
    expect(
      tester.widget<M3EListItem>(find.byKey(const ValueKey(first))).selected,
      isTrue,
    );
    transport.probe.complete([
      {'url': first, 'ok': true, 'ms': 42},
      {'url': second, 'ok': false, 'status': 404},
    ]);
    await tester.pumpAndSettle();
    expect(find.textContaining('连接正常 · 42 ms'), findsOneWidget);
    expect(find.textContaining('HTTP 404'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
  });

  testWidgets('automatic recovery selects a verified line and returns', (
    tester,
  ) async {
    final transport = SettingsTransport();
    final model = AppModel(Repository(transport), MemoryPreferences());
    await model.initialize();
    await mount(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => LinesScreen(model: model),
              ),
            ),
            child: const Text('打开线路'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开线路'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('自动选择可用线路'));
    await tester.tap(find.text('自动选择可用线路'));
    await tester.pump();
    transport.probe.complete([
      {'url': first, 'ok': true, 'ms': 42},
      {'url': second, 'ok': false, 'status': 404},
      {'url': 'https://mirror.example', 'ok': false, 'error': '获取视频列表失败'},
    ]);
    await tester.pumpAndSettle();
    expect(model.base, first);
    expect(transport.calls.where((op) => op == 'line_set'), hasLength(1));
    expect(find.byType(LinesScreen), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
  });

  testWidgets('failed probes never select an unavailable line', (tester) async {
    final transport = SettingsTransport();
    final model = AppModel(Repository(transport), MemoryPreferences());
    await model.initialize();
    await mount(tester, LinesScreen(model: model));
    await tester.ensureVisible(find.text('自动选择可用线路'));
    await tester.tap(find.text('自动选择可用线路'));
    await tester.pump();
    transport.probe.complete([
      {'url': first, 'ok': false, 'error': '获取视频列表失败'},
      {'url': second, 'ok': false, 'status': 404},
      {'url': 'https://mirror.example', 'ok': false, 'status': 200},
    ]);
    await tester.pumpAndSettle();
    expect(model.base, second);
    expect(transport.calls, isNot(contains('line_set')));
    expect(find.byType(LinesScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
  });

  testWidgets('signed in line selection can cancel then confirm', (
    tester,
  ) async {
    final transport = SettingsTransport();
    final model = AppModel(Repository(transport), MemoryPreferences());
    await model.initialize();
    model.user = {'id': 1};
    await mount(tester, LinesScreen(model: model));
    await tester.tap(find.text('固定线路 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(model.base, second);
    expect(model.user, isNotNull);
    await tester.tap(find.text('固定线路 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('切换'));
    await tester.pumpAndSettle();
    expect(model.base, first);
    expect(model.user, isNull);
    expect(find.byType(LinesScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
  });

  testWidgets('pending cache action leaves diagnostics and lines usable', (
    tester,
  ) async {
    final transport = SettingsTransport();
    final model = AppModel(Repository(transport), MemoryPreferences());
    await model.initialize();
    await mount(tester, Scaffold(body: SettingsScreen(model: model)));
    await tester.ensureVisible(find.text('清理媒体缓存'));
    await tester.tap(find.text('清理媒体缓存'));
    await tester.pump();
    final actions = tester.widgetList<ActionListItem>(
      find.byType(ActionListItem),
    );
    expect(actions.where((row) => row.busy).map((row) => row.headline), [
      '清理媒体缓存',
    ]);
    expect(
      tester
          .widgetList<M3EListItem>(find.byType(M3EListItem))
          .every((row) => row.enabled),
      isTrue,
    );
    await tester.tap(find.text('网络自检'));
    await tester.pumpAndSettle();
    expect(find.text('域名解析正常'), findsOneWidget);
    expect(find.text('安全连接失败'), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
    transport.cache.complete(<String, dynamic>{});
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
  });

  testWidgets('HTTP error is distinct from TLS failure', (tester) async {
    final transport = SettingsTransport();
    transport.report['http'] = {
      'probe': 'content_api',
      'ok': false,
      'status': 404,
      'ms': 80,
    };
    await mount(
      tester,
      NetworkDiagnosticsScreen(repository: Repository(transport)),
    );
    expect(find.text('服务器响应异常'), findsOneWidget);
    expect(find.text('安全连接失败'), findsNothing);
    await tester.ensureVisible(find.text('技术详情'));
    await tester.tap(find.text('技术详情'));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('technical details expand and collapse with motion enabled', (
    tester,
  ) async {
    await mount(
      tester,
      NetworkDiagnosticsScreen(repository: Repository(SettingsTransport())),
      reducedMotion: false,
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('技术详情'));
    await tester.tap(find.text('技术详情'));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsOneWidget);
    await tester.ensureVisible(find.text('收起技术详情'));
    await tester.tap(find.text('收起技术详情'));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('content success is reported only after an API probe', (
    tester,
  ) async {
    final transport = SettingsTransport();
    transport.report['http'] = {'probe': 'content_api', 'ok': true, 'ms': 80};
    await mount(
      tester,
      NetworkDiagnosticsScreen(repository: Repository(transport)),
    );
    expect(find.text('内容接口正常'), findsOneWidget);
    expect(find.text('连接正常'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 390.0]) {
    for (final dark in [false, true]) {
      testWidgets('settings pages fit $width, dark=$dark', (tester) async {
        final transport = SettingsTransport();
        final model = AppModel(Repository(transport), MemoryPreferences());
        await model.initialize();
        final boundary = GlobalKey();
        await mount(
          tester,
          LinesScreen(model: model),
          width: width,
          dark: dark,
          boundary: boundary,
        );
        expect(tester.takeException(), isNull);
        await capture(tester, boundary, 'lines-${width.toInt()}-$dark');
        await mount(
          tester,
          NetworkDiagnosticsScreen(repository: model.repository),
          width: width,
          dark: dark,
          boundary: boundary,
        );
        expect(tester.takeException(), isNull);
        await capture(tester, boundary, 'diagnostics-${width.toInt()}-$dark');
        await tester.pumpWidget(const SizedBox.shrink());
        model.dispose();
      });
    }
  }
}
