import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../data/repository.dart';
import '../data/transport.dart';
import 'decoder_info.dart';

/// One decoder per open detail page. All opens are ordered; obsolete loads are discarded.
class PlaybackSession extends ChangeNotifier with WidgetsBindingObserver {
  PlaybackSession(this.repository, {this.playerFactory, this.prepareVideo}) {
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground =
        state == null ||
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    WidgetsBinding.instance.addObserver(this);
  }

  Player _createPlayer() {
    // Media dependencies should not prevent the catalogue or settings from
    // opening. Initialization errors are handled by the playback operation.
    if (playerFactory == null) MediaKit.ensureInitialized();
    final instance =
        playerFactory?.call() ??
        Player(
          configuration: const PlayerConfiguration(
            title: 'Hedone',
            bufferSize: 8 * 1024 * 1024,
            logLevel: bool.fromEnvironment('HEDONE_CAPTURE_DIAGNOSTICS')
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
        _validateResume(v);
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
        if (done &&
            _acceptEvents &&
            !loading &&
            !_resettingResume &&
            error == null &&
            _mayPlay &&
            _wantsPlayback) {
          onCompleted?.call();
        }
      }),
    ]);
    return instance;
  }

  final Repository repository;

  /// Optional backend/output injection for deterministic lifecycle tests.
  final Player Function()? playerFactory;
  final Future<void> Function()? prepareVideo;
  Future<void>? _videoReady;
  bool _created = false;
  late final Player player = _createPlayer();
  VideoController? _video;
  VideoController? get videoIfCreated => _video;
  VideoController get video => _video ??= VideoController(
    player,
    configuration: const VideoControllerConfiguration(
      enableHardwareAcceleration: true,
      hwdec: 'auto-safe',
    ),
  );

  /// Actual backend state; requesting hardware decoding alone is not proof.
  Future<Map<String, String>> decoderInfo() async {
    if (!_created || _disposed) return {'backend': 'idle'};
    return readDecoderInfo(player);
  }

  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Future<void> _queue = Future.value();
  int _generation = 0;
  int _decoderGeneration = 0;
  bool get _acceptEvents => !_disposed && _decoderGeneration == _generation;
  bool _disposed = false, loading = false, playing = false, buffering = false;
  bool _foreground = true, _routeVisible = true, _wantsPlayback = false;
  bool get _mayPlay => _foreground && _routeVisible && !_disposed;
  bool _preparing = false;
  Duration? _resumePosition;
  bool _resettingResume = false;
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
    final started = Stopwatch()..start();
    _wantsPlayback = _mayPlay;
    _record('open', {'id': id, 'ep': ep});
    episode = ep;
    loading = true;
    playing = false;
    buffering = false;
    error = null;
    _resumePosition = null;
    _resettingResume = false;
    duration = Duration.zero;
    position.value = Duration.zero;
    _notify();
    try {
      // DNS/API resolution and video output initialization are independent.
      // Attach handlers to both futures immediately, including failed lookups.
      final source = directUrl == null
          ? repository.playbackUrl(id, ep, fresh: fresh)
          : repository.mediaUrl(directUrl);
      final prepared = await Future.wait<Object?>([
        source,
        _prepareOutput(),
      ], eagerError: true);
      final url = prepared.first! as String;
      if (_disposed || generation != _generation) return;
      _queue = _queue.catchError((Object _) {}).then((_) async {
        if (_disposed || generation != _generation) return;
        _decoderGeneration = generation;
        _resumePosition = resume > Duration.zero ? resume : null;
        await player.open(
          Media(url, start: resume > Duration.zero ? resume : null),
          play: false,
        );
        if (_disposed || generation != _generation) return;
        _validateResume(player.state.duration);
        if (generation == _generation && _mayPlay && _wantsPlayback) {
          await player.play();
          if (generation != _generation || !_mayPlay || !_wantsPlayback) {
            await player.pause();
          }
        }
        _record('open_ready', {
          'ep': ep,
          'elapsed_ms': started.elapsedMilliseconds,
        });
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

  Future<void> _prepareOutput() async {
    await (_videoReady ??=
        prepareVideo?.call() ?? video.platform.future.then<void>((_) {}));
    if (!_disposed) {
      _notify();
      await player.pause();
    }
  }

  void _validateResume(Duration length) {
    final resume = _resumePosition;
    if (resume == null || length <= Duration.zero) return;
    _resumePosition = null;
    if (resume < length - const Duration(seconds: 3)) return;
    final generation = _generation;
    _resettingResume = true;
    // Metadata may arrive after open returns. Correct a completed watch record
    // without holding every other video's startup behind a duration timeout.
    _queue = _queue.catchError((Object _) {}).then((_) async {
      if (_disposed || generation != _generation) return;
      try {
        await player.seek(Duration.zero);
        if (generation == _generation && _mayPlay && _wantsPlayback) {
          await player.play();
          if (generation != _generation || !_mayPlay || !_wantsPlayback) {
            await player.pause();
          }
        }
      } catch (e) {
        if (!_disposed && generation == _generation) error = errorMessage(e);
      } finally {
        if (!_disposed && generation == _generation) {
          _resettingResume = false;
          _notify();
        }
      }
    });
  }

  Future<void> pause() async {
    _wantsPlayback = false;
    if (_created && !_disposed) await player.pause();
  }

  Future<void> togglePlayback() async {
    if (!_mayPlay) return;
    if (loading ? _wantsPlayback : playing) {
      await pause();
    } else {
      _wantsPlayback = true;
      if (!loading) {
        await player.play();
        if (!_mayPlay || !_wantsPlayback) await player.pause();
      }
    }
  }

  void setRouteVisible(bool visible) {
    _routeVisible = visible;
    if (!visible) _pauseForVisibility();
  }

  void _pauseForVisibility() {
    // Visibility loss also cancels autoplay for a request still in flight.
    unawaited(
      pause().catchError((Object _) {
        _record('pause_failed', {'ep': episode});
      }),
    );
  }

  /// Prepare at most one adjacent address; never allocate another decoder or
  /// fetch video segments speculatively. Failure is retried by an explicit open.
  Future<void> prepareNext(int id, int ep) async {
    if (!_mayPlay || _preparing) return;
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
    if (state == AppLifecycleState.inactive) return;
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) _pauseForVisibility();
  }

  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    try {
      await _videoReady;
    } catch (_) {
      // Failed initialization still needs to release the allocated player.
    }
    await _queue.catchError((Object _) {});
    if (_created) await player.dispose();
    position.dispose();
    super.dispose();
  }
}
