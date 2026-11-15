import 'dart:async';

import '../core/playback_session.dart';
import 'design.dart';
import 'feedback.dart';

/// A thin seek track with a full-size touch target. Options live in a sheet,
/// leaving the video viewport unchanged when controls disappear.
class PlaybackControls extends StatefulWidget {
  const PlaybackControls({
    required this.session,
    required this.episode,
    required this.onNext,
    required this.onFullscreen,
    required this.fullscreen,
    required this.onRetry,
    this.expanded = true,
    this.onActivity,
    this.onDraggingChanged,
    this.onHide,
    super.key,
  });
  final PlaybackSession session;
  final int episode;
  final VoidCallback? onNext, onActivity, onHide;
  final VoidCallback onFullscreen, onRetry;
  final ValueChanged<bool>? onDraggingChanged;
  final bool fullscreen, expanded;
  @override
  State<PlaybackControls> createState() => _PlaybackControlsState();
}

class _PlaybackControlsState extends State<PlaybackControls> {
  double? _drag;
  int? _dragEpisode;
  bool _cancelled = false;
  String _time(Duration value) {
    final seconds = value.inSeconds;
    final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
    return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _decoderInfo() => perform(context, () async {
    final info = await widget.session.decoderInfo();
    if (!mounted) return;
    final hardware = info['hwdec-current'];
    final status = info['backend'] == 'browser'
        ? '由浏览器管理硬件加速'
        : hardware == 'no'
        ? '软件解码 · 当前设备未启用此格式的硬件解码'
        : hardware == null || hardware.isEmpty || hardware == 'unavailable'
        ? '尚未获取解码器状态'
        : '硬件解码 · $hardware';
    await M3EDialog.show(
      context,
      dialog: M3EDialog(
        title: '播放信息',
        content: Text(
          [
            status,
            if (info['video-codec'] case final String codec) '编码：$codec',
            if (info['video-format'] case final String format) '格式：$format',
          ].join('\n'),
        ),
        actions: [
          M3EButton(
            onPressed: () => Navigator.pop(context),
            label: const Text('关闭'),
          ),
        ],
      ),
    );
  });

  Future<void> _options() async {
    widget.onActivity?.call();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, update) {
          final player = widget.session.player;
          Future<void> change(Future<void> Function() action) =>
              perform(context, () async {
                await action();
                if (context.mounted) update(() {});
              });
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('播放设置', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 20),
                  const Text('播放速度'),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final rate in [0.75, 1.0, 1.25, 1.5, 2.0])
                        M3EButton(
                          label: Text('$rate×'),
                          style: player.state.rate == rate
                              ? M3EButtonStyle.filled
                              : M3EButtonStyle.tonal,
                          onPressed: () => change(() => player.setRate(rate)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  M3EListItem(
                    headline: player.state.volume == 0 ? '取消静音' : '静音',
                    leading: Icon(
                      player.state.volume == 0
                          ? Icons.volume_off_rounded
                          : Icons.volume_up_rounded,
                    ),
                    onTap: () => change(
                      () =>
                          player.setVolume(player.state.volume == 0 ? 100 : 0),
                    ),
                  ),
                  M3EListItem(
                    headline: '播放信息',
                    leading: const Icon(Icons.info_outline_rounded),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      unawaited(_decoderInfo());
                    },
                  ),
                  M3EListItem(
                    headline: widget.fullscreen ? '退出全屏' : '全屏观看',
                    leading: Icon(
                      widget.fullscreen
                          ? Icons.fullscreen_exit_rounded
                          : Icons.fullscreen_rounded,
                    ),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      widget.onFullscreen();
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (mounted) widget.onActivity?.call();
  }

  void _update(double x, double width) {
    if (width <= 0) return;
    _dragEpisode = widget.session.episode;
    final max = widget.session.duration.inMilliseconds.toDouble();
    setState(() => _drag = (x / width).clamp(0, 1) * max);
  }

  void _commit() {
    final value = _drag;
    setState(() => _drag = null);
    widget.onDraggingChanged?.call(false);
    widget.onActivity?.call();
    if (!_cancelled &&
        value != null &&
        _dragEpisode == widget.session.episode) {
      unawaited(
        perform(
          context,
          () => widget.session.seek(Duration(milliseconds: value.round())),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) => ValueListenableBuilder<Duration>(
      valueListenable: widget.session.position,
      builder: (context, position, _) {
        final session = widget.session;
        final length = session.duration.inMilliseconds.toDouble();
        final value = (_drag ?? position.inMilliseconds.toDouble()).clamp(
          0.0,
          length,
        );
        final enabled = !session.loading && length > 0 && session.error == null;
        final expanded = widget.expanded || _drag != null;
        return SizedBox(
          height: 88,
          child: Stack(
            alignment: Alignment.bottomCenter,
            children: [
              Positioned(
                left: 12,
                right: 12,
                bottom: 32,
                child: IgnorePointer(
                  ignoring: !expanded,
                  child: ExcludeSemantics(
                    excluding: !expanded,
                    child: AnimatedOpacity(
                      opacity: expanded ? 1 : 0,
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 180),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${_time(Duration(milliseconds: value.round()))} / ${_time(session.duration)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(color: Colors.white),
                                ),
                                Text(
                                  '第 ${widget.episode} 集',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(color: Colors.white70),
                                ),
                              ],
                            ),
                          ),
                          if (widget.onNext != null)
                            IconButton(
                              onPressed: widget.onNext,
                              tooltip: '下一集',
                              icon: const Icon(Icons.skip_next_rounded),
                            ),
                          IconButton(
                            onPressed: _options,
                            tooltip: '播放设置',
                            icon: const Icon(Icons.more_horiz_rounded),
                          ),
                          if (widget.onHide != null)
                            IconButton(
                              onPressed: widget.onHide,
                              tooltip: '收起控制',
                              icon: const Icon(Icons.expand_more_rounded),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: LayoutBuilder(
                  builder: (context, constraints) => Semantics(
                    label: '播放进度',
                    slider: true,
                    enabled: enabled,
                    value:
                        '${_time(Duration(milliseconds: value.round()))} / ${_time(session.duration)}',
                    increasedValue: enabled
                        ? '${_time(Duration(milliseconds: (position.inMilliseconds + 10000).clamp(0, length.toInt())))} / ${_time(session.duration)}'
                        : null,
                    decreasedValue: enabled
                        ? '${_time(Duration(milliseconds: (position.inMilliseconds - 10000).clamp(0, length.toInt())))} / ${_time(session.duration)}'
                        : null,
                    onIncrease: enabled
                        ? () => unawaited(
                            perform(
                              context,
                              () => session.seek(
                                position + const Duration(seconds: 10),
                              ),
                            ),
                          )
                        : null,
                    onDecrease: enabled
                        ? () => unawaited(
                            perform(
                              context,
                              () => session.seek(
                                position - const Duration(seconds: 10),
                              ),
                            ),
                          )
                        : null,
                    child: Listener(
                      onPointerDown: (_) => _cancelled = false,
                      onPointerCancel: (_) {
                        _cancelled = true;
                        setState(() => _drag = null);
                        widget.onDraggingChanged?.call(false);
                      },
                      child: GestureDetector(
                        key: const ValueKey('playback-seek-track'),
                        behavior: HitTestBehavior.opaque,
                        excludeFromSemantics: true,
                        onTapUp: enabled
                            ? (event) {
                                _update(
                                  event.localPosition.dx,
                                  constraints.maxWidth,
                                );
                                _commit();
                              }
                            : null,
                        onHorizontalDragStart: enabled
                            ? (event) {
                                widget.onDraggingChanged?.call(true);
                                _update(
                                  event.localPosition.dx,
                                  constraints.maxWidth,
                                );
                              }
                            : null,
                        onHorizontalDragUpdate: enabled
                            ? (event) => _update(
                                event.localPosition.dx,
                                constraints.maxWidth,
                              )
                            : null,
                        onHorizontalDragEnd: enabled ? (_) => _commit() : null,
                        onHorizontalDragCancel: () {
                          setState(() => _drag = null);
                          widget.onDraggingChanged?.call(false);
                        },
                        child: SizedBox(
                          height: 32,
                          child: Center(
                            child: SizedBox(
                              width: double.infinity,
                              height: _drag == null ? 2 : 4,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(2),
                                child: Stack(
                                  children: [
                                    const Positioned.fill(
                                      child: ColoredBox(
                                        color: Color(0x55FFFFFF),
                                      ),
                                    ),
                                    FractionallySizedBox(
                                      widthFactor: length > 0
                                          ? value / length
                                          : 0,
                                      child: const ColoredBox(
                                        color: Colors.white,
                                        child: SizedBox.expand(),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}
