import 'dart:convert';

import 'package:http/browser_client.dart';

import 'transport.dart';

Transport createTransport() => WebTransport();

class WebTransport implements Transport {
  final BrowserClient _client = BrowserClient()..withCredentials = true;
  String _csrf = '';

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final response = await _client
        .post(
          Uri.base.resolve('/api/$path'),
          headers: {'content-type': 'application/json', 'x-hg-csrf': _csrf},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 75));
    if (response.statusCode == 401) throw const ServiceConnectionRequired();
    final dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw Exception('Rust 服务响应无效，请检查同源部署配置');
    }
    final value = decoded is Map<String, dynamic>
        ? decoded
        : <String, dynamic>{'items': decoded};
    if (response.statusCode >= 400) {
      throw Exception(value['error'] ?? '服务请求失败（${response.statusCode}）');
    }
    return value;
  }

  @override
  Future<Map<String, dynamic>> initialize() async {
    final value = await _post('bootstrap', {});
    _csrf = value['csrf'] as String;
    return value['boot'] as Map<String, dynamic>;
  }

  @override
  Future<void> connect(String key) async {
    final value = await _post('connect', {'key': key});
    _csrf = value['csrf'] as String;
  }

  @override
  Future<dynamic> request(Map<String, dynamic> payload) =>
      _post('request', payload);

  @override
  Future<String> mediaUrl(String url, {required bool image}) async =>
      (await _post('media', {'url': url, 'image': image}))['url'] as String;

  @override
  Future<void> persistSession() async {} // HttpOnly cookie; upstream credentials stay in Rust.

  @override
  Future<void> clearSession() async {
    await request({'op': 'logout'});
  }
}
