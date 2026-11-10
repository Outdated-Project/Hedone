import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../core/app_model.dart';
import '../core/paged_controller.dart';
import '../data/models.dart';
import '../ui/design.dart';
import '../ui/feedback.dart';
import '../ui/poster.dart';
import 'detail.dart';
import 'settings.dart';
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
  final _scroll = ScrollController(), _query = TextEditingController();
  String _filter = 'feed', _submitted = '';
  static const filters = <String, String>{
    'feed': '为你发现',
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
    if (!widget.search) _controller.next();
  }

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    _query.dispose();
    super.dispose();
  }

  void _search() {
    final text = _query.text.trim();
    if (text.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() => _submitted = text);
    _controller.refresh();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      PageHeading(
        widget.search ? '找到心动的故事' : '发现好故事',
        subtitle: widget.search ? '搜索标题、标签与关键词' : '黄果 · 随时开启下一段精彩',
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
              if (_controller.error == null) return status;
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

class VideoTile extends StatelessWidget {
  const VideoTile({
    required this.model,
    required this.item,
    this.progress,
    super.key,
  });
  final AppModel model;
  final VideoItem item;
  final String? progress;
  Widget _destination(BuildContext context) => DetailScreen(
    model: model,
    item: item,
    autoplay: true,
    immersive: MediaQuery.sizeOf(context).width < 600,
  );
  @override
  Widget build(BuildContext context) => M3ECard(
    variant: M3ECardVariant.filled,
    padding: EdgeInsets.zero,
    semanticLabel: '打开 ${item.title}',
    openBuilder: MediaQuery.disableAnimationsOf(context)
        ? null
        : (_) => _destination(context),
    onPressed: MediaQuery.disableAnimationsOf(context)
        ? () => AuroraMotion.open(context, _destination(context))
        : null,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Poster(repository: model.repository, url: item.cover),
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
