import 'design.dart';

/// The launcher artwork is much larger than an in-app mark. Decode it once at
/// the physical display size instead of retaining a full launcher-size bitmap.
class BrandMark extends StatelessWidget {
  const BrandMark({this.size = 48, super.key});
  final double size;
  @override
  Widget build(BuildContext context) {
    final pixels =
        ((size * MediaQuery.devicePixelRatioOf(context) / 32).ceil() * 32)
            .clamp(32, 512);
    return Image.asset(
      'assets/brand.png',
      width: size,
      height: size,
      cacheWidth: pixels,
      cacheHeight: pixels,
      excludeFromSemantics: true,
    );
  }
}
