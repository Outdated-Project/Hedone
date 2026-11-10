import 'dart:async';

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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_cinema,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && _cinema) setState(() => _cinema = false);
    },
    child: Scaffold(
      appBar: _cinema
          ? null
          : M3EAppBar.top(
              titleText: widget.title,
              automaticallyImplyLeading: true,
            ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Video(
                controller: _session.video,
                controls: NoVideoControls,
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: PlaybackControls(
                session: _session,
                episode: 1,
                onNext: null,
                onFullscreen: () => setState(() => _cinema = !_cinema),
                fullscreen: _cinema,
                onRetry: () => unawaited(_open()),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
