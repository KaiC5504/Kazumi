@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/pages/player/controller/player_syncplay_controller.dart';
import 'package:kazumi/services/storage/storage.dart';

import 'support/syncplay_sim.dart';

/// A controller with no player page ticking it, as while an episode loads.
PlayerSyncPlayController _untickedController(VirtualClock clock) =>
    PlayerSyncPlayController(
      bangumiId: () => 1,
      currentEpisode: () => 1,
      currentRoad: () => 0,
      playing: () => false,
      currentPosition: () => Duration.zero,
      playerPosition: () => Duration.zero,
      duration: () => Duration.zero,
      completed: () => false,
      pause: ({bool enableSync = true}) async {},
      play: ({bool enableSync = true}) async {},
      seek: (Duration to, {bool enableSync = true}) async {},
      setRateFactor: (double factor) async {},
      clock: clock.now,
    );

Future<void> _noEpisodeChange(
  int episode, {
  int currentRoad = 0,
  int offset = 0,
}) async {}

void main() {
  setUpSyncplayStorage();

  test('inRoom holds through a quiet reconnect, driven without player '
      'ticks', () async {
    final clock = VirtualClock(20);
    final server = await SimSyncplayServer.start(clock);
    final sync = _untickedController(clock);
    final joins = <bool>[];
    sync.onJoinedRoom = ({required bool quiet}) => joins.add(quiet);
    await GStorage.putSetting(
      SettingsKeys.syncPlayEndPoint,
      '127.0.0.1:${server.port}',
    );
    await sync.createRoom('room', 'her', _noEpisodeChange);
    await clock.until(
      () => sync.syncplayController?.username == 'her',
      what: 'her to join',
    );
    expect(sync.inRoom, isTrue);
    expect(joins, [false]);

    server.zombie('her');
    await clock.until(
      () {
        expect(sync.inRoom, isTrue);
        return joins.length == 2 && !sync.reconnecting;
      },
      timeout: 80,
      what: 'a quiet reconnect',
    );
    expect(joins.last, isTrue);
    expect(sync.reconnectAttempts, greaterThan(0));

    await sync.exitRoom();
    expect(sync.inRoom, isFalse);
    await server.close();
  });

  test('a first connect that fails leaves no room behind', () async {
    final clock = VirtualClock(20);
    final socket = await ServerSocket.bind('127.0.0.1', 0);
    final port = socket.port;
    await socket.close();
    final sync = _untickedController(clock);
    await GStorage.putSetting(SettingsKeys.syncPlayEndPoint, '127.0.0.1:$port');
    simNotices.clear();
    await sync.createRoom('room', 'her', _noEpisodeChange);
    expect(sync.inRoom, isFalse);
    expect(simNotices, contains('连不上同步服务器'));
    await sync.dispose();
  });
}
