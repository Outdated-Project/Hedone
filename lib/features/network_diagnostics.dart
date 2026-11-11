import 'dart:convert';

import '../data/models.dart';
import '../data/repository.dart';
import '../data/transport.dart';
import '../ui/design.dart';
import '../ui/feedback.dart';

class NetworkDiagnosticsScreen extends StatefulWidget {
  const NetworkDiagnosticsScreen({required this.repository, super.key});
  final Repository repository;
  @override
  State<NetworkDiagnosticsScreen> createState() =>
      _NetworkDiagnosticsScreenState();
}

class _NetworkDiagnosticsScreenState extends State<NetworkDiagnosticsScreen> {
  late Future<Json> _result;
  bool _running = true, _details = false;
  @override
  void initState() {
    super.initState();
    _result = _load();
  }

  Future<Json> _load() async {
    try {
      return object(await widget.repository.call('net_diag'));
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  void _retry() {
    if (_running) return;
    setState(() {
      _running = true;
      _result = _load();
    });
  }

  Widget _check(
    String title,
    String description, {
    required bool good,
    required IconData icon,
  }) {
    final colors = Theme.of(context).colorScheme;
    return M3ECard(
      variant: M3ECardVariant.filled,
      padding: const EdgeInsets.all(20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: good ? colors.primary : colors.error),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
                Text(
                  description,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _report(Json report) {
    final dns = object(report['dns']), http = object(report['http']);
    final dnsOk = dns['error'] == null && number(dns['count']) > 0;
    final status = number(http['status']);
    final contentProbe = http['probe'] == 'content_api';
    final httpOk =
        http['error'] == null &&
        (contentProbe ? http['ok'] == true : status >= 200 && status < 400);
    final connected = dnsOk && httpOk;
    final proxy = object(report['env']).entries
        .any((e) => e.key != 'NO_PROXY' && e.value != null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(
          connected ? Icons.verified_user_outlined : Icons.gpp_maybe_outlined,
          size: 48,
          color: connected
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.error,
        ),
        const SizedBox(height: 16),
        Text(
          connected ? '连接正常' : '连接需要处理',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(string(report['base']), textAlign: TextAlign.center),
        const SizedBox(height: 28),
        _check(
          dnsOk ? '域名解析正常' : '域名解析失败',
          dnsOk
              ? '已取得 ${number(dns['count'])} 个地址${dns['has_fake_ip'] == true ? '，检测到 Fake-IP 地址' : ''}。'
              : errorMessage(dns['error'] ?? '没有取得可用地址'),
          good: dnsOk,
          icon: Icons.dns_outlined,
        ),
        const SizedBox(height: 12),
        _check(
          httpOk
              ? contentProbe
                    ? '内容接口正常'
                    : '安全连接正常'
              : http['error'] != null
              ? '安全连接失败'
              : '服务器响应异常',
          httpOk
              ? '${contentProbe ? '已验证安全连接并取得内容列表' : '服务器已响应'}，用时 ${number(http['ms'])} ms。'
              : http['error'] != null
              ? errorMessage(http['error'])
              : '已建立安全连接，但服务器返回 HTTP $status。可以更换数据线路后重试。',
          good: httpOk,
          icon: Icons.https_outlined,
        ),
        const SizedBox(height: 16),
        Text(
          proxy ? '已配置应用代理；检测结果以上方实际连接为准。' : '未配置应用环境代理；系统 VPN 或网络接管仍可能影响连接。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (object(report['transport'])['upstream_streaming'] == false) ...[
          const SizedBox(height: 12),
          Text(
            object(report['transport'])['progressive_range'] == true
                ? '支持 Range 和强 ETag 的视频按需分段读取；其他单次响应上限为 8 MiB。'
                : '每次响应最多 8 MiB，完整接收后才交给播放器。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 24),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            M3EButton(
              onPressed: _running ? null : _retry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重新检测'),
            ),
            M3EButton(
              onPressed: () => setState(() => _details = !_details),
              label: Text(_details ? '收起技术详情' : '技术详情'),
              style: M3EButtonStyle.text,
            ),
          ],
        ),
        _technicalDetails(report),
      ],
    );
  }

  Widget _technicalDetails(Json report) {
    final child = _details
        ? Padding(
            padding: const EdgeInsets.only(top: 20),
            child: SelectableText(
              const JsonEncoder.withIndent('  ').convert(report),
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(fontFamily: 'Google Sans Code'),
            ),
          )
        : const SizedBox(width: double.infinity);
    // A zero-duration AnimatedSize can re-dirty its own layout. Reduced motion
    // renders the final subtree directly and creates no animation controller.
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return AnimatedSize(
      duration: AuroraMotion.standard,
      curve: AuroraMotion.curve,
      alignment: Alignment.topCenter,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: const M3EAppBar.top(
      titleText: '网络自检',
      automaticallyImplyLeading: true,
    ),
    body: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: FutureBuilder<Json>(
            future: _result,
            builder: (context, snapshot) {
              final ready = snapshot.connectionState == ConnectionState.done;
              return AnimatedSwitcher(
                duration: AuroraMotion.duration(context),
                child: !ready
                    ? const Padding(
                        key: ValueKey('loading'),
                        padding: EdgeInsets.symmetric(vertical: 64),
                        child: StatusPane(loading: true),
                      )
                    : snapshot.hasError
                    ? StatusPane(
                        key: const ValueKey('error'),
                        error: errorMessage(snapshot.error!),
                        onRetry: _retry,
                      )
                    : KeyedSubtree(
                        key: const ValueKey('report'),
                        child: _report(snapshot.data!),
                      ),
              );
            },
          ),
        ),
      ),
    ),
  );
}
