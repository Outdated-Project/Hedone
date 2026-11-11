import '../core/app_model.dart';
import '../data/models.dart';
import '../data/transport.dart';
import '../ui/design.dart';
import '../ui/feedback.dart';

class LinesScreen extends StatefulWidget {
  const LinesScreen({required this.model, super.key});
  final AppModel model;
  @override
  State<LinesScreen> createState() => _LinesScreenState();
}

class _LinesScreenState extends State<LinesScreen> {
  late Future<Json> _state;
  List<Json> _mirrors = [];
  final Map<String, Json> _results = {};
  String? _selecting;
  bool _confirming = false, _discovering = false, _probing = false;
  String? _discoveryError;

  @override
  void initState() {
    super.initState();
    _state = widget.model.repository.call('line_state').then(object);
  }

  Future<void> _select(String url) async {
    final model = widget.model;
    if (url == model.base || _selecting != null || _confirming) return;
    if (model.user != null) {
      _confirming = true;
      final approved = await M3EDialog.show<bool>(
        context,
        dialog: M3EDialog(
          title: '切换数据线路？',
          content: const Text('切换后将退出当前账号，收藏和观看历史仍按原线路保留。'),
          actions: [
            M3EButton(
              onPressed: () =>
                  Navigator.of(context, rootNavigator: true).pop(false),
              label: const Text('取消'),
              style: M3EButtonStyle.text,
            ),
            M3EButton(
              onPressed: () =>
                  Navigator.of(context, rootNavigator: true).pop(true),
              label: const Text('切换'),
            ),
          ],
        ),
      );
      _confirming = false;
      if (approved != true || !mounted) return;
    }
    setState(() => _selecting = url);
    try {
      await model.setLine(url);
      if (mounted) M3ESnackbar.show(context, message: '已切换数据线路');
    } catch (error) {
      if (mounted) M3ESnackbar.show(context, message: errorMessage(error));
    } finally {
      if (mounted) setState(() => _selecting = null);
    }
  }

  Future<void> _discover() async {
    if (_discovering) return;
    setState(() {
      _discovering = true;
      _discoveryError = null;
    });
    try {
      final value = object(await widget.model.repository.call('line_mirrors'));
      if (mounted) setState(() => _mirrors = objects(value['items']));
    } catch (error) {
      if (mounted) setState(() => _discoveryError = errorMessage(error));
    } finally {
      if (mounted) setState(() => _discovering = false);
    }
  }

  Future<void> _probe(List<Json> lines) async {
    if (_probing) return;
    setState(() => _probing = true);
    await perform(context, () async {
      final value = object(
        await widget.model.repository.call('line_probe', {
          'urls': lines.take(16).map((line) => string(line['url'])).toList(),
        }),
      );
      if (mounted) {
        setState(() {
          for (final result in objects(value['items'])) {
            _results[string(result['url'])] = result;
          }
        });
      }
    });
    if (mounted) setState(() => _probing = false);
  }

  Widget _line(Json line) {
    final url = string(line['url']);
    final selected = widget.model.base == url;
    final result = _results[url];
    final progress = _selecting == url;
    final status = result == null
        ? null
        : result['ok'] == true
        ? '连接正常 · ${number(result['ms'])} ms'
        : result['error'] != null
        ? errorMessage(result['error'])
        : '服务器返回 HTTP ${number(result['status'])}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: M3EListItem(
        key: ValueKey(url),
        headline: string(line['name']).isEmpty
            ? string(line['host'])
            : string(line['name']),
        supportingText: status == null ? url : '$url\n$status',
        selected: selected,
        leading: Icon(
          selected
              ? Icons.radio_button_checked_rounded
              : Icons.radio_button_off_rounded,
        ),
        trailing: progress
            ? const SizedBox(
                width: 24,
                height: 24,
                child: M3ELoadingIndicator(),
              )
            : selected
            ? null
            : const Icon(Icons.chevron_right_rounded),
        onTap: _selecting != null || selected ? null : () => _select(url),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: const M3EAppBar.top(
      titleText: '数据线路',
      automaticallyImplyLeading: true,
    ),
    body: ListenableBuilder(
      listenable: widget.model,
      builder: (context, _) => FutureBuilder<Json>(
        future: _state,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return StatusPane(
              loading: !snapshot.hasError,
              error: snapshot.hasError ? errorMessage(snapshot.error!) : null,
              onRetry: () => setState(
                () => _state = widget.model.repository
                    .call('line_state')
                    .then(object),
              ),
            );
          }
          final fixed = objects(snapshot.data!['fixed']);
          final unique = <String, Json>{
            for (final row in [...fixed, ..._mirrors]) string(row['url']): row,
          };
          final lines = unique.values.toList();
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840),
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  Text(
                    '选择线路',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  const Text('切换不依赖连接检测。镜像仅供游客浏览，账号登录请使用固定线路。'),
                  const SizedBox(height: 24),
                  for (final line in lines) _line(line),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      M3EButton(
                        onPressed: _discovering ? null : _discover,
                        label: Text(_discovering ? '正在查找镜像' : '刷新镜像'),
                        icon: const Icon(Icons.travel_explore_rounded),
                        style: M3EButtonStyle.tonal,
                      ),
                      M3EButton(
                        onPressed: _probing ? null : () => _probe(lines),
                        label: Text(_probing ? '正在检测' : '检测连接'),
                        icon: const Icon(Icons.network_check_rounded),
                        style: M3EButtonStyle.tonal,
                      ),
                    ],
                  ),
                  if (_discoveryError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        _discoveryError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
}
