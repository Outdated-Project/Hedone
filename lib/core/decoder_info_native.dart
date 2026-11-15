import 'package:media_kit/media_kit.dart';

Future<Map<String, String>> readDecoderInfo(Player player) async {
  final backend = player.platform;
  if (backend is! NativePlayer) return {'backend': 'unavailable'};
  final info = <String, String>{'backend': 'mpv'};
  for (final property in ['hwdec-current', 'video-codec', 'video-format']) {
    try {
      info[property] = await backend.getProperty(property);
    } catch (_) {
      info[property] = 'unavailable';
    }
  }
  return info;
}
