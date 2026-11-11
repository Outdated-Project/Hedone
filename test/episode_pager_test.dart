import 'package:flutter_test/flutter_test.dart';
import 'package:hedone/data/models.dart';
import 'package:hedone/ui/design.dart';
import 'package:hedone/ui/episode_pager.dart';
import 'package:hedone/ui/episode_picker.dart';
import 'package:hedone/ui/app_theme.dart';

void main() {
  testWidgets('500 episodes keep one video and commit only settled gestures', (
    tester,
  ) async {
    final episodes = List.generate(500, (i) => Episode(i * 2 + 1, ''));
    var selected = 1, changes = 0, built = 0;
    final videoKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => EpisodePager(
              episodes: episodes,
              selected: selected,
              video: SizedBox(
                key: videoKey,
                child: const Text('single decoder'),
              ),
              placeholder: (_, ep) {
                built++;
                return Center(child: Text('episode ${ep.number}'));
              },
              onSelect: (ep) => setState(() {
                selected = ep;
                changes++;
              }),
            ),
          ),
        ),
      ),
    );
    expect(find.byKey(videoKey), findsOneWidget);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(PageView)),
    );
    await gesture.moveBy(const Offset(0, -90));
    await tester.pump();
    expect(changes, 0);
    await gesture.up();
    await tester.pumpAndSettle();
    final before = changes;
    await tester.fling(find.byType(PageView), const Offset(0, -500), 1200);
    await tester.pumpAndSettle();
    expect(changes, greaterThan(before));
    expect(selected, greaterThan(1));
    expect(find.byKey(videoKey), findsOneWidget);
    expect(built, lessThan(12));
    expect(tester.takeException(), isNull);
  });
  testWidgets('episode picker builds visible entries instead of all 500', (
    tester,
  ) async {
    final episodes = List.generate(500, (i) => Episode(i + 1, ''));
    int? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Builder(
            builder: (context) => M3EButton(
              label: const Text('open episodes'),
              onPressed: () async {
                selected = await pickEpisode(context, episodes, 1);
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open episodes'));
    await tester.pumpAndSettle();
    expect(find.text('第 500 集'), findsNothing);
    expect(find.byType(M3EButton).evaluate().length, lessThan(40));
    await tester.tap(find.text('第 2 集'));
    await tester.pumpAndSettle();
    expect(selected, 2);
    expect(tester.takeException(), isNull);
  });
}
