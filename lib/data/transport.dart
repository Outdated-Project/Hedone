abstract interface class Transport {
  Future<Map<String, dynamic>> initialize();
  Future<dynamic> request(Map<String, dynamic> payload);
  Future<String> mediaUrl(String url, {required bool image});
  Future<void> persistSession();
  Future<void> clearSession();
  Future<void> connect(String key);
}

class ServiceConnectionRequired implements Exception {
  const ServiceConnectionRequired();
  @override
  String toString() => '连接你的 Rust 服务';
}

String errorMessage(Object error) {
  var text = error.toString().replaceFirst(
    RegExp(r'^(Exception|AnyhowException):\s*'),
    '',
  );
  if (text == '401') return '登录已过期，请重新登录';
  if (text.contains('SocketException') || text.contains('ClientException')) {
    return '网络连接失败，请检查网络或服务地址';
  }
  if (text.contains('TimeoutException')) return '请求超时，请重试';
  return text.length > 220 ? '${text.substring(0, 220)}…' : text;
}
