import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../ui/design.dart';
import '../ui/feedback.dart';

/// Long legal text belongs in an accessible, scrollable page, not a narrow
/// dialog. Render the bundled license verbatim; presentation adds no terms.
class LicenseScreen extends StatefulWidget {
  const LicenseScreen({required this.source, super.key});
  final String source;
  @override
  State<LicenseScreen> createState() => _LicenseScreenState();
}

class _LicenseScreenState extends State<LicenseScreen> {
  final _anchors = <String, GlobalKey>{};
  final _scroll = ScrollController();
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: const M3EAppBar.top(
      titleText: '许可证',
      automaticallyImplyLeading: true,
    ),
    body: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 48),
          child: MarkdownBody(
            data: widget.source,
            selectable: true,
            builders: {'h1': _Heading(_anchors), 'h2': _Heading(_anchors)},
            styleSheet: MarkdownStyleSheet(
              p: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.65),
              h1: Theme.of(context).textTheme.headlineMedium
                  ?.copyWith(height: 1.2),
              h2: Theme.of(context).textTheme.titleLarge,
              a: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                decoration: TextDecoration.underline,
              ),
              blockquote: Theme.of(context).textTheme.bodyMedium,
              blockquoteDecoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(16),
              ),
              blockquotePadding: const EdgeInsets.all(16),
              blockSpacing: 20,
              code: const TextStyle(
                fontFamily: 'Google Sans Code',
                fontFamilyFallback: ['Noto Sans SC'],
              ),
            ),
            onTapLink: (_, href, _) {
              if (href != null && href.startsWith('#')) {
                final target = _anchors[href.substring(1)]?.currentContext;
                if (target != null) {
                  Scrollable.ensureVisible(
                    target,
                    duration: AuroraMotion.duration(context),
                    curve: AuroraMotion.curve,
                  );
                }
                return;
              }
              final uri = href == null ? null : Uri.tryParse(href);
              if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
                return;
              }
              perform(context, () async {
                if (!await launchUrl(
                  uri,
                  mode: LaunchMode.externalApplication,
                )) {
                  throw StateError('无法打开此链接');
                }
              });
            },
          ),
        ),
      ),
    ),
  );
}

class _Heading extends MarkdownElementBuilder {
  _Heading(this.anchors);
  final Map<String, GlobalKey> anchors;
  @override
  bool isBlockElement() => true;
  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final slug = element.textContent
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s-]'), '')
        .replaceAll(RegExp(r'\s+'), '-');
    return Semantics(
      header: true,
      child: Padding(
        key: anchors.putIfAbsent(slug, () => GlobalKey()),
        padding: const EdgeInsets.only(top: 8),
        child: SelectableText(element.textContent, style: preferredStyle),
      ),
    );
  }
}
