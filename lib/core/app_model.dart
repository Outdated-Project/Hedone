import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'preferences.dart';
import 'recommendations.dart';

import '../data/models.dart';
import '../data/repository.dart';

class AppModel extends ChangeNotifier {
  AppModel(this.repository, this.preferences) {
    repository.onServiceExpired = () {
      if (serviceExpired) return;
      serviceExpired = true;
      user = null;
      repository.invalidate();
      identityRevision++;
      notifyListeners();
    };
  }
  final Repository repository;
  final Preferences preferences;
  Json? user;
  String base = '', theme = 'system';
  bool reducedMotion = false;
  bool haptics = true;
  final recommendations = RecommendationProfile();
  bool serviceExpired = false;
  final List<WatchEntry> history = [];
  final Map<int, VideoItem> favorites = {};
  int identityRevision = 0;
  bool _accountBusy = false;
  Future<void> _writes = Future.value();
  String get _scope => Uri.encodeComponent(base);
  bool get accountBusy => _accountBusy;

  Future<void> initialize() async {
    final boot = await repository.transport.initialize();
    serviceExpired = false;
    user = boot['user'] is Json ? boot['user'] as Json : null;
    base = string(boot['base']);
    theme = await preferences.getString('theme') ?? 'system';
    reducedMotion = await preferences.getBool('reducedMotion') ?? false;
    haptics = await preferences.getBool('haptics') ?? true;
    await _readLibrary();
    notifyListeners();
  }

  Future<void> _readLibrary() async {
    history.clear();
    favorites.clear();
    recommendations.clear();
    try {
      final saved = await preferences.getString('library.$_scope');
      final value = saved == null
          ? <String, dynamic>{}
          : object(jsonDecode(saved));
      recommendations.restore(object(value['recommendations']));
      history.addAll(
        objects(value['history']).take(100).map(WatchEntry.fromJson),
      );
      for (final json in objects(value['favorites']).take(500)) {
        final v = VideoItem.fromJson(json);
        if (v.id > 0) favorites[v.id] = v;
      }
    } on FormatException {
      await preferences.remove('library.$_scope');
    }
  }

  Future<void> saveLibrary() {
    final key = 'library.$_scope';
    final data = jsonEncode({
      'history': history.map((e) => e.toJson()).toList(),
      'favorites': favorites.values.map((e) => e.toJson()).toList(),
      'recommendations': recommendations.toJson(),
    });
    final next = _writes
        .catchError((Object _) {})
        .then((_) => preferences.setString(key, data));
    _writes = next;
    return next;
  }

  Future<void> remember(WatchEntry entry) async {
    recommendations.watch(entry.video, entry.positionMs);
    history.removeWhere((e) => e.video.id == entry.video.id);
    history.insert(0, entry);
    if (history.length > 100) history.removeLast();
    await saveLibrary();
    notifyListeners();
  }

  Future<void> setFavorite(VideoItem item, bool on) async {
    if (user != null) {
      await repository.call('collect', {'id': item.id, 'on': on});
    }
    if (on) {
      favorites[item.id] = item;
    } else {
      favorites.remove(item.id);
    }
    await saveLibrary();
    notifyListeners();
  }

  Future<void> clearHistory() async {
    history.clear();
    recommendations.clear();
    await saveLibrary();
    notifyListeners();
  }

  Future<void> authenticate(
    String name,
    String password, {
    String? email,
  }) async {
    if (_accountBusy) return;
    _accountBusy = true;
    notifyListeners();
    try {
      final response = await repository.call(
        email == null ? 'login' : 'register',
        {
          'username': name.trim(),
          'password': password,
          if (email != null) 'email': email.trim(),
        },
      );
      await repository.transport.persistSession();
      user = object(response['user']);
      identityRevision++;
    } finally {
      _accountBusy = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    if (_accountBusy) return;
    _accountBusy = true;
    notifyListeners();
    try {
      // Remove persisted credentials before publishing a signed-out state.
      await repository.clearSession();
      user = null;
      identityRevision++;
      repository.invalidate();
    } finally {
      _accountBusy = false;
      notifyListeners();
    }
  }

  Future<void> setLine(String url) async {
    if (_accountBusy) throw StateError('账号操作正在进行，请稍后切换线路');
    _accountBusy = true;
    notifyListeners();
    try {
      await repository.clearSession();
      user = null;
      identityRevision++;
      repository.invalidate();
      final result = await repository.call('line_set', {'url': url});
      base = string(result['base']);
      await _readLibrary();
    } finally {
      _accountBusy = false;
      notifyListeners();
    }
  }

  Future<void> setTheme(String mode) async {
    await preferences.setString('theme', mode);
    theme = mode;
    notifyListeners();
  }

  Future<void> setReducedMotion(bool enabled) async {
    await preferences.setBool('reducedMotion', enabled);
    reducedMotion = enabled;
    notifyListeners();
  }

  Future<void> rememberSearch(String query) async {
    recommendations.search(query);
    await saveLibrary();
  }

  Future<void> setHaptics(bool enabled) async {
    await preferences.setBool('haptics', enabled);
    haptics = enabled;
    notifyListeners();
  }

  @override
  void dispose() {
    repository.onServiceExpired = null;
    super.dispose();
  }
}
