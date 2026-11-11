import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

ui.TargetImageSize coverDecodeSize(
  int sourceWidth,
  int sourceHeight,
  int width,
  int height,
  int maxPixels,
  BoxFit fit,
) {
  final x = width / sourceWidth, y = height / sourceHeight;
  final requested = fit == BoxFit.cover ? math.max(x, y) : math.min(x, y);
  final scale = math.min(
    1.0,
    math.min(requested, math.sqrt(maxPixels / (sourceWidth * sourceHeight))),
  );
  return ui.TargetImageSize(
    width: math.max(1, (sourceWidth * scale).floor()),
    height: math.max(1, (sourceHeight * scale).floor()),
  );
}

@immutable
class ResponsiveImage extends ImageProvider<ResponsiveImage> {
  const ResponsiveImage(
    this.url, {
    required this.width,
    required this.height,
    required this.maxPixels,
    required this.fit,
  });
  final String url;
  final int width, height, maxPixels;
  final BoxFit fit;
  @override
  Future<ResponsiveImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(
    ResponsiveImage key,
    ImageDecoderCallback decode,
  ) {
    final source = NetworkImage(url);
    // Delegate HTTP/platform loading, replacing only codec target sizing.
    // ignore: invalid_use_of_protected_member
    final completer = source.loadImage(
      source,
      (buffer, {getTargetSize}) => decode(
        buffer,
        getTargetSize: (w, h) =>
            coverDecodeSize(w, h, width, height, maxPixels, fit),
      ),
    );
    completer.addEphemeralErrorListener((error, stack) {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
    });
    return completer;
  }

  @override
  bool operator ==(Object other) =>
      other is ResponsiveImage &&
      url == other.url &&
      width == other.width &&
      height == other.height &&
      maxPixels == other.maxPixels &&
      fit == other.fit;
  @override
  int get hashCode => Object.hash(url, width, height, maxPixels, fit);
}
