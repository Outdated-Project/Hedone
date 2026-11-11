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
  if (text.contains('no trusted root found')) {
    return '当前网络库无法验证该线路的证书链，请更换数据线路。证书校验不会关闭。';
  }
  if (text.contains('TLS certificate error')) {
    return '服务器证书验证失败。请检查设备日期、网络代理或更换数据线路。';
  }
  final status = RegExp(r'^HTTP\s+(\d{3})\b').firstMatch(text)?.group(1);
  if (status == '404') {
    return '当前线路的内容接口不可用（HTTP 404），请更换数据线路。';
  }
  if (status != null) {
    return '服务器返回 HTTP $status，请稍后重试或更换数据线路。';
  }
  if (text.contains('SocketException') || text.contains('ClientException')) {
    return '网络连接失败，请检查网络或服务地址';
  }
  if (text.contains('TimeoutException')) return '请求超时，请重试';
  return text.length > 220 ? '${text.substring(0, 220)}…' : text;
}
