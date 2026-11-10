import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  PaintingBinding.instance.imageCache
    ..maximumSize = 96
    ..maximumSizeBytes = 32 * 1024 * 1024;
  runApp(const HGhubApp());
}
