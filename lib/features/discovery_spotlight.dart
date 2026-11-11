import '../core/app_model.dart';
import '../data/models.dart';
import '../ui/design.dart';
import '../ui/poster.dart';
import '../ui/haptics.dart';
import 'detail.dart';

/// Editorial surface backed exclusively by the current feed; no autoplay or
/// decorative blur/shader runs behind a scrolling catalogue.
class DiscoverySpotlight extends StatefulWidget {
  const DiscoverySpotlight({
    required this.model,
    required this.item,
    super.key,
  });
  final AppModel model;
  final VideoItem item;
  @override
  State<DiscoverySpotlight> createState() => _DiscoverySpotlightState();
}

class _DiscoverySpotlightState extends State<DiscoverySpotlight> {
  final _artwork = Object();
  bool _opening = false;
  Future<void> _open() async {
    if (_opening) return;
    _opening = true;
    AppHaptics.selection(context);
    try {
      await AuroraMotion.open(
        context,
        DetailScreen(
          model: widget.model,
          item: widget.item,
          heroTag: _artwork,
          autoplay: true,
          immersive: MediaQuery.sizeOf(context).width < 800,
        ),
      );
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(32),
          topRight: Radius.circular(32),
          bottomLeft: Radius.circular(32),
          bottomRight: Radius.circular(64),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: LayoutBuilder(
          builder: (context, size) {
            final width = (size.maxWidth * .38).clamp(72.0, 220.0);
            return Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.auto_awesome_rounded,
                        color: colors.onPrimaryContainer,
                        size: 26,
                      ),
                      const SizedBox(height: 14),
                      Text(
                        '今日放映',
                        style: text.labelLarge?.copyWith(
                          color: colors.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        widget.item.title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: text.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: colors.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '${widget.item.episodes} 集 · 从这部开始',
                        style: text.bodySmall?.copyWith(
                          color: colors.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(height: 20),
                      M3EButton(
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text('开始观看'),
                        onPressed: _open,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                SizedBox(
                  width: width,
                  height: width * 1.5,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: GestureDetector(
                      onTap: _open,
                      child: PosterHero(
                        tag: _artwork,
                        repository: widget.model.repository,
                        url: widget.item.cover,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
