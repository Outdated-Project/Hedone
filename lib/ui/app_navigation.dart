import 'design.dart';

/// Use the whole viewport, not the space left above the keyboard.
bool usesNavigationSidebar(TargetPlatform platform, Size viewport) =>
    switch (platform) {
      TargetPlatform.windows ||
      TargetPlatform.linux ||
      TargetPlatform.macOS => true,
      _ => viewport.shortestSide >= 600 && viewport.width > viewport.height,
    };

class CapsuleNavigationBar extends StatelessWidget {
  const CapsuleNavigationBar({
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    super.key,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<M3ENavigationBarDestination> destinations;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Align(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Material(
            shape: StadiumBorder(
              side: BorderSide(color: colors.outlineVariant),
            ),
            clipBehavior: Clip.antiAlias,
            color: colors.surfaceContainer,
            child: M3ENavigationBar(
              selectedIndex: selectedIndex,
              onDestinationSelected: onDestinationSelected,
              destinations: destinations,
              autoLayout: false,
              safeArea: false,
              backgroundColor: Colors.transparent,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
          ),
        ),
      ),
    );
  }
}
