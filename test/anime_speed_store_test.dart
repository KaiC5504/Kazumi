import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/player/anime_speed_store.dart';
import 'package:kazumi/services/storage/storage.dart';

import 'support/syncplay_sim.dart' show setUpSyncplayStorage;

void main() {
  setUpSyncplayStorage();

  setUp(() async {
    await GStorage.putSetting<String>(SettingsKeys.animeSpeeds, '{}');
    await GStorage.putSetting<double>(SettingsKeys.defaultPlaySpeed, 1.0);
  });

  test('unknown anime uses the default speed', () {
    expect(AnimeSpeedStore.speedFor(42, inRoom: false), 1.0);
  });

  test('remembers per anime', () async {
    await AnimeSpeedStore.remember(42, 1.25, inRoom: false);
    await AnimeSpeedStore.remember(7, 1.5, inRoom: false);
    expect(AnimeSpeedStore.speedFor(42, inRoom: false), 1.25);
    expect(AnimeSpeedStore.speedFor(7, inRoom: false), 1.5);
  });

  test('in a room it is always 1.0 and nothing is saved', () async {
    await AnimeSpeedStore.remember(42, 1.25, inRoom: false);
    expect(AnimeSpeedStore.speedFor(42, inRoom: true), 1.0);
    await AnimeSpeedStore.remember(42, 1.5, inRoom: true);
    expect(AnimeSpeedStore.speedFor(42, inRoom: false), 1.25);
  });

  test('corrupt storage falls back to the default', () async {
    await GStorage.putSetting<String>(SettingsKeys.animeSpeeds, '{oops');
    expect(AnimeSpeedStore.speedFor(42, inRoom: false), 1.0);
  });
}
