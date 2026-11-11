import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'design.dart';

class HapticScope extends InheritedWidget {
  const HapticScope({required this.enabled, required super.child, super.key});
  final bool enabled;
  @override
  bool updateShouldNotify(HapticScope oldWidget) =>
      oldWidget.enabled != enabled;
}

/// Semantic feedback only; scrolling and animation frames never vibrate.
abstract final class AppHaptics {
  static final Stopwatch _clock = Stopwatch()..start();
  static int _last = -100;
  static void selection(BuildContext context) {
    if (kIsWeb ||
        !(context.dependOnInheritedWidgetOfExactType<HapticScope>()?.enabled ??
            false)) {
      return;
    }
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    final now = _clock.elapsedMilliseconds;
    if (now - _last < 70) return;
    _last = now;
    unawaited(HapticFeedback.selectionClick().catchError((Object _) {}));
  }
}
