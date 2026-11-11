import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:hedone/features/license.dart';
import 'package:hedone/ui/design.dart';

import 'settings_test.dart' show mount, capture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String source;
  setUpAll(() async {
    source = await rootBundle.loadString('LICENSE');
    for (final entry in {
      'Google Sans': 'assets/fonts/googlesans.ttf',
      'Noto Sans SC': 'assets/fonts/notosanssc.ttf',
    }.entries) {
      await (FontLoader(
        entry.key,
      )..addFont(rootBundle.load(entry.value))).load();
    }
  });
  for (final width in [320.0, 390.0, 1440.0]) {
    testWidgets(
      'license renders markdown at $width without raw heading syntax',
      (tester) async {
        final boundary = GlobalKey();
        await mount(
          tester,
          LicenseScreen(source: source),
          width: width,
          boundary: boundary,
        );
        await tester.pumpAndSettle();
        expect(find.byType(MarkdownBody), findsOneWidget);
        expect(
          find.textContaining('# PolyForm', findRichText: true),
          findsNothing,
        );
        expect(
          find.textContaining('PolyForm Noncommercial', findRichText: true),
          findsWidgets,
        );
        expect(tester.takeException(), isNull);
        await capture(tester, boundary, 'license-${width.toInt()}');
        tester
            .widget<MarkdownBody>(find.byType(MarkdownBody))
            .onTapLink
            ?.call('Distribution License', '#distribution-license', '');
        await tester.pumpAndSettle();
        expect(
          tester
              .state<ScrollableState>(find.byType(Scrollable).first)
              .position
              .pixels,
          greaterThan(0),
        );
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -600));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
}
