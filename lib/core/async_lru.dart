/// Coalesces identical requests; evicts least recently used entries in O(1).
/// Expiration starts when the result arrives. Invalidated work cannot return
/// to the cache or remove a newer request with the same key.
class AsyncLru<K, V> {
  AsyncLru({
    required this.capacity,
    required this.ttl,
    DateTime Function()? now,
  }) : assert(capacity > 0),
       _now = now ?? DateTime.now;
  final int capacity;
  final Duration ttl;
  final DateTime Function() _now;
  // Dart's default map preserves insertion order (LinkedHashMap).
  final _entries = <K, _Entry<V>>{};

  Future<V> obtain(K key, Future<V> Function() load) {
    final existing = _entries.remove(key);
    if (existing != null &&
        (existing.expires == null || _now().isBefore(existing.expires!))) {
      _entries[key] = existing;
      return existing.future;
    }
    final entry = _Entry<V>(Future<V>.sync(load));
    _entries[key] = entry;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
    entry.future.then<void>(
      (_) {
        entry.expires = _now().add(ttl);
      },
      onError: (Object _, StackTrace _) {
        if (identical(_entries[key], entry)) _entries.remove(key);
      },
    );
    return entry.future;
  }

  void remove(K key) => _entries.remove(key);
  void clear() => _entries.clear();
}

class _Entry<V> {
  _Entry(this.future);
  final Future<V> future;
  DateTime? expires;
}
