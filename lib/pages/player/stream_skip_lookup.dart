import 'package:kazumi/pages/player/player_controller.dart';
import 'package:kazumi/services/skip/aniskip_client.dart';
import 'package:kazumi/services/storage/storage.dart';

/// Streams never went through the PC, so AniSkip is their only source of skip
/// times. AniSkip matches on episode length, which is only known once the
/// player has opened the stream.
Future<void> loadStreamSkipSegments(
  PlayerController player,
  PlaybackInitParams params,
  bool Function() isActive,
) async {
  if (!GStorage.getSetting(SettingsKeys.aniSkipLookup)) return;
  var duration = Duration.zero;
  for (var i = 0; i < 40 && isActive(); i++) {
    duration = player.playback.playerDuration;
    if (duration > Duration.zero) break;
    await Future.delayed(const Duration(milliseconds: 500));
  }
  if (!isActive() || duration <= Duration.zero) return;
  final segments = await AniSkipClient.instance.lookup(
    params.bangumiId,
    params.sortNumber ?? params.danmakuEpisodeNumber,
    duration.inMilliseconds / 1000,
  );
  if (isActive() && player.videoUrl == params.videoUrl) {
    player.skipSegments = segments;
  }
}
