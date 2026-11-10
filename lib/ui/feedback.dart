import '../data/transport.dart';
import 'design.dart';

Future<void> perform(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (e) {
    if (context.mounted) M3ESnackbar.show(context, message: errorMessage(e));
  }
}

class StatusPane extends StatelessWidget {
  const StatusPane({
    this.loading = false,
    this.error,
    this.message = '暂时没有内容',
    this.onRetry,
    super.key,
  });
  final bool loading;
  final String? error;
  final String message;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (loading)
            const SizedBox(width: 56, height: 56, child: M3ELoadingIndicator())
          else
            Icon(
              error == null ? Icons.inbox_outlined : Icons.cloud_off_rounded,
              size: 42,
              color: Theme.of(context).colorScheme.primary,
            ),
          const SizedBox(height: 18),
          Text(
            loading ? '正在加载' : error ?? message,
            textAlign: TextAlign.center,
          ),
          if (!loading && onRetry != null) ...[
            const SizedBox(height: 18),
            M3EButton(
              onPressed: onRetry,
              label: const Text('重试'),
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ],
      ),
    ),
  );
}
