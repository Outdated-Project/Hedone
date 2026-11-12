import 'dart:convert';

import '../core/app_model.dart';
import '../data/models.dart';
import '../data/transport.dart';
import '../ui/design.dart';
import '../ui/feedback.dart';
import '../ui/haptics.dart';

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
  bool _cached = false;
  int _probeCount = 0, _probeTotal = 0;

  List<Json> _validMirrors(dynamic value) => objects(value)
      .where((row) {
        final uri = Uri.tryParse(string(row['url']));
        return uri != null &&
            uri.scheme == 'https' &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty &&
            (uri.path.isEmpty || uri.path == '/') &&
            !uri.hasQuery &&
            !uri.hasFragment;
      })
      .take(60)
      .toList();

  @override
  void initState() {
    super.initState();
    _state = widget.model.repository.call('line_state').then(object);
    _discover();
  }

  Future<bool> _select(String url) async {
    final model = widget.model;
    if (url == model.base) return true;
    if (_selecting != null || _confirming) return false;
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
      if (approved != true || !mounted) return false;
    }
    setState(() => _selecting = url);
    AppHaptics.selection(context);
    try {
      await model.setLine(url);
      if (mounted) M3ESnackbar.show(context, message: '已切换数据线路');
      return true;
    } catch (error) {
      if (mounted) M3ESnackbar.show(context, message: errorMessage(error));
      return false;
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
      if (_mirrors.isEmpty) {
        try {
          final saved = await widget.model.preferences.getString(
            'line.mirrors.v1',
          );
          final cache = saved == null
              ? <String, dynamic>{}
              : object(jsonDecode(saved));
          final age =
              DateTime.now().millisecondsSinceEpoch - number(cache['at']);
          if (mounted &&
              age >= 0 &&
              age < const Duration(days: 7).inMilliseconds) {
            setState(() {
              _mirrors = _validMirrors(cache['items']);
              _cached = _mirrors.isNotEmpty;
            });
          }
        } catch (_) {
          /* Ignore unavailable optional cache; fetch the source. */
        }
      }
      final value = object(await widget.model.repository.call('line_mirrors'));
      final mirrors = _validMirrors(value['items']);
      if (mounted) {
        setState(() {
          _mirrors = mirrors;
          _cached = false;
          if (_mirrors.isEmpty) _discoveryError = '发布页没有返回镜像，请稍后刷新。固定线路仍可手动选择。';
        });
      }
      if (mirrors.isNotEmpty) {
        try {
          await widget.model.preferences.setString(
            'line.mirrors.v1',
            jsonEncode({
              'at': DateTime.now().millisecondsSinceEpoch,
              'items': mirrors,
            }),
          );
        } catch (_) {
          /* A cache write cannot invalidate fresh network results. */
        }
      }
    } catch (error) {
      if (mounted) setState(() => _discoveryError = errorMessage(error));
    } finally {
      if (mounted) setState(() => _discovering = false);
    }
  }

  Future<void> _probe(List<Json> lines, {bool selectAvailable = false}) async {
    if (_probing) return;
    final revision = widget.model.identityRevision;
    setState(() {
      _probing = true;
      _probeCount = 0;
      _probeTotal = lines.length;
    });
    await perform(context, () async {
      // Small batches let recovery stop as soon as a working content API is found.
      final batchSize = selectAvailable ? 6 : 16;
      for (
        var offset = 0;
        offset < lines.length && mounted;
        offset += batchSize
      ) {
        final batch = lines.skip(offset).take(batchSize).toList();
        final value = object(
          await widget.model.repository.call('line_probe', {
            'urls': batch.map((line) => string(line['url'])).toList(),
          }),
        );
        if (!mounted) return;
        final fresh = <String, Json>{
          for (final result in objects(value['items']))
            string(result['url']): result,
        };
        setState(() {
          _probeCount += batch.length;
          for (final line in batch) {
            _results.remove(string(line['url']));
          }
          _results.addAll(fresh);
        });
        if (selectAvailable) {
          // A manual selection or account change takes priority over this probe.
          if (revision != widget.model.identityRevision) return;
          final usable = batch
              .map((line) => string(line['url']))
              .where((url) => fresh[url]?['ok'] == true)
              .toList();
          if (usable.isNotEmpty) {
            // Keep a recovered current line; otherwise prefer fixed origins
            // (listed first) before temporary guest mirrors.
            final current = widget.model.base;
            final selected = await _select(
              usable.contains(current) ? current : usable.first,
            );
            if (mounted && selected) Navigator.of(context).pop();
            return;
          }
        }
      }
      if (selectAvailable && mounted) {
        M3ESnackbar.show(context, message: '暂未找到能提供视频的线路，请查看检测结果或稍后刷新镜像。');
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
            if (widget.model.base.isNotEmpty &&
                ![
                  ...fixed,
                  ..._mirrors,
                ].any((v) => v['url'] == widget.model.base))
              widget.model.base: {'name': '当前线路', 'url': widget.model.base},
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
                  const Text('自动读取发布页镜像。镜像仅供游客浏览，账号登录请使用固定线路。'),
                  const SizedBox(height: 24),
                  if (_cached)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text('显示最近缓存的镜像，可用性以连接检测为准。'),
                    ),
                  for (final line in lines) _line(line),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      M3EButton(
                        onPressed:
                            _probing || _discovering || _selecting != null
                            ? null
                            : () => _probe(lines, selectAvailable: true),
                        label: const Text('自动选择可用线路'),
                        icon: const Icon(Icons.auto_fix_high_rounded),
                      ),
                      M3EButton(
                        onPressed: _discovering ? null : _discover,
                        label: Text(_discovering ? '正在查找镜像' : '刷新镜像'),
                        icon: const Icon(Icons.travel_explore_rounded),
                        style: M3EButtonStyle.tonal,
                      ),
                      M3EButton(
                        onPressed: _probing ? null : () => _probe(lines),
                        label: Text(
                          _probing ? '检测中 $_probeCount/$_probeTotal' : '检测连接',
                        ),
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
