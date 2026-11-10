import '../core/app_model.dart';
import '../core/paged_controller.dart';
import '../data/models.dart';
import '../ui/design.dart';
import '../ui/feedback.dart';
import 'account.dart';

class CommentsScreen extends StatefulWidget {
  const CommentsScreen({
    required this.model,
    required this.id,
    this.episode = 1,
    this.post = false,
    super.key,
  });
  final AppModel model;
  final int id, episode;
  final bool post;
  @override
  State<CommentsScreen> createState() => _CommentsScreenState();
}

class _CommentsScreenState extends State<CommentsScreen> {
  late final PagedController<Json> _controller;
  final _text = TextEditingController();
  bool _sending = false;
  int? _replyId;
  String? _replyName;
  @override
  void initState() {
    super.initState();
    _controller = PagedController((page) async {
      final result = await widget.model.repository.call(
        widget.post ? 'post_comments' : 'comments',
        {
          'id': widget.id,
          if (!widget.post) 'ep': widget.episode,
          'page': page,
          'size': 30,
        },
      );
      return PageResult(
        objects(result['items']),
        page < number(object(result['pagination'])['pages']),
      );
    });
    _controller.next();
  }

  @override
  void dispose() {
    _controller.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending || _text.text.trim().isEmpty) return;
    if (widget.model.user == null) {
      await showLogin(context, widget.model);
      return;
    }
    setState(() => _sending = true);
    await perform(context, () async {
      await widget.model.repository.call('comment_send', {
        'id': widget.id,
        'ep': widget.episode,
        'text': _text.text.trim(),
        'reply_id': _replyId,
      });
      _text.clear();
      if (mounted) {
        setState(() {
          _replyId = null;
          _replyName = null;
        });
      }
      await _controller.refresh();
    });
    if (mounted) setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: M3EAppBar.top(titleText: '评论', automaticallyImplyLeading: true),
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            child: ListenableBuilder(
              listenable: _controller,
              builder: (context, _) {
                if (_controller.items.isEmpty) {
                  return StatusPane(
                    loading: _controller.loading,
                    error: _controller.error,
                    message: '还没有评论',
                    onRetry: _controller.error == null
                        ? null
                        : () => _controller.next(),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.all(20),
                  itemCount: _controller.items.length + 1,
                  separatorBuilder: (_, i) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    if (i == _controller.items.length) {
                      return _controller.hasMore
                          ? M3EButton(
                              onPressed: _controller.loading
                                  ? null
                                  : () => _controller.next(),
                              label: Text(
                                _controller.loading ? '加载中…' : '更多评论',
                              ),
                              style: M3EButtonStyle.tonal,
                            )
                          : const SizedBox(height: 20);
                    }
                    final c = _controller.items[i];
                    return M3ECard(
                      variant: M3ECardVariant.filled,
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 8,
                        children: [
                          Text(
                            plainText(c['nickname']),
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          Text(plainText(c['text'])),
                          for (final reply in objects(c['reply_list']))
                            Padding(
                              padding: const EdgeInsets.only(left: 16),
                              child: Text(
                                '${plainText(reply['nickname'])}：${plainText(reply['text'])}',
                              ),
                            ),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  string(c['time']),
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                              ),
                              if (!widget.post)
                                M3EButton(
                                  onPressed: () {
                                    setState(() {
                                      _replyId = number(c['id']);
                                      _replyName = plainText(c['nickname']);
                                    });
                                  },
                                  label: const Text('回复'),
                                  style: M3EButtonStyle.text,
                                ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
          if (!widget.post)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_replyName != null)
                    Row(
                      children: [
                        Expanded(child: Text('回复 $_replyName')),
                        M3EIconButton(
                          icon: const Icon(Icons.close_rounded),
                          tooltip: '取消回复',
                          onPressed: () => setState(() {
                            _replyId = null;
                            _replyName = null;
                          }),
                        ),
                      ],
                    ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: M3ETextField(
                          controller: _text,
                          label: '说说你的想法',
                          maxLength: 2000,
                          minLines: 1,
                          maxLines: 4,
                          enabled: !_sending,
                        ),
                      ),
                      const SizedBox(width: 10),
                      M3EIconButton(
                        icon: Icon(
                          _sending
                              ? Icons.hourglass_top_rounded
                              : Icons.send_rounded,
                        ),
                        tooltip: '发送评论',
                        onPressed: _sending ? null : _send,
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
