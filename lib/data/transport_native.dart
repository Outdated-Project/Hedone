import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../src/rust/bridge.dart' as bridge;
import '../src/rust/frb_generated.dart';
import 'transport.dart';

Transport createTransport() => NativeTransport();

class NativeTransport implements Transport {
  static const _storage = FlutterSecureStorage();
  static const _sessionKey = 'hghub.session.v2';
  static Future<void>? _rustReady;

  @override
  Future<Map<String, dynamic>> initialize() async {
    try {
      await (_rustReady ??= RustLib.init());
    } catch (_) {
      _rustReady = null;
      rethrow;
    }
    final directory = await getApplicationSupportDirectory();
    final saved = await _storage.read(key: _sessionKey);
    final boot = jsonDecode(
      await bridge.initialize(dataDir: directory.path, savedSession: saved),
    ) as Map<String, dynamic>;
    if (saved != null && boot['logged_in'] != true) {
      await _storage.delete(key: _sessionKey);
    }
    return boot;
  }

  @override
  Future<dynamic> request(Map<String, dynamic> payload) async =>
      jsonDecode(await bridge.request(payload: jsonEncode(payload)));

  @override
  Future<String> mediaUrl(String url, {required bool image}) =>
      bridge.mediaUrl(url: url, image: image);

  @override
  Future<void> persistSession() async {
    try {
      await _storage.write(
        key: _sessionKey,
        value: await bridge.sessionSnapshot(),
      );
    } catch (_) {
      await bridge.clearSession();
      rethrow;
    }
  }

  @override
  Future<void> clearSession() async {
    await _storage.delete(key: _sessionKey);
    await bridge.clearSession();
  }

  @override
  Future<void> connect(String key) async =>
      throw UnsupportedError('原生应用直接连接 Rust 核心');
}
