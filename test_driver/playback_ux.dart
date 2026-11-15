import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  final output = Directory('build/playback-ux');
  await output.create(recursive: true);
  await integrationDriver(
    writeResponseOnFailure: true,
    onScreenshot: (name, bytes, [args]) async {
      if (!RegExp(r'^[a-z-]+$').hasMatch(name)) return false;
      await File('${output.path}/$name.png').writeAsBytes(bytes);
      return bytes.isNotEmpty;
    },
    responseDataCallback: (data) async {
      final report = Map<String, dynamic>.from(data ?? {})
        ..remove('screenshots');
      await File('${output.path}/report.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    },
  );
}
