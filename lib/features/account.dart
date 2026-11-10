import '../core/app_model.dart';
import '../ui/design.dart';
import '../ui/feedback.dart';
import '../data/transport.dart';
import 'browse.dart';

Future<void> showLogin(BuildContext context, AppModel model) =>
    M3EDialog.show(context, dialog: LoginDialog(model: model));

class LoginDialog extends StatefulWidget {
  const LoginDialog({required this.model, super.key});
  final AppModel model;
  @override
  State<LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<LoginDialog> {
  final _name = TextEditingController(),
      _password = TextEditingController(),
      _email = TextEditingController();
  bool _register = false, _busy = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    _password.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.model.authenticate(
        _name.text,
        _password.text,
        email: _register ? _email.text : null,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: M3EDialog(
      title: _register ? '创建黄果账号' : '欢迎回来',
      icon: const Icon(Icons.person_outline_rounded),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 16,
          children: [
            Text('账号与当前固定线路绑定', style: Theme.of(context).textTheme.bodyMedium),
            M3ETextField(
              controller: _name,
              label: '用户名',
              enabled: !_busy,
              maxLength: 64,
              showCounter: false,
              textInputAction: TextInputAction.next,
            ),
            M3ETextField(
              controller: _password,
              label: '密码',
              obscureText: true,
              showPasswordToggle: true,
              enabled: !_busy,
              maxLength: 256,
              showCounter: false,
              onSubmitted: (_) => _submit(),
            ),
            if (_register)
              M3ETextField(
                controller: _email,
                label: '邮箱（选填）',
                enabled: !_busy,
                keyboardType: TextInputType.emailAddress,
                maxLength: 254,
                showCounter: false,
              ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (_busy)
              const Center(
                child: SizedBox(
                  width: 36,
                  height: 36,
                  child: M3ELoadingIndicator(),
                ),
              ),
          ],
        ),
      ),
      actions: [
        M3EButton(
          onPressed: _busy
              ? null
              : () => setState(() => _register = !_register),
          label: Text(_register ? '已有账号' : '创建账号'),
          style: M3EButtonStyle.text,
        ),
        M3EButton(
          onPressed: _busy ? null : _submit,
          label: Text(_register ? '注册' : '登录'),
        ),
      ],
    ),
  );
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({required this.model, super.key});
  final AppModel model;
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  bool _history = false;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model,
    builder: (context, _) {
      final model = widget.model;
      final videos = _history
          ? model.history.map((e) => e.video).toList()
          : model.favorites.values.toList();
      return Column(
        children: [
          PageHeading('我的片库', subtitle: '把喜欢的故事，留在身边'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: M3ECard(
              variant: M3ECardVariant.filled,
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 28,
                    backgroundColor: Theme.of(context)
                        .colorScheme
                        .primaryContainer,
                    child: const Icon(Icons.person_rounded),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          model.user == null
                              ? '以游客身份浏览'
                              : '${model.user!['nickname'] ?? model.user!['username'] ?? '黄果用户'}',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          model.user == null ? '收藏与观看进度保存在这台设备' : '已连接黄果账号',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  M3EButton(
                    onPressed: model.accountBusy
                        ? null
                        : () => model.user == null
                              ? showLogin(context, model)
                              : perform(context, model.logout),
                    label: Text(model.user == null ? '登录' : '退出'),
                    style: M3EButtonStyle.tonal,
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                M3EChip(
                  label: '收藏 ${model.favorites.length}',
                  type: M3EChipType.filter,
                  selected: !_history,
                  onPressed: () => setState(() => _history = false),
                ),
                M3EChip(
                  label: '历史 ${model.history.length}',
                  type: M3EChipType.filter,
                  selected: _history,
                  onPressed: () => setState(() => _history = true),
                ),
                if (_history && videos.isNotEmpty)
                  M3EButton(
                    onPressed: () => _clear(context),
                    style: M3EButtonStyle.text,
                    label: const Text('清空历史'),
                  ),
              ],
            ),
          ),
          Expanded(
            child: videos.isEmpty
                ? StatusPane(message: _history ? '播放记录会出现在这里' : '喜欢的故事，点一下收藏')
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 240,
                          mainAxisExtent: 340,
                          crossAxisSpacing: 16,
                          mainAxisSpacing: 16,
                        ),
                    itemCount: videos.length,
                    itemBuilder: (context, i) => VideoTile(
                      model: model,
                      item: videos[i],
                      progress: _history
                          ? '第 ${model.history[i].episode} 集 · ${Duration(milliseconds: model.history[i].positionMs).inMinutes} 分钟'
                          : null,
                    ),
                  ),
          ),
        ],
      );
    },
  );
  Future<void> _clear(BuildContext context) async {
    final clear = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: '清空观看历史？',
        content: const Text('只清除这台设备当前线路的观看记录。'),
        actions: [
          M3EButton(
            onPressed: () => Navigator.pop(context, false),
            label: const Text('保留'),
            style: M3EButtonStyle.text,
          ),
          M3EButton(
            onPressed: () => Navigator.pop(context, true),
            label: const Text('清空'),
          ),
        ],
      ),
    );
    if (clear == true && context.mounted) {
      await perform(context, widget.model.clearHistory);
    }
  }
}
