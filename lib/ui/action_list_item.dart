import 'design.dart';

/// Keeps progress local to the action without tinting unrelated settings rows.
class ActionListItem extends StatelessWidget {
  const ActionListItem({
    required this.headline,
    required this.icon,
    required this.onTap,
    this.supportingText,
    this.busy = false,
    super.key,
  });
  final String headline;
  final String? supportingText;
  final IconData icon;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) => M3EListItem(
    headline: headline,
    supportingText: supportingText,
    leading: Icon(icon),
    onTap: busy ? null : onTap,
    trailing: AnimatedSwitcher(
      duration: AuroraMotion.duration(context),
      switchInCurve: AuroraMotion.curve,
      switchOutCurve: AuroraMotion.curve,
      child: busy
          ? Semantics(
              key: const ValueKey('busy'),
              label: '正在处理',
              liveRegion: true,
              child: const SizedBox(
                width: 24,
                height: 24,
                child: M3ELoadingIndicator(),
              ),
            )
          : const Icon(Icons.chevron_right_rounded, key: ValueKey('ready')),
    ),
  );
}
