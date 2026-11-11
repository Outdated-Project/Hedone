import 'package:flutter/widgets.dart';

import 'app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  PaintingBinding.instance.imageCache
    ..maximumSize = 96
    ..maximumSizeBytes = 32 * 1024 * 1024;
  runApp(const HedoneApp());
}
