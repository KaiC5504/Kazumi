import 'package:kazumi/pages/player/player_controller.dart';

typedef EpisodeChanger =
    Future<void> Function(int episode, {int currentRoad, int offset});

/// Lets whoever launched an offline playback follow it, e.g. to join the
/// watch-together room and download ahead.
abstract class OfflinePlaybackHooks {
  void onEpisodeStarted(
    int episodeNumber,
    PlayerController player,
    EpisodeChanger changeEpisode,
  );

  void onPlaybackClosed();

  /// A streamed episode failed on [failedUrl]'s host; the player moved on.
  void onStreamHostFailed(String failedUrl) {}
}
