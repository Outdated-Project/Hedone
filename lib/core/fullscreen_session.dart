import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'fullscreen_status.dart';

/// Owns platform presentation separately from the video decoder and page layout.
class FullscreenSession {
  bool _active = false;
  bool get active => kIsWeb ? browserFullscreenActive : _active;
  Future<void> _pending = Future.value();
  bool _closed = false;

  Future<void> set(bool enabled) {
    _pending = _pending.catchError((Object _) {}).then((_) async {
      final target = enabled && !_closed;
      if (active == target) return;
      if (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS)) {
        await SystemChrome.setEnabledSystemUIMode(
          target ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
        );
        // Let the sensor choose portrait or landscape; short dramas must not
        // be forcibly rotated merely because the user requested fullscreen.
        await SystemChrome.setPreferredOrientations([]);
      } else if (target) {
        await defaultEnterNativeFullscreen();
      } else {
        await defaultExitNativeFullscreen();
      }
      _active = target;
    });
    return _pending;
  }

  Future<void> close() {
    _closed = true;
    return set(false);
  }
}
