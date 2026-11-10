import 'models.dart';
import 'transport.dart';
import '../core/async_lru.dart';

class Repository {
  Repository(this.transport);
  final Transport transport;
  void Function()? onServiceExpired;
  final _urls = AsyncLru<String, String>(
    capacity: 128,
    ttl: const Duration(minutes: 5),
  );
  final _play = AsyncLru<(int, int), String>(
    capacity: 3,
    ttl: const Duration(seconds: 15),
  );
  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on ServiceConnectionRequired {
      onServiceExpired?.call();
      rethrow;
    }
  }

  Future<Json> call(String operation, [Json fields = const {}]) async {
    final value = await _guard(
      () => transport.request({'op': operation, ...fields}),
    );
    return value is List ? {'items': value} : object(value);
  }

  void invalidate() {
    _urls.clear();
    _play.clear();
  }

  Future<void> clearSession() => _guard(transport.clearSession);
  Future<String> mediaUrl(String raw, {bool image = false}) {
    final key = '$image:$raw';
    return _urls.obtain(
      key,
      () => _guard(() => transport.mediaUrl(raw, image: image)),
    );
  }

  Future<String> playbackUrl(int id, int ep, {bool fresh = false}) {
    final key = (id, ep);
    if (fresh) _play.remove(key);
    return _play.obtain(key, () async {
      final info = await call('play', {'id': id, 'ep': ep});
      final source = string(info['video_url']);
      if (source.isEmpty) throw StateError('上游没有返回可播放的地址');
      return mediaUrl(source);
    });
  }

  Future<VideoDetail> detail(int id) async =>
      VideoDetail.fromJson(await call('video', {'id': id}));
  Future<PageResult<VideoItem>> videos(
    String op,
    int page, {
    Json fields = const {},
  }) async {
    final dynamic raw = await _guard(
      () => transport.request({
        'op': op,
        if (op != 'rank') ...{'page': page, 'size': 24},
        ...fields,
      }),
    );
    final value = object(raw);
    final items = objects(raw is List ? raw : value['items'])
        .map(VideoItem.fromJson)
        .where((v) => v.id > 0)
        .toList();
    final pagination = object(value['pagination']);
    return PageResult(
      items,
      op != 'rank' &&
          (pagination.containsKey('pages')
              ? page < number(pagination['pages'])
              : items.length == 24),
    );
  }
}
