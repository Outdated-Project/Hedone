// Runs production screens and transport with an isolated guest data directory.
// Ctrl+P opens the CC BY 3.0 film; Escape returns to settings. No fake feed data.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:hedone/ui/design.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:hedone/core/app_model.dart';
import 'package:hedone/core/native_runtime.dart';
import 'package:hedone/core/preferences.dart';
import 'package:hedone/data/repository.dart';
import 'package:hedone/data/transport_native.dart';
import 'package:hedone/features/post_video.dart';
import 'package:hedone/features/settings.dart';
import 'package:hedone/src/rust/bridge.dart' as bridge;
import 'package:hedone/ui/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeNativeRuntime();
  final directory = await Directory.systemTemp.createTemp('hedone-readme-');
  final boot = jsonDecode(await bridge.initialize(dataDir: directory.path));
  await bridge.request(payload: '{"op":"log_set","enabled":true}');
  final model = AppModel(Repository(NativeTransport()), DevicePreferences())
    ..base = boot['base'] as String;
  final navigator = GlobalKey<NavigatorState>();
  final capture = GlobalKey();
  runApp(
    MaterialApp(
      navigatorKey: navigator,
      title: 'Hedone',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => AppTheme.scope(
        context,
        CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyP, control: true): () {
              if (navigator.currentState!.canPop()) return;
              navigator.currentState!.push(
                MaterialPageRoute<void>(
                  builder: (_) => PostVideoScreen(
                    repository: model.repository,
                    url: 'https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/720/Big_Buck_Bunny_720_10s_1MB.mp4',
                    title: 'Big Buck Bunny · Blender Foundation',
                  ),
                ),
              );
            },
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                navigator.currentState!.maybePop(),
          },
          child: Focus(
            autofocus: true,
            child: RepaintBoundary(key: capture, child: child!),
          ),
        ),
      ),
      home: Scaffold(
        body: SafeArea(child: SettingsScreen(model: model)),
      ),
    ),
  );
  unawaited(_captureScreens(navigator, capture, model));
}

Future<void> _captureScreens(
  GlobalKey<NavigatorState> navigator,
  GlobalKey capture,
  AppModel model,
) async {
  final output = Directory(
    const String.fromEnvironment(
      'HEDONE_CAPTURE_OUTPUT',
      defaultValue: 'docs/screenshots',
    ),
  );
  await output.create(recursive: true);
  Future<void> save(String name) async {
    WidgetsBinding.instance.scheduleFrame();
    await WidgetsBinding.instance.endOfFrame;
    final boundary =
        capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('${output.path}/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  }

  try {
    await Future<void>.delayed(const Duration(seconds: 3));
    await save('settings');
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => PostVideoScreen(
            repository: model.repository,
            url: 'https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/720/Big_Buck_Bunny_720_10s_1MB.mp4',
            title: 'Big Buck Bunny · Blender Foundation',
          ),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(seconds: 2));
    VideoController? video;
    void findVideo(Element element) {
      if (element.widget case Video(:final controller)) video = controller;
      element.visitChildElements(findVideo);
    }

    WidgetsBinding.instance.rootElement!.visitChildElements(findVideo);
    final controller =
        video ?? (throw StateError('Production video widget missing'));
    await controller.waitUntilFirstFrameRendered.timeout(
      const Duration(seconds: 60),
    );
    final player = controller.player;
    await player.seek(const Duration(seconds: 3));
    await Future<void>.delayed(const Duration(seconds: 2));
    await player.pause();
    await save('playback');
    final backend = player.platform;
    final report = <String, dynamic>{
      'film': 'Big Buck Bunny',
      'position_ms': player.state.position.inMilliseconds,
    };
    if (backend is NativePlayer) {
      for (final name in ['hwdec-current', 'video-codec', 'video-format']) {
        report[name] = await backend.getProperty(name);
      }
    }
    await File('${output.path}/capture.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    debugPrint('README capture complete: ${output.path}');
  } catch (error, stack) {
    await save('capture-error');
    final logs = await bridge.request(payload: '{"op":"log_read"}');
    await File('${output.path}/capture-error.json').writeAsString(logs);
    debugPrint('README capture failed: $error\n$stack');
  }
}
