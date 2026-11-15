import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/playback_backend.dart';

Future<void> flush() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'source and output initialize concurrently; inactive keeps autoplay',
    () async {
      final backend = PlaybackBackend();
      final transport = PlaybackTransport()..pending[1] = Completer<String>();
      final output = Completer<void>();
      var preparations = 0;
      final session = playbackSession(
        backend,
        transport: transport,
        prepareVideo: () {
          preparations++;
          return output.future;
        },
      );
      final opening = session.open(1, 1, resume: const Duration(seconds: 37));
      expect(transport.requested, [1]);
      expect(preparations, 1);
      session.didChangeAppLifecycleState(AppLifecycleState.inactive);
      transport.pending[1]!.complete('https://example.com/resume.mp4');
      output.complete();
      await opening;
      await flush();
      expect(backend.opened.single.start, const Duration(seconds: 37));
      expect(backend.plays, 1);
      expect(session.playing, isTrue);
      expect(session.loading, isFalse);
      expect(backend.seeks, isEmpty); // No duration timeout or second seek.
      final pauses = backend.pauses;
      session.didChangeAppLifecycleState(AppLifecycleState.inactive);
      await flush();
      expect(backend.pauses, pauses);
      await session.close();
    },
  );

  for (final state in [
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.detached,
  ]) {
    test(
      '$state cancels pending autoplay and returning does not resume',
      () async {
        final backend = PlaybackBackend()..opening = Completer<void>();
        final session = playbackSession(backend);
        final opening = session.open(1, 1);
        await flush();
        expect(backend.opened, hasLength(1));
        session.didChangeAppLifecycleState(state);
        backend.opening!.complete();
        await opening;
        session.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await flush();
        expect(backend.plays, 0);
        await session.togglePlayback();
        await flush();
        expect(session.playing, isTrue);
        session.didChangeAppLifecycleState(state);
        await flush();
        expect(session.playing, isFalse);
        await session.close();
      },
    );
  }

  test('rapid selection discards slow previous URLs', () async {
    final backend = PlaybackBackend();
    final transport = PlaybackTransport()..pending[1] = Completer<String>();
    final session = playbackSession(backend, transport: transport);
    final first = session.open(1, 1);
    await session.open(1, 2);
    transport.pending[1]!.complete('https://example.com/obsolete.mp4');
    await first;
    expect(backend.opened.map((m) => m.uri), [
      'https://example.com/test-2.mp4',
    ]);
    expect(session.episode, 2);
    await session.close();
  });

  test(
    'a decoder open in flight cannot play after a newer selection',
    () async {
      final backend = PlaybackBackend()..opening = Completer<void>();
      final session = playbackSession(backend);
      final first = session.open(1, 1);
      await flush();
      final second = session.open(1, 2);
      backend.opening!.complete();
      await Future.wait([first, second]);
      expect(backend.opened, hasLength(2));
      expect(backend.plays, 1);
      expect(session.episode, 2);
      await session.close();
    },
  );

  test('pausing a pending URL is respected after it resolves', () async {
    final backend = PlaybackBackend();
    final transport = PlaybackTransport()..pending[1] = Completer<String>();
    final session = playbackSession(backend, transport: transport);
    final opening = session.open(1, 1);
    await session.togglePlayback();
    transport.pending[1]!.complete('https://example.com/paused.mp4');
    await opening;
    expect(backend.plays, 0);
    await session.close();
  });

  test(
    'late duration resets finished history without overriding background pause',
    () async {
      final backend = PlaybackBackend();
      final session = playbackSession(backend);
      await session.open(1, 1, resume: const Duration(seconds: 58));
      session.didChangeAppLifecycleState(AppLifecycleState.hidden);
      backend.duration(const Duration(seconds: 60));
      await flush();
      expect(backend.seeks, [Duration.zero]);
      expect(backend.plays, 1);
      expect(session.playing, isFalse);
      await session.close();
    },
  );

  test(
    'route loss cancels pending autoplay but popup-independent focus does not',
    () async {
      final backend = PlaybackBackend()..opening = Completer<void>();
      final session = playbackSession(backend);
      final opening = session.open(1, 1);
      await flush();
      session.setRouteVisible(false);
      backend.opening!.complete();
      await opening;
      session.setRouteVisible(true);
      expect(backend.plays, 0);
      await session.togglePlayback();
      expect(backend.plays, 1);
      await session.close();
    },
  );

  test(
    'closing during output initialization never opens or leaks a decoder',
    () async {
      final backend = PlaybackBackend();
      final output = Completer<void>();
      final session = playbackSession(
        backend,
        prepareVideo: () => output.future,
      );
      // Simulate a VideoController which has allocated the backend already.
      session.player;
      final opening = session.open(1, 1);
      final closing = session.close();
      output.complete();
      await Future.wait([opening, closing]);
      expect(backend.opened, isEmpty);
      expect(backend.disposed, isTrue);
    },
  );
}
