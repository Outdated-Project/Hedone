import 'package:shared_preferences/shared_preferences.dart';

abstract interface class Preferences {
  Future<String?> getString(String key);
  Future<bool?> getBool(String key);
  Future<void> setString(String key, String value);
  Future<void> setBool(String key, bool value);
  Future<void> remove(String key);
}

final class DevicePreferences implements Preferences {
  final SharedPreferencesAsync _storage = SharedPreferencesAsync();
  @override
  Future<String?> getString(String key) => _storage.getString(key);
  @override
  Future<bool?> getBool(String key) => _storage.getBool(key);
  @override
  Future<void> setString(String key, String value) =>
      _storage.setString(key, value);
  @override
  Future<void> setBool(String key, bool value) => _storage.setBool(key, value);
  @override
  Future<void> remove(String key) => _storage.remove(key);
}
