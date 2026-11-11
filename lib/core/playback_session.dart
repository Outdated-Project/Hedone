import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../data/repository.dart';
import '../data/transport.dart';

/// One decoder per open detail page. All opens are ordered; obsolete loads are discarded.
class PlaybackSession extends ChangeNotifier with WidgetsBindingObserver {
  PlaybackSession(this.repository) {
    WidgetsBinding.instance.addObserver(this);
  }

  Player _createPlayer() {
    final instance = Player(
      configuration: const PlayerConfiguration(
        title: 'HGhub',
        bufferSize: 8 * 1024 * 1024,
        logLevel: bool.fromEnvironment('HGHUB_CAPTURE_DIAGNOSTICS')
            ? MPVLogLevel.debug
            : MPVLogLevel.error,
      ),
    );
    _created = true;
    _subscriptions.addAll([
      instance.stream.playing.listen((v) {
        if (!_acceptEvents) return;
        playing = v;
        _notify();
      }),
      instance.stream.buffering.listen((v) {
        if (!_acceptEvents) return;
        buffering = v;
        _notify();
      }),
      instance.stream.duration.listen((v) {
        if (!_acceptEvents) return;
        duration = v;
        _notify();
      }),
      instance.stream.position.listen((v) {
        if (!_acceptEvents) return;
        if ((v - position.value).abs().inMilliseconds >= 200) {
          position.value = v;
        }
      }),
      instance.stream.error.listen((v) {
        if (!_acceptEvents) return;
        if (v.isNotEmpty) {
          error = '视频解码或加载失败，请重试';
          _record('decoder_error', {'ep': episode});
          loading = false;
          _notify();
        }
      }),
      instance.stream.completed.listen((done) {
        if (done && _acceptEvents && !loading && error == null) {
          onCompleted?.call();
        }
      }),
    ]);
    return instance;
  }

  final Repository repository;
  bool _created = false;
  late final Player player = _createPlayer();
  late final VideoController video = VideoController(player);
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Future<void> _queue = Future.value();
  int _generation = 0;
  int _decoderGeneration = 0;
  bool get _acceptEvents => !_disposed && _decoderGeneration == _generation;
  bool _disposed = false, loading = false, playing = false, buffering = false;
  bool _foreground = true;
  bool _preparing = false;
  Duration duration = Duration.zero;
  String? error;
  int episode = 1;
  VoidCallback? onCompleted;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _record(String event, Map<String, dynamic> data) {
    if (kIsWeb || _disposed) return;
    unawaited(
      repository
          .call('log_write', {
            'entries': [
              {'event': event, 'data': data},
            ],
          })
          .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }

  Future<void> open(
    int id,
    int ep, {
    Duration resume = Duration.zero,
    String? directUrl,
    bool fresh = false,
  }) async {
    if (_disposed) return;
    final generation = ++_generation;
    _record('open', {'id': id, 'ep': ep});
    episode = ep;
    loading = true;
    playing = false;
    buffering = false;
    error = null;
    duration = Duration.zero;
    position.value = Duration.zero;
    _notify();
    try {
      await player.pause();
      if (_disposed || generation != _generation) return;
      final url = directUrl == null
          ? await repository.playbackUrl(id, ep, fresh: fresh)
          : await repository.mediaUrl(directUrl);
      if (_disposed || generation != _generation) return;
      _queue = _queue.catchError((Object _) {}).then((_) async {
        if (_disposed || generation != _generation) return;
        _decoderGeneration = generation;
        await player.open(Media(url), play: false);
        if (_disposed || generation != _generation) return;
        if (resume > Duration.zero) {
          final length = player.state.duration > Duration.zero
              ? player.state.duration
              : await player.stream.duration
                    .firstWhere((d) => d > Duration.zero)
                    .timeout(const Duration(seconds: 12));
          if (_disposed || generation != _generation) return;
          if (resume < length - const Duration(seconds: 3)) {
            await player.seek(resume);
          }
        }
        if (!_disposed && generation == _generation && _foreground) {
          await player.play();
        }
      });
      await _queue;
    } catch (e) {
      if (!_disposed && generation == _generation) error = errorMessage(e);
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        _notify();
      }
    }
  }

  /// Prepare at most one adjacent address; never allocate another decoder or
  /// fetch video segments speculatively. Failure is retried by an explicit open.
  Future<void> prepareNext(int id, int ep) async {
    if (_disposed || !_foreground || _preparing) return;
    _preparing = true;
    try {
      await repository.playbackUrl(id, ep);
    } catch (_) {
      // Speculation does not change the currently playing session.
    } finally {
      _preparing = false;
    }
  }

  Future<void> seek(Duration value) async {
    if (duration <= Duration.zero || loading) return;
    final ms = value.inMilliseconds.clamp(0, duration.inMilliseconds);
    await player.seek(Duration(milliseconds: ms));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground && _created && !_disposed) unawaited(player.pause());
  }

  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _queue.catchError((Object _) {});
    if (_created) await player.dispose();
    position.dispose();
    super.dispose();
  }
}
