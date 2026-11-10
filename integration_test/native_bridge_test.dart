import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hghub/src/rust/frb_generated.dart';
import 'package:hghub/src/rust/bridge.dart' as bridge;
import 'package:media_kit/media_kit.dart';
import 'package:hghub/core/playback_session.dart';
import 'package:hghub/data/repository.dart';
import 'package:hghub/data/transport_native.dart';
import 'package:hghub/ui/design.dart';
import 'package:hghub/ui/episode_pager.dart';
import 'package:hghub/data/models.dart';
import 'package:media_kit_video/media_kit_video.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('packaged native library initializes and enforces URL policy', (
    tester,
  ) async {
    final dir = await Directory.systemTemp.createTemp('hghub-bridge-');
    try {
      await RustLib.init();
      final boot = jsonDecode(
        await bridge.initialize(dataDir: dir.path),
      ) as Map<String, dynamic>;
      expect(boot['base'], 'https://huangguoai.com');
      expect(boot['logged_in'], false);
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
        final episodes = objects(detail['episodes'])
            .map(Episode.fromJson)
            .toList();
        var selected = ep as int;
        Future<void>? switched;
        final videoKey = GlobalKey();
        try {
          await tester.pumpWidget(
            M3EMaterialApp(
              data: M3EThemeData.light(),
              home: Scaffold(
                body: StatefulBuilder(
                  builder: (context, update) => EpisodePager(
                    episodes: episodes,
                    selected: selected,
                    video: Video(
                      key: videoKey,
                      controller: session.video,
                      controls: NoVideoControls,
                    ),
                    placeholder: (_, episode) =>
                        Center(child: Text('Episode ${episode.number}')),
                    onSelect: (number) {
                      update(() => selected = number);
                      switched = session.open(id as int, number);
                    },
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
          await tester.pumpWidget(const SizedBox.shrink());
          await session.close();
        }
      }
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
