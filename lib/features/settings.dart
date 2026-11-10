import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_model.dart';
import '../data/models.dart';
import '../ui/design.dart';
import '../ui/feedback.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({required this.model, super.key});
  final AppModel model;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _busy = false, _logs = false;
  @override
  void initState() {
    super.initState();
    widget.model.repository
        .call('log_status')
        .then((value) {
          if (mounted) setState(() => _logs = value['enabled'] == true);
        })
        .catchError((Object _) {});
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    await perform(context, action);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _text(String title, String content) => M3EDialog.show(
    context,
    dialog: M3EDialog(
      title: title,
      content: SizedBox(width: 640, child: SelectableText(content)),
      actions: [
        M3EButton(
          onPressed: () => Navigator.pop(context),
          label: const Text('关闭'),
        ),
      ],
    ),
  );
  Future<void> _license() async {
    final text = await rootBundle.loadString('LICENSE');
    if (!mounted) return;
    await _text('PolyForm Noncommercial 1.0.0', text);
  }

  Future<void> _dependencies() async {
    final entries = await LicenseRegistry.licenses.toList();
    final text = StringBuffer();
    for (final entry in entries) {
      text.writeln(entry.packages.join(', '));
      for (final p in entry.paragraphs) {
        text.writeln(p.text);
      }
      text.writeln();
    }
    for (final font in ['robotoflex', 'notosanssc']) {
      text.writeln(await rootBundle.loadString('assets/fonts/$font-OFL.txt'));
    }
    for (final entry in {
      'RecurseX 0.2.4': 'recurse-x',
      'Courierust 1.1.1': 'courierust',
      'NextJson 0.1.5 / RustBinary 0.1.10': 'apache-2.0',
      'Mozilla CA certificate bundle': 'mozilla-mpl-2.0',
    }.entries) {
      text.writeln(entry.key);
      text.writeln(
        await rootBundle.loadString('assets/licenses/${entry.value}.txt'),
      );
    }
    if (mounted) await _text('第三方软件与字体许可', text.toString());
  }

  Future<void> _update() async {
    final result = await widget.model.repository.call('check_update');
    if (!mounted) return;
    final available = result['has_update'] == true;
    await M3EDialog.show(
      context,
      dialog: M3EDialog(
        title: available ? '发现新版本 ${result['latest']}' : '当前没有新版本',
        content: Text(available ? plainText(result['notes']) : '当前版本 2.0.0'),
        actions: [
          M3EButton(
            onPressed: () => Navigator.pop(context),
            label: const Text('关闭'),
            style: M3EButtonStyle.text,
          ),
          if (available)
            M3EButton(
              onPressed: () => perform(context, () async {
                await launchUrl(
                  Uri.parse('https://github.com/Minireel/HGhub/releases'),
                  mode: LaunchMode.externalApplication,
                );
              }),
              label: const Text('查看发布页'),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model,
    builder: (context, _) {
      final model = widget.model;
      final colors = Theme.of(context).colorScheme;
      return M3ETheme(
        data: M3ETheme.of(context).copyWith(
          cardTheme: M3ECardTheme(
            radius: 24,
            filledContainerColor: colors.surfaceContainerLow,
          ),
          listTheme: const M3EListTheme(
            item: M3EListItemTheme(
              style: M3EListStyle.standard,
              containerColor: Colors.transparent,
            ),
          ),
        ),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1040),
            child: ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                const PageHeading('设置', subtitle: '外观、播放与连接'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 16,
                    children: [
                      M3ECard(
                        variant: M3ECardVariant.filled,
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          spacing: 16,
                          children: [
                            Text(
                              '外观与动效',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final entry in {
                                  'system': '跟随系统',
                                  'light': '浅色',
                                  'dark': '深色',
                                }.entries)
                                  M3EChip(
                                    label: entry.value,
                                    type: M3EChipType.filter,
                                    selected: model.theme == entry.key,
                                    onPressed: () => perform(
                                      context,
                                      () => model.setTheme(entry.key),
                                    ),
                                  ),
                              ],
                            ),
                            M3EListItem(
                              headline: '减少动态效果',
                              supportingText: '同时遵循系统的减少动态效果设置',
                              trailing: M3ESwitch(
                                value: model.reducedMotion,
                                onChanged: (v) => perform(
                                  context,
                                  () => model.setReducedMotion(v),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      M3ECard(
                        variant: M3ECardVariant.filled,
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          children: [
                            M3EListItem(
                              headline: '数据线路',
                              supportingText: model.base,
                              leading: const Icon(Icons.route_outlined),
                              trailing: const Icon(Icons.chevron_right_rounded),
                              onTap: kIsWeb
                                  ? null
                                  : () => AuroraMotion.open(
                                      context,
                                      LinesScreen(model: model),
                                    ),
                            ),
                            if (kIsWeb)
                              const Padding(
                                padding: EdgeInsets.all(12),
                                child: Text('Web 线路由 Rust 服务管理员配置。'),
                              ),
                            M3EListItem(
                              headline: '网络自检',
                              supportingText: '查看 DNS、代理及接口连通状态',
                              leading: const Icon(Icons.network_check_rounded),
                              enabled: !_busy,
                              onTap: () => _run(() async {
                                final result = await model.repository.call(
                                  'net_diag',
                                );
                                if (context.mounted) {
                                  await _text(
                                    '网络自检',
                                    const JsonEncoder.withIndent('  ')
                                        .convert(result),
                                  );
                                }
                              }),
                            ),
                            if (!kIsWeb)
                              M3EListItem(
                                headline: '清理媒体缓存',
                                supportingText: '保留账号、收藏与观看历史',
                                leading: const Icon(
                                  Icons.cleaning_services_outlined,
                                ),
                                enabled: !_busy,
                                onTap: () => _run(() async {
                                  await model.repository.call('cache_clear');
                                  PaintingBinding.instance.imageCache.clear();
                                  model.repository.invalidate();
                                  if (context.mounted) {
                                    M3ESnackbar.show(
                                      context,
                                      message: '媒体缓存已清理',
                                    );
                                  }
                                }),
                              ),
                            if (!kIsWeb)
                              M3EListItem(
                                headline: '播放诊断',
                                supportingText: '默认关闭；记录经过脱敏的播放事件',
                                trailing: M3ESwitch(
                                  value: _logs,
                                  onChanged: _busy
                                      ? null
                                      : (v) => _run(() async {
                                          await model.repository.call(
                                            'log_set',
                                            {'enabled': v},
                                          );
                                          if (mounted) {
                                            setState(() => _logs = v);
                                          }
                                        }),
                                ),
                              ),
                            if (!kIsWeb)
                              M3EListItem(
                                headline: '查看诊断日志',
                                leading: const Icon(
                                  Icons.receipt_long_outlined,
                                ),
                                enabled: !_busy,
                                onTap: () => _run(() async {
                                  final value = await model.repository.call(
                                    'log_read',
                                  );
                                  if (context.mounted) {
                                    await _text('播放诊断', string(value['text']));
                                  }
                                }),
                              ),
                          ],
                        ),
                      ),
                      M3ECard(
                        variant: M3ECardVariant.filled,
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          children: [
                            M3EListItem(
                              headline: 'HGhub 2.0.0',
                              supportingText:
                                  'Flutter × Rust · Material 3 Expressive',
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Image.asset(
                                  'assets/brand.png',
                                  width: 48,
                                  height: 48,
                                ),
                              ),
                            ),
                            M3EListItem(
                              headline: '检查更新',
                              leading: const Icon(
                                Icons.system_update_alt_rounded,
                              ),
                              enabled: !_busy,
                              onTap: () => _run(_update),
                            ),
                            M3EListItem(
                              headline: '仅限非商业用途',
                              supportingText:
                                  'PolyForm Noncommercial License 1.0.0',
                              leading: const Icon(Icons.gpp_good_outlined),
                              onTap: () => _run(_license),
                            ),
                            M3EListItem(
                              headline: '第三方软件许可',
                              leading: const Icon(Icons.description_outlined),
                              onTap: () => _run(_dependencies),
                            ),
                          ],
                        ),
                      ),
                      if (_busy)
                        const Center(
                          child: SizedBox(
                            width: 36,
                            height: 36,
                            child: M3ELoadingIndicator(),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          'NONCOMMERCIAL\n禁止商业使用，不提供商业授权。内容与第三方组件的权利归各自权利人；软件许可不授予第三方内容的使用权。',
                          style: Theme.of(context).textTheme.bodySmall,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class LinesScreen extends StatefulWidget {
  const LinesScreen({required this.model, super.key});
  final AppModel model;
  @override
  State<LinesScreen> createState() => _LinesScreenState();
}

class _LinesScreenState extends State<LinesScreen> {
  late Future<Json> _lines;
  List<Json> _mirrors = [];
  final Map<String, String> _latency = {};
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _lines = widget.model.repository.call('line_state');
  }

  Future<void> _select(String url) async {
    if (url == widget.model.base || _busy) return;
    final approved = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: '切换数据线路？',
        content: Text('将退出当前账号并重新加载内容。\n$url'),
        actions: [
          M3EButton(
            onPressed: () => Navigator.pop(context, false),
            label: const Text('取消'),
            style: M3EButtonStyle.text,
          ),
          M3EButton(
            onPressed: () => Navigator.pop(context, true),
            label: const Text('切换'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    setState(() => _busy = true);
    await perform(context, () => widget.model.setLine(url));
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: const M3EAppBar.top(
      titleText: '数据线路',
      automaticallyImplyLeading: true,
    ),
    body: FutureBuilder<Json>(
      future: _lines,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return StatusPane(
            loading: !snapshot.hasError,
            error: snapshot.error?.toString(),
            onRetry: () => setState(
              () => _lines = widget.model.repository.call('line_state'),
            ),
          );
        }
        final fixed = objects(snapshot.data!['fixed']);
        final all = [...fixed, ..._mirrors];
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text('固定线路可登录账号。镜像只用于游客浏览，不会接收你的账号凭据。'),
            const SizedBox(height: 16),
            for (final line in all)
              M3EListItem(
                headline: string(line['name']).isEmpty
                    ? string(line['host'])
                    : string(line['name']),
                supportingText: string(line['url']),
                selected: widget.model.base == line['url'],
                enabled: !_busy,
                leading: Icon(
                  widget.model.base == line['url']
                      ? Icons.check_circle_rounded
                      : Icons.language_rounded,
                ),
                trailingText: _latency[string(line['url'])],
                onTap: () => _select(string(line['url'])),
              ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                M3EButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          setState(() => _busy = true);
                          await perform(context, () async {
                            final value = await widget.model.repository.call(
                              'line_mirrors',
                            );
                            if (context.mounted) {
                              setState(
                                () => _mirrors = objects(value['items']),
                              );
                            }
                          });
                          if (mounted) setState(() => _busy = false);
                        },
                  label: const Text('刷新镜像'),
                  style: M3EButtonStyle.tonal,
                ),
                M3EButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          setState(() => _busy = true);
                          await perform(context, () async {
                            final value = await widget.model.repository.call(
                              'line_probe',
                              {
                                'urls': all
                                    .take(16)
                                    .map((e) => string(e['url']))
                                    .toList(),
                              },
                            );
                            if (context.mounted) {
                              setState(() {
                                for (final line in objects(value['items'])) {
                                  _latency[string(
                                    line['url'],
                                  )] = line['ok'] == true
                                      ? '${number(line['ms'])} ms'
                                      : '不可用';
                                }
                              });
                              await M3EDialog.show(
                                context,
                                dialog: M3EDialog(
                                  title: '线路检测',
                                  content: SelectableText(
                                    const JsonEncoder.withIndent('  ')
                                        .convert(value),
                                  ),
                                ),
                              );
                            }
                          });
                          if (mounted) setState(() => _busy = false);
                        },
                  label: const Text('检测前 16 条线路'),
                  style: M3EButtonStyle.tonal,
                ),
              ],
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: M3ELoadingIndicator(),
                  ),
                ),
              ),
          ],
        );
      },
    ),
  );
}
