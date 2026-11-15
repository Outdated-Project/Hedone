import 'dart:async';

import 'package:flutter/services.dart';

import '../core/playback_session.dart';
import 'app_theme.dart';
import 'design.dart';
import 'feedback.dart';
import 'playback_controls.dart';

/// Shared short-video interaction layer. The texture/pager never changes size
/// or parent when chrome fades, a menu opens, or the user scrubs the track.
class PlaybackSurface extends StatefulWidget {
  const PlaybackSurface({
    required this.session,
    required this.video,
    required this.episode,
    required this.onRetry,
    required this.onFullscreen,
    required this.fullscreen,
    this.header,
    this.onNext,
    super.key,
  });
  final PlaybackSession session;
  final Widget video;
  final Widget? header;
  final int episode;
  final VoidCallback onRetry, onFullscreen;
  final VoidCallback? onNext;
  final bool fullscreen;
  @override
  State<PlaybackSurface> createState() => _PlaybackSurfaceState();
}

class _PlaybackSurfaceState extends State<PlaybackSurface> {
  Timer? _hide;
  bool _chrome = true,
      _dragging = false,
      _accessible = false,
      _wasPlaying = false;
  @override
  void initState() {
    super.initState();
    widget.session.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _accessible = MediaQuery.accessibleNavigationOf(context);
    _arm();
  }

  @override
  void didUpdateWidget(PlaybackSurface old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      old.session.removeListener(_changed);
      widget.session.addListener(_changed);
      _wasPlaying = widget.session.playing;
      _reveal();
    }
    if (old.episode != widget.episode) _reveal();
  }

  void _changed() {
    final playing = widget.session.playing;
    if (!playing || widget.session.error != null) {
      _hide?.cancel();
      if (!_chrome && mounted) setState(() => _chrome = true);
    } else if (!_wasPlaying) {
      _arm();
    }
    _wasPlaying = playing;
  }

  void _arm() {
    _hide?.cancel();
    if (_accessible || _dragging || !widget.session.playing) return;
    _hide = Timer(const Duration(seconds: 3), () {
      if (mounted && !_dragging && widget.session.playing) {
        setState(() => _chrome = false);
      }
    });
  }

  void _reveal() {
    if (!mounted) return;
    if (!_chrome) setState(() => _chrome = true);
    _arm();
  }

  void _toggle() {
    _reveal();
    unawaited(perform(context, widget.session.togglePlayback));
  }

  @override
  void dispose() {
    _hide?.cancel();
    widget.session.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: AppTheme.dark,
    child: Builder(
      builder: (context) => AppTheme.scope(
        context,
        CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.space): _toggle,
            const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                unawaited(
                  perform(
                    context,
                    () => widget.session.seek(
                      widget.session.position.value -
                          const Duration(seconds: 10),
                    ),
                  ),
                ),
            const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                unawaited(
                  perform(
                    context,
                    () => widget.session.seek(
                      widget.session.position.value +
                          const Duration(seconds: 10),
                    ),
                  ),
                ),
          },
          child: Focus(
            autofocus: true,
            child: MouseRegion(
              onHover: (_) => _reveal(),
              child: ListenableBuilder(
                listenable: widget.session,
                builder: (context, _) {
                  final session = widget.session;
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      Semantics(
                        button: true,
                        label: session.playing ? '暂停视频' : '播放视频',
                        onTap: _toggle,
                        child: GestureDetector(
                          key: const ValueKey('playback-tap-surface'),
                          behavior: HitTestBehavior.opaque,
                          excludeFromSemantics: true,
                          onTap: _toggle,
                          onLongPress: _reveal,
                          child: widget.video,
                        ),
                      ),
                      if (session.error == null &&
                          !session.loading &&
                          !session.playing)
                        const IgnorePointer(
                          child: Center(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Color(0x55000000),
                                shape: BoxShape.circle,
                              ),
                              child: Padding(
                                padding: EdgeInsets.all(16),
                                child: Icon(
                                  Icons.play_arrow_rounded,
                                  size: 48,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (session.error == null &&
                          (session.loading || session.buffering))
                        const IgnorePointer(
                          child: Center(
                            child: SizedBox(
                              width: 28,
                              height: 28,
                              child: M3ELoadingIndicator(),
                            ),
                          ),
                        ),
                      if (session.error != null)
                        Center(
                          child: StatusPane(
                            error: session.error,
                            onRetry: widget.onRetry,
                          ),
                        ),
                      if (widget.header != null)
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: IgnorePointer(
                            ignoring: !_chrome,
                            child: ExcludeSemantics(
                              excluding: !_chrome,
                              child: AnimatedOpacity(
                                opacity: _chrome ? 1 : 0,
                                duration:
                                    MediaQuery.disableAnimationsOf(context)
                                    ? Duration.zero
                                    : const Duration(milliseconds: 180),
                                child: DecoratedBox(
                                  decoration: const BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Color(0xAA000000),
                                        Colors.transparent,
                                      ],
                                    ),
                                  ),
                                  child: widget.header,
                                ),
                              ),
                            ),
                          ),
                        ),
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        height: 88,
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.transparent,
                                  _chrome
                                      ? const Color(0x99000000)
                                      : Colors.transparent,
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: PlaybackControls(
                          session: session,
                          episode: widget.episode,
                          onNext: widget.onNext,
                          onFullscreen: widget.onFullscreen,
                          fullscreen: widget.fullscreen,
                          onRetry: widget.onRetry,
                          expanded: _chrome,
                          onActivity: _reveal,
                          onHide: () {
                            _hide?.cancel();
                            setState(() => _chrome = false);
                          },
                          onDraggingChanged: (dragging) {
                            _dragging = dragging;
                            _reveal();
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
