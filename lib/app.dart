import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'core/preferences.dart';

import 'core/app_model.dart';
import 'data/repository.dart';
import 'data/transport.dart';
import 'data/transport_factory.dart';
import 'features/account.dart';
import 'features/browse.dart';
import 'features/posts.dart';
import 'features/settings.dart';
import 'ui/design.dart';
import 'ui/aurora_scene.dart';
import 'ui/app_navigation.dart';
import 'ui/brand_mark.dart';
import 'ui/app_theme.dart';
import 'ui/haptics.dart';
import 'ui/feedback.dart';

class HedoneApp extends StatefulWidget {
  const HedoneApp({this.model, super.key});
  final AppModel? model;
  @override
  State<HedoneApp> createState() => _HedoneAppState();
}

class _HedoneAppState extends State<HedoneApp> {
  late final AppModel _model =
      widget.model ??
      AppModel(Repository(createTransport()), DevicePreferences());
  late Future<void> _ready;
  final _navigator = GlobalKey<NavigatorState>();
  bool _serviceWasExpired = false;
  late final _appearance = ValueNotifier((
    _model.theme,
    _model.reducedMotion,
    _model.haptics,
    _model.serviceExpired,
  ));
  @override
  void initState() {
    super.initState();
    _model.addListener(_serviceChanged);
    _ready = _model.initialize();
  }

  void _serviceChanged() {
    _appearance.value = (
      _model.theme,
      _model.reducedMotion,
      _model.haptics,
      _model.serviceExpired,
    );
    final expired = _model.serviceExpired;
    if (expired && !_serviceWasExpired) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _model.serviceExpired) {
          _navigator.currentState?.popUntil((route) => route.isFirst);
        }
      });
    }
    _serviceWasExpired = expired;
  }

  @override
  void dispose() {
    _model.removeListener(_serviceChanged);
    _appearance.dispose();
    if (widget.model == null) _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _appearance,
    builder: (context, _) => MaterialApp(
      navigatorKey: _navigator,
      title: 'Hedone · 黄果',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: switch (_model.theme) {
        'dark' => ThemeMode.dark,
        'light' => ThemeMode.light,
        _ => ThemeMode.system,
      },
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      locale: const Locale('zh', 'CN'),
      themeAnimationDuration:
          (_model.reducedMotion ||
              WidgetsBinding
                  .instance
                  .platformDispatcher
                  .accessibilityFeatures
                  .disableAnimations)
          ? Duration.zero
          : AuroraMotion.standard,
      themeAnimationCurve: AuroraMotion.curve,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations:
              MediaQuery.disableAnimationsOf(context) || _model.reducedMotion,
        ),
        child: HapticScope(
          enabled: _model.haptics,
          child: AppTheme.scope(context, child!),
        ),
      ),
      home: FutureBuilder<void>(
        future: _ready,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Scaffold(body: StatusPane(loading: true));
          }
          if (snapshot.hasError || _model.serviceExpired) {
            return StartupScreen(
              error: _model.serviceExpired
                  ? const ServiceConnectionRequired()
                  : snapshot.error!,
              onRetry: () => setState(() => _ready = _model.initialize()),
              onConnect: (key) async {
                await _model.repository.transport.connect(key);
                if (!mounted) return;
                setState(() => _ready = _model.initialize());
              },
            );
          }
          return AppShell(model: _model);
        },
      ),
    ),
  );
}

class StartupScreen extends StatefulWidget {
  const StartupScreen({
    required this.error,
    required this.onRetry,
    required this.onConnect,
    super.key,
  });
  final Object error;
  final VoidCallback onRetry;
  final Future<void> Function(String) onConnect;
  @override
  State<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<StartupScreen> {
  final _key = TextEditingController();
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onConnect(_key.text.trim());
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: M3ECard(
            variant: M3ECardVariant.filled,
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 20,
              children: [
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: const BrandMark(size: 80),
                  ),
                ),
                Text(
                  'Hedone',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
                if (widget.error is ServiceConnectionRequired) ...[
                  const Text('连接你的 Rust 服务', textAlign: TextAlign.center),
                  M3ETextField(
                    controller: _key,
                    label: '服务访问密钥',
                    obscureText: true,
                    enabled: !_busy,
                    onSubmitted: (_) => _connect(),
                  ),
                  if (_error != null)
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  M3EButton(
                    onPressed: _busy ? null : _connect,
                    label: Text(_busy ? '连接中…' : '连接'),
                    size: M3EButtonSize.md,
                  ),
                ] else ...[
                  Text(errorMessage(widget.error), textAlign: TextAlign.center),
                  M3EButton(
                    onPressed: widget.onRetry,
                    label: const Text('重新初始化'),
                  ),
                ],
                Text(
                  'NONCOMMERCIAL · 仅限非商业用途',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class AppShell extends StatefulWidget {
  const AppShell({required this.model, super.key});
  final AppModel model;
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final AnimationController _scene = AnimationController(
    vsync: this,
    duration: AuroraMotion.standard,
    value: 1,
  );
  int _selected = 0, _revision = 0;
  AuroraSceneTransition _transition = AuroraSceneTransition.settled(0, 5);
  bool _active = true;
  final Map<int, Widget> _pages = {};
  final List<int> _recency = [0];
  static const _labels = ['发现', '搜索', '社区', '片库', '设置'];
  static const _icons = [
    Icons.explore_outlined,
    Icons.search_rounded,
    Icons.forum_outlined,
    Icons.bookmarks_outlined,
    Icons.tune_rounded,
  ];
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scene.addStatusListener(_settled);
    _revision = widget.model.identityRevision;
    widget.model.addListener(_changed);
  }

  void _settled(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted) {
      setState(() {
        final retained = _recency.take(2).toSet();
        _pages.removeWhere((index, _) => !retained.contains(index));
      });
    }
  }

  void _changed() {
    if (widget.model.reducedMotion && _scene.isAnimating) _scene.value = 1;
    if (_revision != widget.model.identityRevision) {
      _scene.value = 1;
      setState(() {
        _revision = widget.model.identityRevision;
        _pages.clear();
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() => _active = state == AppLifecycleState.resumed);
    if (_active) {
      if (_scene.value < 1) _scene.forward();
    } else {
      _scene.stop();
    }
  }

  @override
  void didHaveMemoryPressure() {
    _scene.value = 1;
    setState(() => _pages.removeWhere((index, _) => index != _selected));
    PaintingBinding.instance.imageCache.clear();
    widget.model.repository.invalidate();
    if (!kIsWeb) {
      unawaited(
        widget.model.repository
            .call('cache_clear')
            .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) _scene.value = 1;
  }

  @override
  void dispose() {
    widget.model.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    _scene.dispose();
    super.dispose();
  }

  Widget _page(int index) => _pages.putIfAbsent(
    index,
    () => switch (index) {
      0 => BrowseScreen(model: widget.model),
      1 => BrowseScreen(model: widget.model, search: true),
      2 => PostsScreen(model: widget.model),
      3 => LibraryScreen(model: widget.model),
      _ => SettingsScreen(model: widget.model),
    },
  );
  void _select(int value) {
    if (_selected == value) return;
    AppHaptics.selection(context);
    _transition = _transition.retarget(value, _scene.value);
    _recency
      ..remove(value)
      ..insert(0, value);
    setState(() => _selected = value);
    if (MediaQuery.disableAnimationsOf(context)) {
      _scene.value = 1;
      _settled(AnimationStatus.completed);
    } else {
      _scene.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.digit1, control: true): _Destination(
        0,
      ),
      SingleActivator(LogicalKeyboardKey.digit2, control: true): _Destination(
        1,
      ),
      SingleActivator(LogicalKeyboardKey.digit3, control: true): _Destination(
        2,
      ),
      SingleActivator(LogicalKeyboardKey.digit4, control: true): _Destination(
        3,
      ),
      SingleActivator(LogicalKeyboardKey.digit5, control: true): _Destination(
        4,
      ),
    },
    child: Actions(
      actions: {
        _Destination: CallbackAction<_Destination>(
          onInvoke: (intent) {
            _select(intent.index);
            return null;
          },
        ),
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = usesNavigationSidebar(
            defaultTargetPlatform,
            MediaQuery.sizeOf(context),
          );
          _page(_selected);
          final body = KeyedSubtree(
            key: ValueKey(_revision),
            child: Flow(
              delegate: AuroraSceneDelegate(
                animation: _scene,
                transition: _transition,
              ),
              children: List.generate(5, (i) {
                final hidden =
                    i != _selected &&
                    (_scene.isCompleted || !_transition.visible(i));
                return Offstage(
                  offstage: hidden,
                  child: IgnorePointer(
                    ignoring: i != _selected,
                    child: ExcludeSemantics(
                      excluding: i != _selected,
                      child: TickerMode(
                        enabled: _active && i == _selected,
                        child: Focus(
                          canRequestFocus: i == _selected,
                          descendantsAreFocusable: i == _selected,
                          child: RepaintBoundary(
                            child: ColoredBox(
                              color: Theme.of(context).scaffoldBackgroundColor,
                              child: _pages[i] ?? const SizedBox.shrink(),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          );
          return Scaffold(
            body: SafeArea(
              bottom: false,
              child: Row(
                children: [
                  if (wide)
                    M3ENavigationRail(
                      type: M3ENavigationRailType.alwaysExpand,
                      expandedWidth: 220,
                      selectedIndex: _selected,
                      onDestinationSelected: _select,
                      leading: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(18),
                              child: const BrandMark(),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Hedone',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ],
                        ),
                      ),
                      trailing: const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'NONCOMMERCIAL',
                          style: TextStyle(fontSize: 10, letterSpacing: 1.2),
                        ),
                      ),
                      sections: [
                        M3ENavigationRailSection(
                          destinations: List.generate(
                            5,
                            (i) => M3ENavigationRailDestination(
                              icon: Icon(_icons[i]),
                              label: _labels[i],
                            ),
                          ),
                        ),
                      ],
                    ),
                  Expanded(child: body),
                ],
              ),
            ),
            bottomNavigationBar: wide
                ? null
                : CapsuleNavigationBar(
                    selectedIndex: _selected,
                    onDestinationSelected: _select,
                    destinations: List.generate(
                      5,
                      (i) => M3ENavigationBarDestination(
                        icon: Icon(_icons[i]),
                        label: _labels[i],
                      ),
                    ),
                  ),
          );
        },
      ),
    ),
  );
}

class _Destination extends Intent {
  const _Destination(this.index);
  final int index;
}
