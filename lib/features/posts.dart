import '../core/app_model.dart';
import '../core/paged_controller.dart';
import '../data/models.dart';
import '../ui/design.dart';
import '../ui/feedback.dart';
import '../ui/poster.dart';
import '../ui/rich_content.dart';
import 'account.dart';
import 'comments.dart';
import 'detail.dart';
import 'post_video.dart';

class PostsScreen extends StatefulWidget {
  const PostsScreen({required this.model, super.key});
  final AppModel model;
  @override
  State<PostsScreen> createState() => _PostsScreenState();
}

class _PostsScreenState extends State<PostsScreen> {
  late final PagedController<Json> _controller;
  @override
  void initState() {
    super.initState();
    _controller = PagedController((page) async {
      final value = await widget.model.repository.call('posts', {
        'page': page,
        'size': 24,
      });
      return PageResult(
        objects(value['items']),
        page < number(object(value['pagination'])['pages']),
      );
    }, identity: (item) => number(item['id']));
    _controller.next();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      const PageHeading('社区', subtitle: '换个角度，发现更多'),
      Expanded(
        child: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) {
            if (_controller.items.isEmpty) {
              return StatusPane(
                loading: _controller.loading,
                error: _controller.error,
                onRetry: _controller.error == null
                    ? null
                    : () => _controller.next(),
              );
            }
            return M3ERefreshIndicator(
              onRefresh: _controller.refresh,
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                itemCount: _controller.items.length + 1,
                separatorBuilder: (_, i) => const SizedBox(height: 16),
                itemBuilder: (context, i) {
                  if (i == _controller.items.length) {
                    return _controller.hasMore
                        ? M3EButton(
                            onPressed: _controller.loading
                                ? null
                                : () => _controller.next(),
                            label: const Text('加载更多'),
                            style: M3EButtonStyle.tonal,
                          )
                        : const SizedBox.shrink();
                  }
                  final post = _controller.items[i];
                  return M3ECard(
                    variant: M3ECardVariant.filled,
                    padding: const EdgeInsets.all(16),
                    onPressed: () => AuroraMotion.open(
                      context,
                      PostScreen(model: widget.model, id: number(post['id'])),
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 100,
                          height: 110,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: Poster(
                              repository: widget.model.repository,
                              url: string(post['cover']),
                            ),
                          ),
                        ),
                        const SizedBox(width: 18),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            spacing: 8,
                            children: [
                              Text(
                                plainText(post['title']),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              Text(
                                plainText(post['desc']),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                plainText(object(post['author'])['name']),
                                style: Theme.of(context).textTheme.labelMedium,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            );
          },
        ),
      ),
    ],
  );
}

class PostScreen extends StatefulWidget {
  const PostScreen({required this.model, required this.id, super.key});
  final AppModel model;
  final int id;
  @override
  State<PostScreen> createState() => _PostScreenState();
}

class _PostScreenState extends State<PostScreen> {
  late Future<Json> _post;
  int _identity = 0, _loadGeneration = 0;
  bool _liked = false, _collected = false, _busy = false;
  @override
  void initState() {
    super.initState();
    _identity = widget.model.identityRevision;
    widget.model.addListener(_identityChanged);
    _post = _fetch();
  }

  Future<Json> _fetch() async {
    final generation = ++_loadGeneration;
    final post = await widget.model.repository.call('post', {'id': widget.id});
    if (mounted && generation == _loadGeneration) {
      final interaction = object(post['interaction']);
      _liked = interaction['liked'] == true;
      _collected = interaction['collected'] == true;
    }
    return post;
  }

  void _identityChanged() {
    if (widget.model.serviceExpired ||
        _identity == widget.model.identityRevision) {
      return;
    }
    _identity = widget.model.identityRevision;
    setState(() => _post = _fetch());
  }

  @override
  void dispose() {
    widget.model.removeListener(_identityChanged);
    super.dispose();
  }

  Future<void> _interact(bool like) async {
    if (widget.model.user == null) {
      await showLogin(context, widget.model);
      return;
    }
    if (_busy) return;
    setState(() => _busy = true);
    await perform(context, () async {
      await widget.model.repository.call(like ? 'post_like' : 'post_collect', {
        'id': widget.id,
        'on': like ? !_liked : !_collected,
      });
      if (mounted) {
        setState(() {
          if (like) {
            _liked = !_liked;
          } else {
            _collected = !_collected;
          }
        });
      }
    });
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: const M3EAppBar.top(
      titleText: '帖子',
      automaticallyImplyLeading: true,
    ),
    body: FutureBuilder<Json>(
      future: _post,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return StatusPane(
            loading: !snapshot.hasError,
            error: snapshot.error?.toString(),
            onRetry: () => setState(() => _post = _fetch()),
          );
        }
        final post = snapshot.data!;
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  plainText(post['title']),
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 16),
                if (string(post['cover']).isNotEmpty)
                  SizedBox(
                    height: 280,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(28),
                      child: Poster(
                        repository: widget.model.repository,
                        url: string(post['cover']),
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
                RichContent(
                  source: string(post['content'] ?? post['desc']),
                  repository: widget.model.repository,
                ),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    if (string(post['video_url']).isNotEmpty)
                      M3EButton(
                        onPressed: () => AuroraMotion.open(
                          context,
                          PostVideoScreen(
                            repository: widget.model.repository,
                            url: string(post['video_url']),
                            title: plainText(post['title']),
                          ),
                        ),
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text('播放视频'),
                      ),
                    M3EButton(
                      onPressed: _busy ? null : () => _interact(true),
                      icon: Icon(
                        _liked
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                      ),
                      label: const Text('点赞'),
                      style: M3EButtonStyle.tonal,
                    ),
                    M3EButton(
                      onPressed: _busy ? null : () => _interact(false),
                      icon: Icon(
                        _collected
                            ? Icons.bookmark_rounded
                            : Icons.bookmark_border_rounded,
                      ),
                      label: const Text('收藏'),
                      style: M3EButtonStyle.tonal,
                    ),
                    M3EButton(
                      onPressed: () => AuroraMotion.open(
                        context,
                        CommentsScreen(
                          model: widget.model,
                          id: widget.id,
                          post: true,
                        ),
                      ),
                      label: const Text('查看评论'),
                      style: M3EButtonStyle.tonal,
                    ),
                    if (number(post['video_id']) > 0)
                      M3EButton(
                        onPressed: () => AuroraMotion.open(
                          context,
                          DetailScreen(
                            model: widget.model,
                            item: VideoItem(
                              id: number(post['video_id']),
                              title: plainText(post['title']),
                              cover: string(post['cover']),
                              episodes: 0,
                              tags: const [],
                            ),
                          ),
                        ),
                        label: const Text('播放关联视频'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
