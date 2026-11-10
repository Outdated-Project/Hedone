import '../data/repository.dart';
import 'design.dart';

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
              final ratio = MediaQuery.devicePixelRatioOf(context)
                  .clamp(1.0, 3.0);
              final width = decodeExtent(constraints.maxWidth, ratio, 768);
              final height = decodeExtent(constraints.maxHeight, ratio, 1280);
              return Image(
                image: ResizeImage(
                  NetworkImage(snapshot.data!),
                  width: width,
                  height: height,
                  policy: ResizeImagePolicy.fit,
                ),
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
