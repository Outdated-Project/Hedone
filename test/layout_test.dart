import 'package:flutter_test/flutter_test.dart';
import 'package:hghub/core/preferences.dart';
import 'package:hghub/core/app_model.dart';
import 'package:hghub/data/repository.dart';
import 'package:hghub/data/transport.dart';
import 'package:hghub/features/browse.dart';
import 'package:hghub/ui/design.dart';

class MemoryPreferences implements Preferences {
  final Map<String, Object> values = {};
  @override
  Future<String?> getString(String key) async => values[key] as String?;
  @override
  Future<bool?> getBool(String key) async => values[key] as bool?;
  @override
  Future<void> setString(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> setBool(String key, bool value) async {
    values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    values.remove(key);
  }
}

class FixtureTransport implements Transport {
  @override
  Future<Map<String, dynamic>> initialize() async => {
    'base': 'https://huangguoai.com',
  };
  @override
  Future<dynamic> request(Map<String, dynamic> payload) async => {
    'items': List.generate(
      4,
      (i) => {
        'id': i + 1,
        'title': '用于布局回归测试的较长标题 ${i + 1}',
        'cover': '',
        'episode_count': 12,
      },
    ),
    'pagination': {'pages': 1},
  };
  @override
  Future<String> mediaUrl(String url, {required bool image}) async => url;
  @override
  Future<void> clearSession() async {}
  @override
  Future<void> connect(String key) async {}
  @override
  Future<void> persistSession() async {}
}

void main() {
  for (final width in [320.0, 390.0, 800.0, 1440.0]) {
    testWidgets('browse layout at $width logical pixels', (tester) async {
      tester.view.physicalSize = Size(width, 950);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = AppModel(
        Repository(FixtureTransport()),
        MemoryPreferences(),
      );
      await tester.pumpWidget(
        M3EMaterialApp(
          data: M3EThemeData.light(),
          appBuilder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(width == 320 ? 2 : 1),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: Scaffold(body: BrowseScreen(model: model)),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('发现好故事'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
    });
  }
}
