import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../core/app_model.dart';
import '../core/paged_controller.dart';
import '../core/recommendations.dart';
import '../ui/haptics.dart';
import '../data/models.dart';
import '../ui/design.dart';
import '../ui/feedback.dart';
import '../ui/poster.dart';
import 'detail.dart';
import 'lines.dart';
import 'discovery_spotlight.dart';

class BrowseScreen extends StatefulWidget {
  const BrowseScreen({required this.model, this.search = false, super.key});
  final AppModel model;
  final bool search;
  @override
  State<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends State<BrowseScreen> {
  late final PagedController<VideoItem> _controller;
  late final RecommendationFeed _recommendations;
  final _scroll = ScrollController(keepScrollOffset: false),
      _query = TextEditingController();
  PageStorageBucket? _storage;
  bool _restored = false;
  late final String _storageKey;
  String _filter = 'feed', _submitted = '';
  static const filters = <String, String>{
    'feed': '为你发现',
    'personal': '猜你喜欢',
    'ai-duanju': '短剧',
    'ai-manju': '漫剧',
    'ai-huanlian': '换脸',
    'ai-mogai': '魔改',
    'hot': '热播榜',
    'recommend': '推荐榜',
    'potential': '潜力榜',
  };
  @override
  void initState() {
    super.initState();
    _storageKey = 'browse.${widget.model.identityRevision}.${widget.search}';
    _recommendations = RecommendationFeed(
      widget.model.repository,
      widget.model.recommendations,
    );
    _controller = PagedController((page) {
      if (widget.search) {
        return widget.model.repository.videos(
          'search',
          page,
          fields: {'q': _submitted},
        );
      }
      if (_filter == 'feed') {
        return widget.model.repository.videos('feed', page);
      }
      if (_filter == 'personal') return _recommendations.load(page);
      if (_filter.startsWith('ai-')) {
        return widget.model.repository.videos(
          'category',
          page,
          fields: {'cate': _filter},
        );
      }
      return widget.model.repository.videos(
        'rank',
        page,
        fields: {'kind': _filter},
      );
    }, identity: (item) => item.id);
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 600) _controller.next();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_restored) return;
    _restored = true;
    _storage = PageStorage.maybeOf(context);
    final saved = _storage?.readState(context, identifier: _storageKey);
    if (saved is (String, String, String)) {
      _filter = filters.containsKey(saved.$1) ? saved.$1 : 'feed';
      _submitted = saved.$2;
      _query.text = saved.$3;
    }
    if (!widget.search || _submitted.isNotEmpty) _controller.next();
  }

  @override
  void dispose() {
    // Explicit identifier avoids ancestor lookups during disposal. Keep only
    // small user input state; evicted pages release images and result lists.
    _storage?.writeState(context, (
      _filter,
      _submitted,
      _query.text,
    ), identifier: _storageKey);
    _controller.dispose();
    _scroll.dispose();
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final text = _query.text.trim();
    if (text.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() => _submitted = text);
    unawaited(_controller.refresh());
    AppHaptics.selection(context);
    try {
      await widget.model.rememberSearch(text);
    } catch (_) {
      if (mounted) M3ESnackbar.show(context, message: '搜索偏好未能保存，请检查本机存储空间');
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      PageHeading(
        widget.search ? '找到心动的故事' : '发现好故事',
        subtitle: widget.search
            ? '搜索标题、标签与关键词'
            : _filter == 'personal'
            ? '从偶然心动，到越来越懂你'
            : 'Hedone · 随时开启下一段精彩',
        actions: [
          M3EIconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: () => _controller.refresh(),
            variant: M3EIconButtonVariant.tonal,
          ),
        ],
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 18),
        child: widget.search
            ? M3ETextField(
                controller: _query,
                label: '搜索黄果',
                placeholder: '输入关键词，按回车搜索',
                maxLength: 120,
                showCounter: false,
                leading: const Icon(Icons.search_rounded),
                trailing: M3EIconButton(
                  icon: const Icon(Icons.arrow_forward_rounded),
                  tooltip: '搜索',
                  onPressed: _search,
                ),
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
              )
            : SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  spacing: 8,
                  children: filters.entries
                      .map(
                        (e) => M3EChip(
                          label: e.value,
                          type: M3EChipType.filter,
                          selected: _filter == e.key,
                          onPressed: () {
                            if (_filter == e.key) return;
                            AppHaptics.selection(context);
                            setState(() => _filter = e.key);
                            _controller.refresh();
                            if (_scroll.hasClients) _scroll.jumpTo(0);
                          },
                        ),
                      )
                      .toList(),
                ),
              ),
      ),
      Expanded(
        child: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) {
            if (widget.search && _submitted.isEmpty) {
              return const StatusPane(message: '让好故事，从一个关键词开始');
            }
            if (_controller.items.isEmpty) {
              final status = StatusPane(
                loading: _controller.loading,
                error: _controller.error,
                onRetry: _controller.error == null
                    ? null
                    : () => _controller.next(),
              );
              if (_controller.error == null) {
                if (_controller.loading || !_controller.hasMore) return status;
                return SingleChildScrollView(
                  child: Column(
                    children: [
                      status,
                      M3EButton(
                        onPressed: () => _controller.next(),
                        label: const Text('继续发现'),
                      ),
                    ],
                  ),
                );
              }
              return SingleChildScrollView(
                child: Column(
                  children: [
                    status,
                    if (kIsWeb)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('请管理员检查 Rust 服务配置的数据线路。'),
                      )
                    else
                      M3EButton(
                        onPressed: () => AuroraMotion.open(
                          context,
                          LinesScreen(model: widget.model),
                        ),
                        label: const Text('更换数据线路'),
                        style: M3EButtonStyle.tonal,
                      ),
                  ],
                ),
              );
            }
            return M3ERefreshIndicator(
              onRefresh: _controller.refresh,
              child: CustomScrollView(
                controller: _scroll,
                physics: const AlwaysScrollableScrollPhysics(),
                scrollCacheExtent: const ScrollCacheExtent.pixels(240),
                slivers: [
                  if (!widget.search && _filter == 'feed')
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                      sliver: SliverToBoxAdapter(
                        child: DiscoverySpotlight(
                          model: widget.model,
                          item: _controller.items.first,
                        ),
                      ),
                    ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    sliver: SliverLayoutBuilder(
                      builder: (context, constraints) {
                        final textScale =
                            MediaQuery.textScalerOf(context).scale(14) / 14;
                        final columns =
                            (constraints.crossAxisExtent /
                                    (textScale > 1.5 ? 280 : 180))
                                .floor()
                                .clamp(textScale > 1.5 ? 1 : 2, 6);
                        final width =
                            (constraints.crossAxisExtent - (columns - 1) * 16) /
                            columns;
                        final offset = !widget.search && _filter == 'feed'
                            ? 1
                            : 0;
                        return SliverGrid.builder(
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: columns,
                                crossAxisSpacing: 16,
                                mainAxisSpacing: 16,
                                mainAxisExtent: width * 1.3 + 84 * textScale,
                              ),
                          itemCount: _controller.items.length - offset,
                          itemBuilder: (context, i) => VideoTile(
                            key: ValueKey(_controller.items[i + offset].id),
                            model: widget.model,
                            item: _controller.items[i + offset],
                          ),
                        );
                      },
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: _controller.loading
                          ? const Center(
                              child: SizedBox(
                                width: 40,
                                height: 40,
                                child: M3ELoadingIndicator(),
                              ),
                            )
                          : _controller.error != null
                          ? StatusPane(
                              error: _controller.error,
                              onRetry: () => _controller.next(),
                            )
                          : _controller.hasMore
                          ? Center(
                              child: M3EButton(
                                onPressed: () => _controller.next(),
                                label: const Text('继续发现'),
                                style: M3EButtonStyle.tonal,
                              ),
                            )
                          : const Center(child: Text('已经看到这里的全部内容')),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    ],
  );
}

class VideoTile extends StatefulWidget {
  const VideoTile({
    required this.model,
    required this.item,
    this.progress,
    super.key,
  });
  final AppModel model;
  final VideoItem item;
  final String? progress;
  @override
  State<VideoTile> createState() => _VideoTileState();
}

class _VideoTileState extends State<VideoTile> {
  final _artwork = Object();
  bool _opening = false;
  Future<void> _open() async {
    if (_opening) return;
    _opening = true;
    AppHaptics.selection(context);
    try {
      await AuroraMotion.open(context, _destination(context));
    } finally {
      _opening = false;
    }
  }

  AppModel get model => widget.model;
  VideoItem get item => widget.item;
  String? get progress => widget.progress;
  Widget _destination(BuildContext context) => DetailScreen(
    model: model,
    item: item,
    heroTag: _artwork,
    autoplay: true,
    immersive: MediaQuery.sizeOf(context).width < 600,
  );
  @override
  Widget build(BuildContext context) => M3ECard(
    variant: M3ECardVariant.filled,
    padding: EdgeInsets.zero,
    semanticLabel: '打开 ${item.title}',
    onPressed: _open,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Stack(
              fit: StackFit.expand,
              children: [
                PosterHero(
                  tag: _artwork,
                  repository: model.repository,
                  url: item.cover,
                ),
                if (item.score > 0)
                  Positioned(
                    top: 10,
                    right: 10,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerLow,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 5,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.star_rounded,
                              size: 14,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              item.score.toStringAsFixed(1),
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Text(
            item.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Text(
            progress ??
                '${item.episodes} 集${item.score > 0 ? '  ·  ${item.score.toStringAsFixed(1)} 分' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    ),
  );
}
