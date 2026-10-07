import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/player/player_controller.dart';
import 'package:kazumi/services/player/anime_speed_store.dart';
import 'package:kazumi/services/player/audio_controller.dart';
import 'package:kazumi/services/shaders/shader_asset_service.dart';
import 'package:kazumi/services/storage/storage.dart';

import 'support/syncplay_sim.dart' show setUpSyncplayStorage;

class _NoDownloads implements DownloadController {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  setUpSyncplayStorage();

  setUp(() async {
    await GStorage.putSetting<String>(SettingsKeys.animeSpeeds, '{}');
    await GStorage.putSetting<double>(SettingsKeys.defaultPlaySpeed, 1.0);
  });

  test('leaving a room restores the anime speed at once', () async {
    await AnimeSpeedStore.remember(42, 1.5, inRoom: false);
    final player = PlayerController(
      ShaderAssetService(),
      _NoDownloads(),
      AudioController(),
    )..bangumiId = 42;
    player.playback.playerSpeed = 1.0;
    await player.exitSyncPlayRoom();
    expect(player.playback.playerSpeed, 1.5);
  });
}
