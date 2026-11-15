import 'dart:async';

import 'package:hedone/core/playback_session.dart';
import 'package:hedone/data/repository.dart';
import 'package:hedone/data/transport.dart';
import 'package:media_kit/media_kit.dart';

/// Test backend only: controllable completions expose races without a decoder.
class PlaybackBackend extends PlatformPlayer {
  PlaybackBackend() : super(configuration: const PlayerConfiguration());
  final opened = <Media>[];
  final seeks = <Duration>[];
  int plays = 0, pauses = 0;
  bool disposed = false;
  Completer<void>? opening;

  void playing(bool value) {
    state = state.copyWith(playing: value);
    playingController.add(value);
  }

  void duration(Duration value) {
    state = state.copyWith(duration: value);
    durationController.add(value);
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opened.add(playable as Media);
    playing(false);
    duration(Duration.zero);
    await opening?.future;
    if (play) await this.play();
  }

  @override
  Future<void> play() async {
    plays++;
    playing(true);
  }

  @override
  Future<void> pause() async {
    pauses++;
    playing(false);
  }

  @override
  Future<void> seek(Duration value) async {
    seeks.add(value);
    state = state.copyWith(position: value);
    positionController.add(value);
  }

  @override
  Future<void> setRate(double rate) async {
    state = state.copyWith(rate: rate);
  }

  @override
  Future<void> setVolume(double volume) async {
    state = state.copyWith(volume: volume);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await super.dispose();
  }
}

class PlaybackTransport implements Transport {
  final requested = <int>[];
  final pending = <int, Completer<String>>{};
  @override
  Future<dynamic> request(Map<String, dynamic> payload) async {
    if (payload['op'] != 'play') return <String, dynamic>{};
    final ep = payload['ep'] as int;
    requested.add(ep);
    return {
      'video_url':
          await (pending[ep]?.future ??
              Future.value('https://example.com/test-$ep.mp4')),
    };
  }

  @override
  Future<String> mediaUrl(String url, {required bool image}) async => url;
  @override
  Future<Map<String, dynamic>> initialize() async => {};
  @override
  Future<void> clearSession() async {}
  @override
  Future<void> persistSession() async {}
  @override
  Future<void> connect(String key) async {}
}

PlaybackSession playbackSession(
  PlaybackBackend backend, {
  PlaybackTransport? transport,
  Future<void> Function()? prepareVideo,
}) => PlaybackSession(
  Repository(transport ?? PlaybackTransport()),
  playerFactory: () => Player(platformPlayer: backend),
  prepareVideo: prepareVideo ?? () async {},
);
