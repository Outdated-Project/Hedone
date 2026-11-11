import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart'
    show ExternalLibrary;

import '../src/rust/frb_generated.dart';

/// Load the library shipped with this executable, never a stale Cargo output
/// relative to the working directory. Android resolves its packaged JNI library.
Future<void> initializeNativeRuntime() {
  final executableDirectory = File(Platform.resolvedExecutable).parent.uri;
  final path = switch (Platform.operatingSystem) {
    'windows' => executableDirectory.resolve('hghub_core.dll').toFilePath(),
    'linux' => executableDirectory.resolve('lib/libhghub_core.so').toFilePath(),
    'macos' =>
      executableDirectory
          .resolve('../Frameworks/hghub_core.framework/hghub_core')
          .toFilePath(),
    'ios' =>
      executableDirectory
          .resolve('Frameworks/hghub_core.framework/hghub_core')
          .toFilePath(),
    'android' => 'libhghub_core.so',
    _ => throw UnsupportedError('Unsupported native platform'),
  };
  return RustLib.init(externalLibrary: ExternalLibrary.open(path));
}
