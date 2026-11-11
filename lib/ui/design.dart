import 'package:material_ui/material_ui.dart';
import 'package:flutter/physics.dart' show SpringSimulation;
import 'package:material_3_expressive/material_3_expressive.dart'
    show M3EMotion;
export 'package:material_ui/material_ui.dart' hide CornerRounding;
export 'package:material_3_expressive/material_3_expressive.dart'
    show
        M3EMaterialApp,
        M3EThemeData,
        M3ETheme,
        M3ETypography,
        M3ETypeScaleMode,
        M3EAppBar,
        M3EButton,
        M3EButtonStyle,
        M3EButtonSize,
        M3ECard,
        M3ECardVariant,
        M3ECardTheme,
        M3EChip,
        M3EChipType,
        M3EDialog,
        M3EIconButton,
        M3EIconButtonVariant,
        M3EIconButtonSize,
        M3EListItem,
        M3EListTheme,
        M3EListItemTheme,
        M3EListStyle,
        M3ELoadingIndicator,
        M3ENavigationBar,
        M3ENavigationBarDestination,
        M3ENavigationRail,
        M3ENavigationRailType,
        M3ENavigationRailSection,
        M3ENavigationRailDestination,
        M3ERefreshIndicator,
        M3ESlider,
        M3ESnackbar,
        M3ESwitch,
        M3ETextField;

abstract final class AuroraMotion {
  static const standard = Duration(milliseconds: 360);
  static const emphasized = Duration(milliseconds: 480);
  static const curve = Curves.easeInOutCubicEmphasized;
  static final Curve spatial = _ExpressiveSpringCurve();
  static Duration duration(BuildContext context, [Duration value = standard]) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : value;
  static Future<T?> open<T>(BuildContext context, Widget page) =>
      Navigator.of(context).push<T>(
        PageRouteBuilder<T>(
          transitionDuration: duration(context, emphasized),
          reverseTransitionDuration: duration(context),
          pageBuilder: (_, animation, secondary) => page,
          transitionsBuilder: (_, animation, secondary, child) {
            final progress = animation.drive(CurveTween(curve: curve));
            return FadeTransition(
              opacity: progress,
              child: SlideTransition(
                position: Tween(
                  begin: const Offset(0.025, 0.025),
                  end: Offset.zero,
                ).animate(animation.drive(CurveTween(curve: spatial))),
                child: child,
              ),
            );
          },
        ),
      );
}

class _ExpressiveSpringCurve extends Curve {
  final _spring = SpringSimulation(
    M3EMotion.expressiveSpatialDefault.toDescription(),
    0,
    1,
    0,
  );
  @override
  double transformInternal(double t) => _spring.x(t * .6);
}

class PageHeading extends StatelessWidget {
  const PageHeading(
    this.title, {
    this.subtitle,
    this.actions = const [],
    super.key,
  });
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.headlineLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 6),
                Text(
                  subtitle!,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
        ...actions,
      ],
    ),
  );
}
