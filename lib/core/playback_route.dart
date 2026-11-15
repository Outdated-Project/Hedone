import 'package:flutter/widgets.dart';

import 'playback_session.dart';

// Popup routes (options, login and episode sheets) deliberately do not count as
// leaving playback. A full page does; returning never overrides a user's pause.
final playbackRouteObserver = RouteObserver<PageRoute<dynamic>>();

class PlaybackRoute extends StatefulWidget {
  const PlaybackRoute({required this.session, required this.child, super.key});
  final PlaybackSession session;
  final Widget child;
  @override
  State<PlaybackRoute> createState() => _PlaybackRouteState();
}

class _PlaybackRouteState extends State<PlaybackRoute> with RouteAware {
  PageRoute<dynamic>? _route;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic> && route != _route) {
      playbackRouteObserver.unsubscribe(this);
      _route = route;
      playbackRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didPushNext() => widget.session.setRouteVisible(false);
  @override
  void didPop() => widget.session.setRouteVisible(false);
  @override
  void didPopNext() => widget.session.setRouteVisible(true);
  @override
  void dispose() {
    playbackRouteObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
