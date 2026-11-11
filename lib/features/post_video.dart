import 'dart:async';

import '../core/fullscreen_session.dart';
import '../ui/feedback.dart';
import '../ui/cinema_layout.dart';

import 'package:media_kit_video/media_kit_video.dart';

import '../core/playback_session.dart';
import '../data/repository.dart';
import '../ui/design.dart';
import '../ui/playback_controls.dart';

class PostVideoScreen extends StatefulWidget {
  const PostVideoScreen({
    required this.repository,
    required this.url,
    required this.title,
    super.key,
  });
  final Repository repository;
  final String url, title;
  @override
  State<PostVideoScreen> createState() => _PostVideoScreenState();
}

class _PostVideoScreenState extends State<PostVideoScreen> {
  bool _cinema = false;
  final _presentation = FullscreenSession();
  Future<void> _setFullscreen(bool value) async {
    await perform(context, () async {
      await _presentation.set(value);
      if (mounted) setState(() => _cinema = value);
    });
  }

  late final PlaybackSession _session;
  @override
  void initState() {
    super.initState();
    _session = PlaybackSession(widget.repository);
    unawaited(_open());
  }

  Future<void> _open() => _session.open(0, 1, directUrl: widget.url);
  @override
  void dispose() {
    unawaited(_session.close());
    unawaited(_presentation.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_cinema,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && _cinema) unawaited(_setFullscreen(false));
    },
    child: Scaffold(
      appBar: _cinema
          ? null
          : M3EAppBar.top(
              titleText: widget.title,
              automaticallyImplyLeading: true,
            ),
      body: SafeArea(
        child: CinemaLayout(
          video: Video(controller: _session.video, controls: NoVideoControls),
          controls: Padding(
            padding: const EdgeInsets.all(16),
            child: PlaybackControls(
              session: _session,
              episode: 1,
              onNext: null,
              onFullscreen: () => unawaited(_setFullscreen(!_cinema)),
              fullscreen: _cinema,
              onRetry: () => unawaited(_open()),
            ),
          ),
        ),
      ),
    ),
  );
}
