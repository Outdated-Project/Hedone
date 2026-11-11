import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_model.dart';
import '../data/models.dart';
import '../ui/design.dart';
import '../ui/brand_mark.dart';
import '../ui/feedback.dart';
import '../ui/action_list_item.dart';
import 'lines.dart';
import 'network_diagnostics.dart';
import 'license.dart';
import '../ui/haptics.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({required this.model, super.key});
  final AppModel model;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final Set<String> _pending = {};
  bool _logs = false;
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

  Future<void> _run(String operation, Future<void> Function() action) async {
    if (!_pending.add(operation)) return;
    setState(() {});
    try {
      await perform(context, action);
    } finally {
      if (mounted) setState(() => _pending.remove(operation));
    }
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
    await AuroraMotion.open(context, LicenseScreen(source: text));
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
    for (final font in ['notosanssc', 'googlesans', 'googlesanscode']) {
      text.writeln(await rootBundle.loadString('assets/fonts/$font-OFL.txt'));
    }
    for (final entry in {
      'RecurseX 0.2.6': 'recurse-x',
      'Courierust 1.1.2': 'courierust',
      'Reqwest 0.12': 'reqwest-mit',
      'Rustls 0.23': 'rustls-isc',
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
        content: Text(available ? plainText(result['notes']) : '当前版本 1.0.1'),
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
                  Uri.parse(
                    'https://github.com/Outdated-Project/HGhub/releases',
                  ),
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
                              headline: '震动反馈',
                              supportingText: '切换导航、筛选与播放手势时提供轻触反馈',
                              leading: const Icon(Icons.vibration_rounded),
                              trailing: M3ESwitch(
                                value: model.haptics,
                                onChanged: (v) => perform(context, () async {
                                  await model.setHaptics(v);
                                  if (v && context.mounted) {
                                    AppHaptics.selection(context);
                                  }
                                }),
                              ),
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
                            ActionListItem(
                              headline: '网络自检',
                              supportingText: '检查域名解析与安全连接',
                              icon: Icons.network_check_rounded,
                              onTap: () => AuroraMotion.open(
                                context,
                                NetworkDiagnosticsScreen(
                                  repository: model.repository,
                                ),
                              ),
                            ),
                            if (!kIsWeb)
                              ActionListItem(
                                headline: '清理媒体缓存',
                                supportingText: '保留账号、收藏与观看历史',
                                icon: Icons.cleaning_services_outlined,
                                busy: _pending.contains('cache'),
                                onTap: () => _run('cache', () async {
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
                            ActionListItem(
                              headline: '重置推荐偏好',
                              supportingText: '猜你喜欢在本机按观看与搜索更新；重置后恢复随机探索',
                              icon: Icons.auto_awesome_outlined,
                              busy: _pending.contains('recommendations'),
                              onTap: () => _run('recommendations', () async {
                                model.recommendations.clear();
                                await model.saveLibrary();
                                if (context.mounted) {
                                  M3ESnackbar.show(
                                    context,
                                    message: '推荐偏好已重置，下次刷新生效',
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
                                  onChanged: _pending.contains('logging')
                                      ? null
                                      : (v) => _run('logging', () async {
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
                              ActionListItem(
                                headline: '查看诊断日志',
                                icon: Icons.receipt_long_outlined,
                                busy: _pending.contains('logs'),
                                onTap: () => _run('logs', () async {
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
                              headline: 'Hedone 1.0.1',
                              supportingText:
                                  'Flutter × Rust · Material 3 Expressive',
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: const BrandMark(),
                              ),
                            ),
                            ActionListItem(
                              headline: '检查更新',
                              icon: Icons.system_update_alt_rounded,
                              busy: _pending.contains('update'),
                              onTap: () => _run('update', _update),
                            ),
                            M3EListItem(
                              headline: '许可证',
                              supportingText: 'PolyForm Noncommercial 1.0.0',
                              leading: const Icon(Icons.description_outlined),
                              trailing: const Icon(Icons.chevron_right_rounded),
                              onTap: () => _run('license', _license),
                            ),
                            M3EListItem(
                              headline: '第三方软件许可',
                              leading: const Icon(Icons.description_outlined),
                              onTap: () => _run('licenses', _dependencies),
                            ),
                          ],
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
