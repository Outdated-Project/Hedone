import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/fullscreen_session.dart';
import '../ui/cinema_layout.dart';

import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/app_model.dart';
import '../core/playback_session.dart';
import '../data/models.dart';
import '../ui/design.dart';
import '../ui/feedback.dart';
import '../ui/poster.dart';
import '../ui/episode_pager.dart';
import '../ui/episode_picker.dart';
import '../ui/app_theme.dart';
import '../ui/playback_controls.dart';
import 'account.dart';
import 'comments.dart';

class DetailScreen extends StatefulWidget {
  const DetailScreen({
    required this.model,
    required this.item,
    this.autoplay = false,
    this.immersive = false,
    super.key,
  });
  final AppModel model;
  final VideoItem item;
  final bool autoplay, immersive;
  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  late Future<VideoDetail> _detail;
  late final PlaybackSession _session;
  VideoDetail? _loaded;
  bool _started = false,
      _busy = false,
      _liked = false,
      _remoteCollected = false,
      _following = false,
      _fullscreen = false;
  Timer? _historyTimer;
  int _episode = 1;
  int? _preparedFor;
  final _videoKey = GlobalKey();
  final _presentation = FullscreenSession();
  Future<void> _setFullscreen(bool value) async {
    await perform(context, () async {
      await _presentation.set(value);
      if (mounted) setState(() => _fullscreen = value);
    });
  }

  int _identity = 0, _loadGeneration = 0;
  bool get _collected => widget.model.user == null
      ? widget.model.favorites.containsKey(widget.item.id)
      : _remoteCollected;
  @override
  void initState() {
    super.initState();
    _identity = widget.model.identityRevision;
    widget.model.addListener(_identityChanged);
    _fullscreen = widget.immersive;
    if (_fullscreen && !kIsWeb) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_setFullscreen(true));
      });
    }
    _detail = _fetch();
    _session = PlaybackSession(widget.model.repository)..onCompleted = _next;
    _session.position.addListener(_prepareFollowing);
  }

  Future<VideoDetail> _fetch() async {
    final generation = ++_loadGeneration;
    final detail = await widget.model.repository.detail(widget.item.id);
    if (mounted && generation == _loadGeneration) {
      _loaded = detail;
      _liked = detail.liked;
      _remoteCollected = detail.collected;
      _following = detail.author['is_following'] == true;
      if (widget.autoplay && !_started) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_started) {
            unawaited(
              _play(detail.episodes.firstOrNull?.number ?? 1, resume: true),
            );
          }
        });
      }
    }
    return detail;
  }

  void _identityChanged() {
    if (widget.model.serviceExpired) return;
    if (_identity == widget.model.identityRevision) return;
    _identity = widget.model.identityRevision;
    setState(() => _detail = _fetch());
  }

  Future<void> _play(int ep, {bool resume = false, bool fresh = false}) async {
    _preparedFor = null;
    unawaited(_save());
    if (!mounted) return;
    var position = Duration.zero;
    if (resume) {
      for (final entry in widget.model.history) {
        if (entry.video.id == widget.item.id) {
          if (_loaded?.episodePositions.containsKey(entry.episode) == true) {
            ep = entry.episode;
            position = Duration(milliseconds: entry.positionMs);
          }
          break;
        }
      }
    }
    setState(() {
      _started = true;
      _episode = ep;
    });
    _historyTimer ??= Timer.periodic(const Duration(seconds: 15), (_) {
      if (_session.playing) unawaited(_save());
    });
    await _session.open(widget.item.id, ep, resume: position, fresh: fresh);
  }

  void _prepareFollowing() {
    if (_session.loading ||
        _session.error != null ||
        !_session.playing ||
        _session.duration <= Duration.zero ||
        _preparedFor == _episode ||
        _session.duration - _session.position.value >
            const Duration(seconds: 12)) {
      return;
    }
    final index = _loaded?.episodePositions[_episode];
    if (index != null && index + 1 < _loaded!.episodes.length) {
      _preparedFor = _episode;
      unawaited(
        _session.prepareNext(
          widget.item.id,
          _loaded!.episodes[index + 1].number,
        ),
      );
    }
  }

  Future<void> _save() async {
    if (!_started ||
        _session.loading ||
        _session.error != null ||
        _session.position.value <= Duration.zero) {
      return;
    }
    try {
      await widget.model.remember(
        WatchEntry(
          _loaded?.item ?? widget.item,
          _episode,
          _session.position.value.inMilliseconds,
        ),
      );
    } catch (e) {
      if (mounted) M3ESnackbar.show(context, message: '观看记录未能保存，请检查本机存储空间');
    }
  }

  void _next() {
    final episodes = _loaded?.episodes ?? [];
    final index = _loaded?.episodePositions[_episode] ?? -1;
    if (index >= 0 && index + 1 < episodes.length) {
      unawaited(_play(episodes[index + 1].number));
    }
  }

  @override
  void dispose() {
    widget.model.removeListener(_identityChanged);
    _historyTimer?.cancel();
    _session.position.removeListener(_prepareFollowing);
    _keyboard.dispose();
    unawaited(_presentation.close());
    unawaited(_save());
    unawaited(_session.close());
    super.dispose();
  }

  Future<void> _action(String kind) async {
    if (widget.model.user == null && kind != 'collect') {
      await showLogin(context, widget.model);
      return;
    }
    if (_busy) return;
    setState(() => _busy = true);
    await perform(context, () async {
      switch (kind) {
        case 'collect':
          final on = !_collected;
          await widget.model.setFavorite(_loaded?.item ?? widget.item, on);
          _remoteCollected = on;
        case 'like':
          await widget.model.repository.call('like', {
            'id': widget.item.id,
            'ep': _episode,
            'on': !_liked,
          });
          _liked = !_liked;
        case 'follow':
          await widget.model.repository.call('follow', {
            'uid': number(_loaded?.author['id']),
            'on': !_following,
          });
          _following = !_following;
      }
    });
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _comments() async {
    if (_started) await _session.player.pause();
    if (!mounted) return;
    await AuroraMotion.open(
      context,
      CommentsScreen(
        model: widget.model,
        id: widget.item.id,
        episode: _episode,
      ),
    );
  }

  Widget _surface() => AspectRatio(
    aspectRatio: 16 / 9,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(_fullscreen ? 0 : 28),
      child: ColoredBox(
        color: Colors.black,
        child: _started
            ? RepaintBoundary(
                child: Video(
                  key: _videoKey,
                  controller: _session.video,
                  controls: NoVideoControls,
                ),
              )
            : Stack(
                fit: StackFit.expand,
                children: [
                  Poster(
                    repository: widget.model.repository,
                    url: widget.item.cover,
                  ),
                  ColoredBox(color: Colors.black.withValues(alpha: 0.3)),
                  Center(
                    child: M3EButton(
                      onPressed: () => _play(
                        _loaded?.episodes.firstOrNull?.number ?? 1,
                        resume: true,
                      ),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('开始观看'),
                      size: M3EButtonSize.md,
                    ),
                  ),
                ],
              ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_fullscreen,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) unawaited(_setFullscreen(false));
    },
    child: Scaffold(
      appBar: _fullscreen
          ? null
          : M3EAppBar.top(
              titleText: widget.item.title,
              automaticallyImplyLeading: true,
            ),
      body: SafeArea(
        child: KeyboardListener(
          focusNode: _keyboard,
          autofocus: true,
          onKeyEvent: (event) {
            if (event is! KeyDownEvent || !_started) return;
            if (event.logicalKey == LogicalKeyboardKey.space) {
              unawaited(_session.player.playOrPause());
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
              unawaited(
                _session.seek(
                  _session.position.value + const Duration(seconds: 10),
                ),
              );
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
              unawaited(
                _session.seek(
                  _session.position.value - const Duration(seconds: 10),
                ),
              );
            }
          },
          child: _fullscreen
              ? _immersivePlayer()
              : FutureBuilder<VideoDetail>(
                  future: _detail,
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return StatusPane(
                        loading: !snapshot.hasError,
                        error: snapshot.error?.toString(),
                        onRetry: () => setState(() => _detail = _fetch()),
                      );
                    }
                    final detail = snapshot.data!;
                    final information = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          detail.item.title,
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 14),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: detail.item.tags
                              .take(8)
                              .map((t) => M3EChip(label: t))
                              .toList(),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          detail.description,
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(height: 1.65),
                        ),
                        const SizedBox(height: 20),
                        if (string(detail.author['name']).isNotEmpty)
                          M3EListItem(
                            headline: plainText(detail.author['name']),
                            supportingText: '创作者',
                            leading: const Icon(Icons.account_circle_outlined),
                            trailing: M3EButton(
                              onPressed: _busy ? null : () => _action('follow'),
                              label: Text(_following ? '已关注' : '关注'),
                              style: M3EButtonStyle.tonal,
                            ),
                          ),
                        const SizedBox(height: 16),
                        ListenableBuilder(
                          listenable: widget.model,
                          builder: (context, _) => Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              M3EButton(
                                onPressed: _busy
                                    ? null
                                    : () => _action('collect'),
                                icon: Icon(
                                  _collected
                                      ? Icons.bookmark_rounded
                                      : Icons.bookmark_border_rounded,
                                ),
                                label: const Text('收藏'),
                                style: M3EButtonStyle.tonal,
                              ),
                              M3EButton(
                                onPressed: _busy ? null : () => _action('like'),
                                icon: Icon(
                                  _liked
                                      ? Icons.favorite_rounded
                                      : Icons.favorite_border_rounded,
                                ),
                                label: const Text('点赞'),
                                style: M3EButtonStyle.tonal,
                              ),
                              M3EButton(
                                onPressed: _comments,
                                icon: const Icon(
                                  Icons.chat_bubble_outline_rounded,
                                ),
                                label: const Text('评论'),
                                style: M3EButtonStyle.tonal,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 28),
                        Text(
                          '选集',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 14),
                        if (detail.episodes.isEmpty)
                          const Text('上游未提供分集列表，可尝试播放默认集。')
                        else
                          M3EButton(
                            onPressed: _chooseEpisode,
                            icon: const Icon(Icons.grid_view_rounded),
                            label: Text(
                              '第 $_episode 集 · 共 ${detail.episodes.length} 集',
                            ),
                            style: M3EButtonStyle.tonal,
                          ),
                      ],
                    );
                    return LayoutBuilder(
                      builder: (context, constraints) {
                        final wide = constraints.maxWidth >= 1100;
                        final playback = Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [_surface(), if (_started) _controls()],
                        );
                        return SingleChildScrollView(
                          padding: EdgeInsets.all(wide ? 32 : 20),
                          child: wide
                              ? Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(flex: 3, child: playback),
                                    const SizedBox(width: 32),
                                    Expanded(flex: 2, child: information),
                                  ],
                                )
                              : Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    playback,
                                    const SizedBox(height: 24),
                                    information,
                                  ],
                                ),
                        );
                      },
                    );
                  },
                ),
        ),
      ),
    ),
  );
  Future<void> _chooseEpisode() async {
    final episodes = _loaded?.episodes ?? [];
    if (episodes.isEmpty) return;
    final ep = await pickEpisode(context, episodes, _episode);
    if (mounted && ep != null && (!_started || ep != _episode)) {
      unawaited(_play(ep));
    }
  }

  Widget _immersivePlayer() => Theme(
    data: AppTheme.dark,
    child: Builder(
      builder: (context) => AppTheme.scope(
        context,
        ColoredBox(
          color: Colors.black,
          child: CinemaLayout(
            header: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  M3EIconButton(
                    icon: const Icon(Icons.arrow_back_rounded),
                    tooltip: '返回详情',
                    onPressed: () => unawaited(_setFullscreen(false)),
                  ),
                  Expanded(
                    child: Text(
                      widget.item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  M3EButton(
                    onPressed: _chooseEpisode,
                    label: const Text('选集'),
                    style: M3EButtonStyle.tonal,
                  ),
                ],
              ),
            ),
            video: FutureBuilder<VideoDetail>(
              future: _detail,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return StatusPane(
                    loading: !snapshot.hasError,
                    error: snapshot.error?.toString(),
                    onRetry: () => setState(() => _detail = _fetch()),
                  );
                }
                return EpisodePager(
                  episodes: _loaded?.episodes ?? const [],
                  selected: _episode,
                  onSelect: (ep) => unawaited(_play(ep)),
                  onPrepare: (ep) =>
                      unawaited(_session.prepareNext(widget.item.id, ep)),
                  video: _started
                      ? RepaintBoundary(
                          child: Video(
                            key: _videoKey,
                            controller: _session.video,
                            controls: NoVideoControls,
                          ),
                        )
                      : _surface(),
                  placeholder: (context, episode) => Stack(
                    fit: StackFit.expand,
                    children: [
                      Poster(
                        repository: widget.model.repository,
                        url: widget.item.cover,
                        fit: BoxFit.contain,
                      ),
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: M3EChip(label: '第 ${episode.number} 集'),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            controls: _started
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: _controls(),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ),
    ),
  );

  late final FocusNode _keyboard = FocusNode(debugLabel: 'player shortcuts');
  Widget _controls() => PlaybackControls(
    session: _session,
    episode: _episode,
    onNext:
        (_loaded?.episodePositions[_episode] ?? -1) >= 0 &&
            (_loaded?.episodes.last.number != _episode)
        ? _next
        : null,
    onFullscreen: () => unawaited(_setFullscreen(!_presentation.active)),
    fullscreen: _fullscreen,
    onRetry: () => _play(_episode, fresh: true),
  );
}
