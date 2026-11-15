import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:hedone/core/native_runtime.dart';
import 'package:hedone/core/playback_route.dart';
import 'package:hedone/data/repository.dart';
import 'package:hedone/data/transport_native.dart';
import 'package:hedone/features/post_video.dart';
import 'package:hedone/src/rust/bridge.dart' as bridge;
import 'package:hedone/ui/app_theme.dart';
import 'package:hedone/ui/design.dart';
import 'package:hedone/ui/playback_surface.dart';

// Real public, non-adult CC BY 3.0 sample, through the production Rust gateway.
const sample =
    'https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/720/Big_Buck_Bunny_720_10s_1MB.mp4';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('real playback starts, hides controls and respects visibility', (
    tester,
  ) async {
    final report = <String, dynamic>{
      'sample': 'Big Buck Bunny',
      'platform': Platform.operatingSystem,
    };
    binding.reportData = report;
    await initializeNativeRuntime();
    final directory = await Directory.systemTemp.createTemp(
      'hedone-playback-ux-',
    );
    await bridge.initialize(dataDir: directory.path);
    final repository = Repository(NativeTransport());
    final watch = Stopwatch()..start();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        navigatorObservers: [playbackRouteObserver],
        builder: (context, child) => AppTheme.scope(context, child!),
        home: PostVideoScreen(
          repository: repository,
          url: sample,
          title: 'Big Buck Bunny · Blender Foundation',
        ),
      ),
    );

    Future<void> until(
      bool Function() condition,
      String failure, {
      Duration budget = const Duration(seconds: 30),
    }) async {
      final timer = Stopwatch()..start();
      while (!condition() && timer.elapsed < budget) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(condition(), isTrue, reason: failure);
    }

    final session = tester
        .widget<PlaybackSurface>(find.byType(PlaybackSurface))
        .session;
    try {
      await until(
        () => find.byType(Video).evaluate().isNotEmpty,
        'Video output was not created',
      );
      final controller = tester.widget<Video>(find.byType(Video)).controller;
      var firstFrame = false;
      unawaited(
        controller.waitUntilFirstFrameRendered.then((_) => firstFrame = true),
      );
      await until(() => firstFrame, 'No decoded first frame');
      report['first_frame_ms'] = watch.elapsedMilliseconds;
      await until(
        () => session.position.value > Duration.zero,
        'Playback did not advance',
      );
      expect(session.error, isNull);
      report['decoder'] = await session.decoderInfo();
      await session.player.setPlaylistMode(PlaylistMode.single);

      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byTooltip('播放设置').hitTestable(), findsNothing);
      expect(
        find.byKey(const ValueKey('playback-seek-track')).hitTestable(),
        findsOneWidget,
      );
      report['controls_auto_hide'] = true;
      if (Platform.isAndroid) {
        await binding.convertFlutterSurfaceToImage();
        await tester.pump();
        await binding.takeScreenshot('playback-hidden');
      }

      await tester.tapAt(tester.getCenter(find.byType(PlaybackSurface)));
      await until(() => !session.playing, 'Tap did not pause');
      await tester.tapAt(tester.getCenter(find.byType(PlaybackSurface)));
      await until(() => session.playing, 'Tap did not resume');
      await tester.tap(find.byTooltip('播放设置'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(session.playing, isTrue);
      Navigator.of(tester.element(find.text('播放速度'))).pop();
      await tester.pump(const Duration(milliseconds: 500));
      report['tap_and_options'] = true;

      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump(const Duration(milliseconds: 500));
      expect(session.playing, isTrue);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      try {
        // A hidden app intentionally stops scheduling frames. Pumping here
        // waits forever; let native events run without requesting a frame.
        final paused = Stopwatch()..start();
        while (session.playing && paused.elapsed < const Duration(seconds: 3)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(
          session.playing,
          isFalse,
          reason: 'Hidden playback was not paused',
        );
      } finally {
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      }
      await tester.pump(const Duration(milliseconds: 300));
      expect(session.playing, isFalse);
      report['simulated_lifecycle'] = true;

      final context = tester.element(find.byType(PlaybackSurface));
      await session.togglePlayback();
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('其他页面')),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(session.playing, isFalse);
      Navigator.of(context).pop();
      await tester.pump(const Duration(milliseconds: 500));
      expect(session.playing, isFalse);
      report['page_visibility'] = true;

      await session.open(
        0,
        1,
        directUrl: sample,
        resume: const Duration(seconds: 4),
      );
      await until(
        () => session.position.value >= const Duration(seconds: 4),
        'Resume start was not applied',
      );
      report['resume_ms'] = session.position.value.inMilliseconds;
      await session.pause();
      await tester.pump(const Duration(milliseconds: 250));
      if (Platform.isAndroid) await binding.takeScreenshot('playback-paused');
      expect(tester.takeException(), isNull);
      report['passed'] = true;
    } finally {
      report['error'] = session.error;
      debugPrint(jsonEncode(report));
      await tester.pumpWidget(const SizedBox());
      // Native release continues after screen disposal; it must not allocate
      // another decoder or resurrect an in-flight source.
      await tester.pump(const Duration(milliseconds: 500));
    }
  });
}
