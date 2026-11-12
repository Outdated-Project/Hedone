import 'dart:io';
import 'dart:convert';

import 'package:hedone/app.dart';
import 'package:hedone/core/app_model.dart';
import 'package:hedone/core/preferences.dart';
import 'package:hedone/features/license.dart';
import 'package:hedone/features/browse.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hedone/core/native_runtime.dart';
import 'package:hedone/core/fullscreen_session.dart';
import 'package:hedone/src/rust/bridge.dart' as bridge;
import 'package:media_kit/media_kit.dart';
import 'package:hedone/core/playback_session.dart';
import 'package:hedone/data/repository.dart';
import 'package:hedone/data/transport_native.dart';
import 'package:hedone/ui/design.dart';
import 'package:hedone/ui/episode_pager.dart';
import 'package:hedone/ui/cinema_layout.dart';
import 'package:hedone/ui/playback_controls.dart';
import 'package:hedone/data/models.dart';
import 'package:media_kit_video/media_kit_video.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('packaged native library initializes and enforces URL policy', (
    tester,
  ) async {
    final dir = await Directory.systemTemp.createTemp('hedone-bridge-');
    try {
      await initializeNativeRuntime();
      final boot = jsonDecode(
        await bridge.initialize(dataDir: dir.path),
      ) as Map<String, dynamic>;
      expect(boot['base'], 'https://huangguoai.com');
      expect(boot['logged_in'], false);
      // Fixed line selection is local and must work without a network probe.
      for (final origin in [
        'https://huangguoai.ai',
        'https://huangguoai.com',
      ]) {
        final selected = jsonDecode(
          await bridge.request(
            payload: jsonEncode({'op': 'line_set', 'url': origin}),
          ),
        );
        expect(selected['base'], origin);
        final state = jsonDecode(
          await bridge.request(payload: '{"op":"line_state"}'),
        );
        expect(state['base'], origin);
        expect((state['fixed'] as List).length, 2);
      }
      await expectLater(
        bridge.mediaUrl(url: 'http://127.0.0.1/private', image: true),
        throwsA(anything),
      );
      await expectLater(
        bridge.request(payload: '{"op":"play","id":1,"ep":0}'),
        throwsA(anything),
      );
      final image = await bridge.mediaUrl(
        url: 'https://example.com/cover',
        image: true,
      );
      expect(Uri.parse(image).host, '127.0.0.1');
      expect(Uri.parse(image).pathSegments.first.length, 64);
      const liveBase = String.fromEnvironment('HEDONE_LIVE_BASE');
      if (liveBase.isNotEmpty) {
        if (const bool.fromEnvironment('HEDONE_CAPTURE_DIAGNOSTICS')) {
          await bridge.request(payload: '{"op":"log_set","enabled":true}');
        }
        await bridge.request(
          payload: jsonEncode({'op': 'line_set', 'url': liveBase}),
        );
        if (const bool.fromEnvironment('HEDONE_CAPTURE_DIAGNOSTICS')) {
          final diagnostics = jsonDecode(
            await bridge.request(payload: '{"op":"net_diag"}'),
          ) as Map<String, dynamic>;
          // Only report resolution counts and probe status, never account data
          // or signed media URLs.
          final summary = {
            'dns': diagnostics['dns'],
            'resolver': diagnostics['resolver'],
            'http': diagnostics['http'],
          };
          binding.reportData = {'network': summary};
          debugPrint(jsonEncode(summary));
        }
        final feed = jsonDecode(
          await bridge.request(payload: '{"op":"feed","page":1,"size":24}'),
        );
        expect(feed['items'], isNotEmpty);
        final dramas = jsonDecode(
          await bridge.request(
            payload: '{"op":"category","cate":"ai-duanju","page":1,"size":24}',
          ),
        );
        expect(dramas['items'], isNotEmpty);
        final id = dramas['items'][0]['id'];
        final detail = jsonDecode(
          await bridge.request(payload: jsonEncode({'op': 'video', 'id': id})),
        );
        final ep = detail['episodes'][0]['ep_num'];
        MediaKit.ensureInitialized();
        final session = PlaybackSession(Repository(NativeTransport()));
        final player = session.player;
        final decoderErrors = player.stream.error.listen((error) {
          if (const bool.fromEnvironment('HEDONE_CAPTURE_DIAGNOSTICS')) {
            debugPrint(error.replaceAll(RegExp(r'https?://\S+'), '[media]'));
          }
        });
        final decoderLog = player.stream.log.listen((event) {
          if (const bool.fromEnvironment('HEDONE_CAPTURE_DIAGNOSTICS')) {
            debugPrint(
              event.toString().replaceAll(RegExp(r'https?://\S+'), '[media]'),
            );
          }
        });
        final episodes = objects(detail['episodes'])
            .map(Episode.fromJson)
            .toList();
        var selected = ep as int;
        Future<void>? switched;
        final videoKey = GlobalKey();
        final viewport = ValueNotifier(const Size(720, 360));
        const physicalRotation = bool.fromEnvironment('HEDONE_DEVICE_ROTATION');
        final presentation = FullscreenSession();
        try {
          if (physicalRotation) {
            await presentation.set(true);
            await SystemChrome.setPreferredOrientations([
              DeviceOrientation.landscapeLeft,
            ]);
          }
          await tester.pumpWidget(
            M3EMaterialApp(
              data: M3EThemeData.light(),
              home: Scaffold(
                body: Center(
                  child: ValueListenableBuilder<Size>(
                    valueListenable: viewport,
                    builder: (context, size, _) => SizedBox(
                      width: physicalRotation ? double.infinity : size.width,
                      height: physicalRotation ? double.infinity : size.height,
                      child: CinemaLayout(
                        header: const SizedBox(height: 56),
                        video: StatefulBuilder(
                          builder: (context, update) => EpisodePager(
                            episodes: episodes,
                            selected: selected,
                            video: Video(
                              key: videoKey,
                              controller: session.video,
                              controls: NoVideoControls,
                            ),
                            placeholder: (_, episode) => Center(
                              child: Text('Episode ${episode.number}'),
                            ),
                            onSelect: (number) {
                              update(() => selected = number);
                              switched = session.open(id as int, number);
                            },
                          ),
                        ),
                        controls: PlaybackControls(
                          session: session,
                          episode: selected,
                          onNext: null,
                          onFullscreen: () {},
                          fullscreen: true,
                          onRetry: () {},
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await session.video.platform.future.timeout(
            const Duration(seconds: 20),
          );
          await player.setVolume(0);
          await session
              .open(id as int, ep)
              .timeout(const Duration(seconds: 60));
          expect(session.error, isNull);
          expect(session.loading, false);
          final length = player.state.duration > Duration.zero
              ? player.state.duration
              : await player.stream.duration
                    .firstWhere((d) => d > Duration.zero)
                    .timeout(const Duration(seconds: 30));
          expect(length, greaterThan(const Duration(seconds: 2)));
          await player.play();
          await session.video.waitUntilFirstFrameRendered.timeout(
            const Duration(seconds: 30),
          );
          await player.stream.position
              .firstWhere((p) => p > const Duration(milliseconds: 700))
              .timeout(const Duration(seconds: 30));
          final videoState = videoKey.currentState;
          final pagerState = tester.state(find.byType(EpisodePager));
          for (final size in [
            const Size(360, 720),
            const Size(720, 360),
            const Size(360, 720),
          ]) {
            if (physicalRotation) {
              final landscape = size.width > size.height;
              await SystemChrome.setPreferredOrientations([
                landscape
                    ? DeviceOrientation.landscapeLeft
                    : DeviceOrientation.portraitUp,
              ]);
              for (var frame = 0; frame < 80; frame++) {
                await tester.pump(const Duration(milliseconds: 100));
                final actual = tester.view.physicalSize;
                if ((actual.width > actual.height) == landscape) break;
              }
              final actual = tester.view.physicalSize;
              expect(
                actual.width > actual.height,
                landscape,
                reason: 'the device must actually rotate before testing the surface',
              );
            } else {
              viewport.value = size;
            }
            for (var frame = 0; frame < 5; frame++) {
              await tester.pump(const Duration(milliseconds: 100));
              expect(tester.takeException(), isNull);
            }
            expect(videoKey.currentState, same(videoState));
            expect(session.player, same(player));
            expect(player.state.playing, isTrue);
            expect(session.episode, ep);
            expect(switched, isNull);
          }
          expect(tester.state(find.byType(EpisodePager)), same(pagerState));
          final afterRotation = player.state.position;
          await player.stream.position
              .firstWhere(
                (value) =>
                    value > afterRotation + const Duration(milliseconds: 400),
              )
              .timeout(const Duration(seconds: 15));
          final seek = Duration(milliseconds: length.inMilliseconds ~/ 3);
          await session.seek(seek);
          await player.stream.position
              .firstWhere((p) => (p - seek).abs() < const Duration(seconds: 3))
              .timeout(const Duration(seconds: 20));
          await player.pause();
          if (episodes.length > 1) {
            await session.prepareNext(id, episodes[1].number);
            final height = tester.getSize(find.byType(PageView)).height;
            await tester.fling(
              find.byType(PageView),
              Offset(0, -height * .85),
              1200,
            );
            for (var i = 0; i < 30 && switched == null; i++) {
              await tester.pump(const Duration(milliseconds: 100));
            }
            expect(switched, isNotNull);
            // Selection is dispatched after layout; mount the selected video
            // on the following frame before checking its visible widget.
            await tester.pump();
            await switched!.timeout(const Duration(seconds: 60));
            expect(session.error, isNull);
            expect(session.episode, episodes[1].number);
            expect(identical(player, session.player), true);
            expect(find.byType(Video), findsOneWidget);
            await player.stream.position
                .firstWhere((p) => p > const Duration(milliseconds: 700))
                .timeout(const Duration(seconds: 30));
            await player.pause();
          }
        } finally {
          await decoderErrors.cancel();
          await decoderLog.cancel();
          await tester.pumpWidget(const SizedBox.shrink());
          viewport.dispose();
          await session.close();
          if (physicalRotation) {
            await SystemChrome.setPreferredOrientations([]);
            await presentation.close();
          }
        }
      }
      // Exercise the real app shell and bundled document through the already
      // initialized temporary runtime, without reading account credentials.
      final model = AppModel(
        Repository(_InitializedTransport()),
        DevicePreferences(),
      );
      await tester.pumpWidget(HedoneApp(model: model));
      for (
        var frame = 0;
        frame < 100 && find.text('发现好故事').evaluate().isEmpty;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('发现好故事'), findsOneWidget);
      if (const String.fromEnvironment('HEDONE_LIVE_BASE').isNotEmpty) {
        for (
          var frame = 0;
          frame < 300 && find.byType(VideoTile).evaluate().isEmpty;
          frame++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          find.byType(VideoTile),
          findsWidgets,
          reason:
              'the real discovery page must load videos, not only its heading',
        );
      }
      // Collapsed desktop rails expose the icon; their text is intentionally
      // outside the hit-test area at intermediate window widths.
      await tester.tap(find.byIcon(Icons.tune_rounded).last);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('震动反馈'), findsOneWidget);
      await tester.ensureVisible(find.text('许可证'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('许可证').hitTestable(), findsOneWidget);
      await tester.tap(find.text('许可证'));
      for (
        var frame = 0;
        frame < 50 && find.byType(LicenseScreen).evaluate().isEmpty;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(LicenseScreen), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
    } finally {
      if (const bool.fromEnvironment('HEDONE_CAPTURE_DIAGNOSTICS')) {
        try {
          final log = File('${dir.path}/playback.log');
          if (await log.exists()) {
            // The driver writes on the host. Android's working directory is
            // read-only; diagnostic export must not mask a playback failure.
            binding.reportData = {
              ...?binding.reportData,
              'playback_log': await log.readAsString(),
            };
          }
        } on FileSystemException {
          debugPrint('Playback diagnostic export unavailable');
        }
      }
      await dir.delete(recursive: true);
    }
  });
}

class _InitializedTransport extends NativeTransport {
  @override
  Future<Map<String, dynamic>> initialize() async =>
      jsonDecode(await bridge.request(payload: '{"op":"boot"}'))
          as Map<String, dynamic>;
}
