import '../core/app_model.dart';
import '../data/models.dart';
import '../ui/design.dart';
import '../ui/poster.dart';
import 'detail.dart';

/// A single, static feature card. Discovery never autoplays a decoder.
class DiscoverySpotlight extends StatelessWidget {
  const DiscoverySpotlight({
    required this.model,
    required this.item,
    super.key,
  });
  final AppModel model;
  final VideoItem item;
  @override
  Widget build(BuildContext context) => M3ECard(
    variant: M3ECardVariant.filled,
    padding: const EdgeInsets.all(20),
    child: LayoutBuilder(
      builder: (context, size) {
        final width = (size.maxWidth * .33).clamp(84.0, 200.0);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: width,
              height: width * 1.5,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Poster(repository: model.repository, url: item.cover),
              ),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '从这部开始',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    item.title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${item.episodes} 集 · 上下滑动换集',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 20),
                  M3EButton(
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('沉浸观看'),
                    onPressed: () => AuroraMotion.open(
                      context,
                      DetailScreen(
                        model: model,
                        item: item,
                        autoplay: true,
                        immersive: true,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    ),
  );
}
