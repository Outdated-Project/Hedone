import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hedone/core/fullscreen_session.dart';
import 'package:hedone/ui/cinema_layout.dart';
import 'package:hedone/ui/design.dart';
import 'package:hedone/ui/episode_pager.dart';
import 'package:hedone/data/models.dart';

class SurfaceProbe extends StatefulWidget {
  const SurfaceProbe({super.key});
  @override
  State<SurfaceProbe> createState() => SurfaceProbeState();
}

class SurfaceProbeState extends State<SurfaceProbe> {
  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.black);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('rotation retains the episode pager and video surface', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 400);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final video = GlobalKey<SurfaceProbeState>();
    final selected = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CinemaLayout(
            header: const SizedBox(height: 56),
            video: EpisodePager(
              episodes: const [Episode(1, '第一集'), Episode(2, '第二集')],
              selected: 1,
              video: SurfaceProbe(key: video),
              placeholder: (_, _) => const SizedBox.expand(),
              onSelect: selected.add,
            ),
            controls: const SizedBox(height: 100),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final surface = video.currentState;
    final pager = tester.state(find.byType(EpisodePager));
    for (final size in [
      const Size(400, 800),
      const Size(800, 400),
      const Size(400, 800),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(video.currentState, same(surface));
      expect(tester.state(find.byType(EpisodePager)), same(pager));
      expect(selected, isEmpty);
    }
  });
  test(
    'mobile fullscreen restores system UI and permits both orientations',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            calls.add(call);
            return null;
          });
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });
      final session = FullscreenSession();
      await session.set(true);
      await session.set(true);
      expect(session.active, isTrue);
      expect(
        calls
            .where((c) => c.method == 'SystemChrome.setPreferredOrientations')
            .single
            .arguments,
        isEmpty,
      );
      await session.close();
      expect(session.active, isFalse);
      expect(
        calls
            .where((c) => c.method == 'SystemChrome.setEnabledSystemUIMode')
            .last
            .arguments,
        'SystemUiMode.edgeToEdge',
      );
      await session.set(true);
      expect(session.active, isFalse);
    },
  );
  testWidgets('zero viewport and selection updates do not read a null page', (
    tester,
  ) async {
    final size = ValueNotifier(const Size(640, 320));
    final selected = ValueNotifier(1);
    final changes = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ValueListenableBuilder<Size>(
              valueListenable: size,
              builder: (context, value, _) => SizedBox(
                width: value.width,
                height: value.height,
                child: ValueListenableBuilder<int>(
                  valueListenable: selected,
                  builder: (context, episode, _) => EpisodePager(
                    episodes: const [Episode(1, '第一集'), Episode(2, '第二集')],
                    selected: episode,
                    video: const SurfaceProbe(),
                    placeholder: (_, _) => const SizedBox.expand(),
                    onSelect: changes.add,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    size.value = Size.zero;
    await tester.pump();
    selected.value = 2;
    await tester.pumpAndSettle();
    size.value = const Size(320, 640);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(changes, isEmpty);
    expect(find.byType(SurfaceProbe), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    size.dispose();
    selected.dispose();
  });

  testWidgets('rotation during a drag does not commit a different episode', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 400);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final changes = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CinemaLayout(
            video: EpisodePager(
              episodes: const [Episode(1, '第一集'), Episode(2, '第二集')],
              selected: 1,
              video: const SurfaceProbe(),
              placeholder: (_, _) => const SizedBox.expand(),
              onSelect: changes.add,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(SurfaceProbe));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(PageView)),
    );
    await gesture.moveBy(const Offset(0, -260));
    await tester.pump();
    tester.view.physicalSize = const Size(400, 800);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(changes, isEmpty);
    expect(tester.state(find.byType(SurfaceProbe)), same(state));
  });
  for (final size in [const Size(320, 640), const Size(640, 320)]) {
    testWidgets('cinema preserves video constraints at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const video = Key('video');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CinemaLayout(
              header: const SizedBox(height: 56),
              video: const ColoredBox(key: video, color: Colors.black),
              controls: const SizedBox(height: 150),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byKey(video)).height,
        size.width > size.height ? size.height : size.height - 206,
      );
    });
  }
}
