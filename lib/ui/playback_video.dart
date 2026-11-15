import 'package:media_kit_video/media_kit_video.dart';

import '../core/playback_session.dart';
import 'design.dart';

/// The session owns initialization failures and lifecycle policy. Building a
/// placeholder must not retry a failed native constructor outside that boundary.
class PlaybackVideo extends StatelessWidget {
  const PlaybackVideo({required this.session, super.key});
  final PlaybackSession session;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final controller = session.videoIfCreated;
      return controller == null
          ? const SizedBox.expand()
          : Video(
              controller: controller,
              controls: NoVideoControls,
              pauseUponEnteringBackgroundMode: false,
            );
    },
  );
}
