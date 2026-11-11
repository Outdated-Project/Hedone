import '../data/repository.dart';
import 'design.dart';
import 'responsive_image.dart';

class Poster extends StatefulWidget {
  const Poster({
    required this.repository,
    required this.url,
    this.fit = BoxFit.cover,
    super.key,
  });
  final Repository repository;
  final String url;
  final BoxFit fit;
  @override
  State<Poster> createState() => _PosterState();
}

class _PosterState extends State<Poster> {
  Future<String>? _url;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(Poster old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || old.repository != widget.repository) _load();
  }

  void _load() {
    _url = widget.url.isEmpty
        ? null
        : widget.repository.mediaUrl(widget.url, image: true);
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: FutureBuilder<String>(
        future: _url,
        builder: (context, snapshot) {
          final placeholder = Center(
            child: Icon(
              Icons.movie_outlined,
              size: 36,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          );
          if (!snapshot.hasData) return placeholder;
          return LayoutBuilder(
            builder: (context, constraints) {
              final ratio = MediaQuery.devicePixelRatioOf(context);
              final width = decodeExtent(constraints.maxWidth, ratio, 2048);
              final height = decodeExtent(constraints.maxHeight, ratio, 3072);
              return Image(
                image: ResponsiveImage(
                  snapshot.data!,
                  width: width,
                  height: height,
                  maxPixels: constraints.maxWidth <= 280
                      ? 1024 * 1024
                      : 3 * 1024 * 1024,
                  fit: widget.fit,
                ),
                filterQuality: FilterQuality.medium,
                fit: widget.fit,
                width: double.infinity,
                height: double.infinity,
                excludeFromSemantics: true,
                errorBuilder: (_, error, stack) => placeholder,
              );
            },
          );
        },
      ),
    ),
  );
}

/// Quantization prevents a new decoded image for every pixel of window resize.
int decodeExtent(double logical, double ratio, int maximum) => logical.isFinite
    ? ((logical * ratio / 64).ceil() * 64).clamp(64, maximum)
    : maximum;

/// One artwork crosses the route boundary; textures and decoder surfaces are
/// never captured as a container-transform snapshot.
class PosterHero extends StatelessWidget {
  const PosterHero({
    required this.tag,
    required this.repository,
    required this.url,
    this.child,
    super.key,
  });
  final Object? tag;
  final Repository repository;
  final String url;
  final Widget? child;
  @override
  Widget build(BuildContext context) {
    final poster = Poster(repository: repository, url: url);
    return tag == null
        ? child ?? poster
        : Hero(
            tag: tag!,
            flightShuttleBuilder: (_, animation, direction, from, to) {
              // Hero has already laid out its endpoints. Element.size is not
              // legal inside this overlay builder; read the measured box.
              final box = from.findRenderObject();
              final size = box is RenderBox && box.hasSize
                  ? box.size
                  : const Size(256, 384);
              return ClipRRect(
                borderRadius: BorderRadius.circular(24),
                // Keep codec dimensions stable throughout a shared flight.
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: size.width,
                    height: size.height,
                    child: poster,
                  ),
                ),
              );
            },
            child: child ?? poster,
          );
  }
}
