import 'dart:async';

import '../core/playback_session.dart';
import 'design.dart';
import 'feedback.dart';

class PlaybackControls extends StatefulWidget {
  const PlaybackControls({
    required this.session,
    required this.episode,
    required this.onNext,
    required this.onFullscreen,
    required this.fullscreen,
    required this.onRetry,
    super.key,
  });
  final PlaybackSession session;
  final int episode;
  final VoidCallback? onNext;
  final VoidCallback onFullscreen, onRetry;
  final bool fullscreen;
  @override
  State<PlaybackControls> createState() => _PlaybackControlsState();
}

class _PlaybackControlsState extends State<PlaybackControls> {
  double? _drag;
  double get _rate => widget.session.player.state.rate;
  bool get _muted => widget.session.player.state.volume == 0;
  String _time(Duration d) =>
      '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) {
      final s = widget.session;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (s.loading || s.buffering)
              const SizedBox(
                height: 30,
                width: 30,
                child: M3ELoadingIndicator(),
              ),
            if (s.error != null)
              StatusPane(error: s.error, onRetry: widget.onRetry),
            ValueListenableBuilder<Duration>(
              valueListenable: s.position,
              builder: (context, position, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  M3ESlider(
                    value: (_drag ?? position.inMilliseconds.toDouble()).clamp(
                      0,
                      s.duration.inMilliseconds.toDouble().clamp(
                        1,
                        double.infinity,
                      ),
                    ),
                    max: s.duration.inMilliseconds.toDouble().clamp(
                      1,
                      double.infinity,
                    ),
                    enabled: !s.loading && s.duration > Duration.zero,
                    semanticLabel: '播放进度',
                    label: _time(
                      Duration(
                        milliseconds:
                            (_drag ?? position.inMilliseconds.toDouble())
                                .round(),
                      ),
                    ),
                    onChanged: (value) => setState(() => _drag = value),
                    onChangeEnd: (value) {
                      setState(() => _drag = null);
                      unawaited(
                        perform(
                          context,
                          () => s.seek(Duration(milliseconds: value.round())),
                        ),
                      );
                    },
                  ),
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    spacing: 16,
                    runSpacing: 4,
                    children: [
                      Text(
                        '${_time(position)} / ${_time(s.duration)}',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                      Text(
                        '第 ${widget.episode} 集',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                if (!widget.fullscreen)
                  M3EIconButton(
                    icon: const Icon(Icons.replay_10_rounded),
                    tooltip: '后退 10 秒',
                    onPressed: () => perform(
                      context,
                      () => s.seek(
                        s.position.value - const Duration(seconds: 10),
                      ),
                    ),
                    variant: M3EIconButtonVariant.tonal,
                  ),
                M3EIconButton(
                  icon: Icon(
                    s.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  ),
                  tooltip: s.playing ? '暂停' : '播放',
                  onPressed: s.loading
                      ? null
                      : () => perform(context, s.player.playOrPause),
                  size: M3EIconButtonSize.md,
                ),
                if (!widget.fullscreen)
                  M3EIconButton(
                    icon: const Icon(Icons.forward_10_rounded),
                    tooltip: '前进 10 秒',
                    onPressed: () => perform(
                      context,
                      () => s.seek(
                        s.position.value + const Duration(seconds: 10),
                      ),
                    ),
                    variant: M3EIconButtonVariant.tonal,
                  ),
                if (widget.onNext != null)
                  M3EIconButton(
                    icon: const Icon(Icons.skip_next_rounded),
                    tooltip: '下一集',
                    onPressed: widget.onNext,
                    variant: M3EIconButtonVariant.tonal,
                  ),
                M3EButton(
                  onPressed: () => perform(context, () async {
                    final rates = [0.75, 1.0, 1.25, 1.5, 2.0];
                    final next =
                        rates[(rates.indexOf(_rate) + 1) % rates.length];
                    await s.player.setRate(next);
                    if (mounted) setState(() {});
                  }),
                  label: Text('$_rate×'),
                  style: M3EButtonStyle.tonal,
                ),
                M3EIconButton(
                  icon: Icon(
                    _muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                  ),
                  tooltip: _muted ? '取消静音' : '静音',
                  onPressed: () => perform(context, () async {
                    await s.player.setVolume(_muted ? 100 : 0);
                    if (mounted) setState(() {});
                  }),
                  variant: M3EIconButtonVariant.tonal,
                ),
                M3EIconButton(
                  icon: Icon(
                    widget.fullscreen
                        ? Icons.fullscreen_exit_rounded
                        : Icons.fullscreen_rounded,
                  ),
                  tooltip: '切换影院模式',
                  onPressed: widget.onFullscreen,
                  variant: M3EIconButtonVariant.tonal,
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}
