import 'package:flutter/foundation.dart';

import '../data/models.dart';
import '../data/transport.dart';

/// Generation checks discard results from old filters without disturbing new loads.
class PagedController<T> extends ChangeNotifier {
  PagedController(this._load, {this.identity});
  final Future<PageResult<T>> Function(int page) _load;
  final Object Function(T)? identity;
  final Set<Object> _seen = {};
  final List<T> items = [];
  bool loading = false, hasMore = true, _disposed = false;
  String? error;
  int _page = 0, _generation = 0;
  Future<void> refresh() async {
    _generation++;
    _page = 0;
    items.clear();
    _seen.clear();
    hasMore = true;
    loading = false;
    await next();
  }

  Future<void> next() async {
    if (loading || !hasMore || _disposed) return;
    final generation = _generation;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final result = await _load(_page + 1);
      if (_disposed || generation != _generation) return;
      for (final item in result.items) {
        if (identity == null || _seen.add(identity!(item))) items.add(item);
      }
      // A page can be empty after recommendation deduplication while later
      // upstream pages still contain unseen results. Honor the source cursor.
      hasMore = result.hasMore;
      _page++;
    } catch (e) {
      if (!_disposed && generation == _generation) error = errorMessage(e);
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
