import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hghub/core/native_runtime.dart';
import 'package:hghub/core/fullscreen_session.dart';
import 'package:hghub/src/rust/bridge.dart' as bridge;
import 'package:media_kit/media_kit.dart';
import 'package:hghub/core/playback_session.dart';
import 'package:hghub/data/repository.dart';
import 'package:hghub/data/transport_native.dart';
import 'package:hghub/ui/design.dart';
import 'package:hghub/ui/episode_pager.dart';
import 'package:hghub/ui/cinema_layout.dart';
import 'package:hghub/ui/playback_controls.dart';
import 'package:hghub/data/models.dart';
import 'package:media_kit_video/media_kit_video.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('packaged native library initializes and enforces URL policy', (
    tester,
  ) async {
    final dir = await Directory.systemTemp.createTemp('hghub-bridge-');
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
      const liveBase = String.fromEnvironment('HGHUB_LIVE_BASE');
      if (liveBase.isNotEmpty) {
        if (const bool.fromEnvironment('HGHUB_CAPTURE_DIAGNOSTICS')) {
          await bridge.request(payload: '{"op":"log_set","enabled":true}');
        }
        await bridge.request(
          payload: jsonEncode({'op': 'line_set', 'url': liveBase}),
        );
        final feed = jsonDecode(
          await bridge.request(payload: '{"op":"feed","page":1,"size":1}'),
        );
        final id = feed['items'][0]['id'];
        final detail = jsonDecode(
          await bridge.request(payload: jsonEncode({'op': 'video', 'id': id})),
        );
        final ep = detail['episodes'][0]['ep_num'];
        MediaKit.ensureInitialized();
        final session = PlaybackSession(Repository(NativeTransport()));
        final player = session.player;
        final decoderErrors = player.stream.error.listen((error) {
          if (const bool.fromEnvironment('HGHUB_CAPTURE_DIAGNOSTICS')) {
            debugPrint(error.replaceAll(RegExp(r'https?://\S+'), '[media]'));
          }
        });
        final decoderLog = player.stream.log.listen((event) {
          if (const bool.fromEnvironment('HGHUB_CAPTURE_DIAGNOSTICS')) {
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
        const physicalRotation = bool.fromEnvironment('HGHUB_DEVICE_ROTATION');
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
    } finally {
      if (const bool.fromEnvironment('HGHUB_CAPTURE_DIAGNOSTICS')) {
        final log = File('${dir.path}/playback.log');
        if (await log.exists()) {
          await Directory('build/qa').create(recursive: true);
          await log.copy('build/qa/native-playback.log');
        }
      }
      await dir.delete(recursive: true);
    }
  });
}
