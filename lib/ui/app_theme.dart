import 'design.dart';

/// Material surfaces and Expressive tokens share the same animated theme.
abstract final class AppTheme {
  static final light = _create(Brightness.light);
  static final dark = _create(Brightness.dark);

  static ThemeData _create(Brightness brightness) {
    const seed = Color(0xFF647A27);
    final data =
        (brightness == Brightness.light
                ? M3EThemeData.light(seedColor: seed)
                : M3EThemeData.dark(seedColor: seed))
            .copyWith(
              typography: M3ETypography.material3(
                mode: M3ETypeScaleMode.variable,
              ),
              fontFamily: 'Roboto Flex',
              fontFamilyFallback: const ['Noto Sans SC'],
            );
    return data.toThemeData().copyWith(
      scaffoldBackgroundColor: data.colorScheme.surface,
    );
  }

  static Widget scope(BuildContext context, Widget child) => M3ETheme(
    data: M3EThemeData.fromMaterial(Theme.of(context)),
    child: child,
  );
}
