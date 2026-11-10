import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;

import '../data/models.dart';
import '../data/repository.dart';
import 'design.dart';
import 'poster.dart';

/// Renders upstream text and images as native widgets. No HTML engine or scripts.
class RichContent extends StatelessWidget {
  const RichContent({
    required this.source,
    required this.repository,
    super.key,
  });
  final String source;
  final Repository repository;
  @override
  Widget build(BuildContext context) {
    final blocks = <Widget>[];
    final text = StringBuffer();
    void flush() {
      final value = text.toString().trim();
      text.clear();
      if (value.isNotEmpty) {
        blocks.add(
          SelectableText(
            value,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.8),
          ),
        );
      }
    }

    void visit(dom.Node node, int depth) {
      if (depth > 32 || blocks.length >= 200) return;
      if (node is dom.Text) {
        text.write(node.text);
        return;
      }
      if (node is! dom.Element) return;
      if ([
        'script',
        'style',
        'iframe',
        'object',
        'embed',
        'form',
      ].contains(node.localName)) {
        return;
      }
      if (node.localName == 'img') {
        flush();
        final src = node.attributes['data-src'] ?? node.attributes['src'] ?? '';
        final uri = Uri.tryParse(src);
        if (uri != null && ['https', 'http'].contains(uri.scheme)) {
          blocks.add(
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: SizedBox(
                height: 360,
                child: Poster(
                  repository: repository,
                  url: src,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          );
        }
        return;
      }
      if (['br', 'p', 'div', 'h1', 'h2', 'h3', 'li'].contains(node.localName)) {
        text.writeln();
      }
      for (final child in node.nodes) {
        visit(child, depth + 1);
      }
      if (['p', 'div', 'h1', 'h2', 'h3', 'li'].contains(node.localName)) {
        text.writeln();
      }
    }

    final root = parser.parseFragment(source);
    for (final child in root.nodes) {
      visit(child, 0);
    }
    flush();
    if (blocks.isEmpty) return Text(plainText(source));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 18,
      children: blocks,
    );
  }
}
