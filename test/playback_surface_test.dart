import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hedone/core/playback_route.dart';
import 'package:hedone/core/playback_session.dart';
import 'package:hedone/data/models.dart';
import 'package:hedone/ui/app_theme.dart';
import 'package:hedone/ui/design.dart';
import 'package:hedone/ui/episode_pager.dart';
import 'package:hedone/ui/playback_surface.dart';

import 'support/playback_backend.dart';

Widget host(
  PlaybackSession session, {
  Widget? video,
  VoidCallback? onNext,
  double scale = 1,
}) => MaterialApp(
  theme: AppTheme.dark,
  navigatorObservers: [playbackRouteObserver],
  builder: (context, child) => AppTheme.scope(
    context,
    MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
  ),
  home: PlaybackRoute(
    session: session,
    child: Scaffold(
      body: PlaybackSurface(
        session: session,
        video:
            video ??
            const ColoredBox(key: ValueKey('video'), color: Colors.black),
        header: const SizedBox(height: 56, child: Text('测试剧集')),
        episode: 120,
        onNext: onNext,
        onRetry: () {},
        onFullscreen: () {},
        fullscreen: true,
      ),
    ),
  ),
);

// Keep cached asynchronous initialization in the real event loop. Widget
// clocks below remain fake so the auto-hide interval is deterministic.
Future<PlaybackSession> start(
  WidgetTester tester,
  PlaybackBackend backend,
) async => (await tester.runAsync(() async {
  final session = playbackSession(backend);
  await session.open(1, 1);
  return session;
}))!;

void main() {
  testWidgets(
    'video taps toggle playback; hiding controls preserves viewport and track',
    (tester) async {
      final backend = PlaybackBackend();
      final session = await start(tester, backend);
      backend.duration(const Duration(minutes: 6));
      await tester.pumpWidget(host(session));
      final viewport = tester.getRect(find.byKey(const ValueKey('video')));
      expect(find.byTooltip('播放设置').hitTestable(), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byTooltip('播放设置').hitTestable(), findsNothing);
      expect(
        find.byKey(const ValueKey('playback-seek-track')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.getRect(find.byKey(const ValueKey('video'))), viewport);
      // Includes the transparent area previously occupied by the control row.
      await tester.tapAt(viewport.bottomCenter - const Offset(0, 70));
      await tester.pump();
      expect(session.playing, isFalse);
      await tester.tapAt(viewport.center);
      await tester.pump();
      expect(session.playing, isTrue);
      await tester.tap(find.byTooltip('收起控制'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(session.playing, isTrue);
      expect(find.byTooltip('播放设置').hitTestable(), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(session.close);
    },
  );

  testWidgets(
    'settings and seek do not pause or consume vertical episode swipes',
    (tester) async {
      final backend = PlaybackBackend();
      final session = await start(tester, backend);
      backend.duration(const Duration(minutes: 6));
      final episodes = <int>[];
      await tester.pumpWidget(
        host(
          session,
          video: EpisodePager(
            episodes: const [Episode(1, 'one'), Episode(2, 'two')],
            selected: 1,
            video: const ColoredBox(color: Colors.black),
            placeholder: (_, _) => const SizedBox.expand(),
            onSelect: episodes.add,
          ),
        ),
      );
      await tester.tap(find.byTooltip('播放设置'));
      await tester.pumpAndSettle();
      expect(session.playing, isTrue);
      await tester.tap(find.text('1.5×'));
      await tester.pumpAndSettle();
      expect(backend.state.rate, 1.5);
      Navigator.of(tester.element(find.text('播放速度'))).pop();
      await tester.pumpAndSettle();
      final track = tester.getRect(
        find.byKey(const ValueKey('playback-seek-track')),
      );
      await tester.tapAt(track.center);
      await tester.pump();
      expect(backend.seeks.last.inSeconds, closeTo(180, 1));
      expect(session.playing, isTrue);
      final seeks = backend.seeks.length;
      final gesture = await tester.startGesture(track.center);
      await gesture.moveBy(const Offset(90, 0));
      await tester.pump();
      await gesture.cancel();
      await tester.pump();
      expect(backend.seeks, hasLength(seeks));
      await tester.drag(find.byType(PageView), const Offset(0, -500));
      await tester.pumpAndSettle();
      expect(episodes, [2]);
      expect(session.playing, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(session.close);
    },
  );

  testWidgets(
    'full pages pause while popup routes keep playing; back does not auto resume',
    (tester) async {
      final backend = PlaybackBackend();
      final session = await start(tester, backend);
      await tester.pumpWidget(host(session));
      final context = tester.element(find.byType(PlaybackSurface));
      unawaited(
        showDialog<void>(
          context: context,
          builder: (_) => const AlertDialog(content: Text('弹层')),
        ),
      );
      await tester.pumpAndSettle();
      expect(session.playing, isTrue);
      Navigator.of(context).pop();
      await tester.pumpAndSettle();
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('其他页面')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(session.playing, isFalse);
      Navigator.of(context).pop();
      await tester.pumpAndSettle();
      expect(session.playing, isFalse);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(session.close);
    },
  );

  for (final size in [const Size(320, 640), const Size(640, 320)]) {
    testWidgets('controls and settings fit at $size with double text scale', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = PlaybackBackend();
      final session = await start(tester, backend);
      await tester.pumpWidget(host(session, scale: 2, onNext: () {}));
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('播放设置'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(session.close);
    });
  }
}
