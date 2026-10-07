@Timeout(Duration(minutes: 30))
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/player/syncplay_watchdog.dart';

import 'support/syncplay_sim.dart';

// What the room sees while one player reloads its episode, through the real
// sync controller and client. Her only host is slow, so a load takes 6 s.
const _speed = 20.0;

void main() {
  setUpSyncplayStorage();

  late VirtualClock clock;
  late SimSyncplayServer server;
  late SimViewer kai;
  late SimViewer her;
  final viewers = <SimViewer>[];

  Future<void> start(int seed) async {
    clock = VirtualClock(_speed);
    server = await SimSyncplayServer.start(clock, seed: seed);
    kai = SimViewer(
      'kai',
      clock,
      network: NetworkProfile.australiaToHk,
      episodeLength: 1440,
      loadTime: 0.2,
    );
    her = SimViewer(
      'her',
      clock,
      network: NetworkProfile.nanningToHk,
      episodeLength: 1440,
    )..hosts = [SimHost('sg', 6)];
    viewers.addAll([kai, her]);
    await kai.join(server, at: 300);
    await her.join(server, at: 300);
    simNotices.clear();
  }

  Future<void> stop() async {
    for (final viewer in viewers.reversed) {
      await viewer.leave();
    }
    if (viewers.isNotEmpty) await server.close();
    viewers.clear();
  }

  Future<void> eachSeed(int first, Future<void> Function(int seed) body) =>
      forSeeds(
        labSeeds(first: first),
        body,
        stop: stop,
        viewers: () => viewers,
        roomLog: () => [...server.roomPauseChanges, ...simNotices],
      );

  Future<void> reconnected() => clock.until(
    () =>
        her.sync.syncplayController?.isConnected == true &&
        !her.sync.reconnecting,
    timeout: 20,
    what: 'her to reconnect',
  );

  test('a same-episode reload reports where it resumes, not 0', () {
    return eachSeed(1, (seed) async {
      await start(seed);
      await clock.wait(10);
      her.cutStream(recoverAfter: 0);
      await clock.until(() => her.loading, timeout: 10, what: 'the reload');
      final resumeAt = her.endGuard.lastGoodPosition.inSeconds;
      await clock.wait(4);
      expect(her.loading, isTrue);
      expect(server.positionOf('her'), greaterThanOrEqualTo(resumeAt - 0.5));
      expect(kai.syncPauses, 0, reason: 'nobody waits on a phantom 0:00');
    });
  });

  test('a new episode still reports 0 while it loads', () {
    return eachSeed(11, (seed) async {
      await start(seed);
      await clock.wait(10);
      unawaited(her.changeEpisode(2));
      await clock.wait(4);
      expect(her.loading, isTrue);
      expect(server.positionOf('her'), lessThan(1.5));
      await clock.until(() => server.fileOf('her') == '1[2]', timeout: 10);
    });
  });

  test('a reload after a reconnect announces nothing until caught up', () {
    return eachSeed(21, (seed) async {
      await start(seed);
      await clock.wait(10);
      her.cutStream(recoverAfter: 0);
      server.zombie('her');
      her.switchNetwork(NetKind.cellular);
      await reconnected();
      expect(server.fileOf('her'), isNull);
      await clock.until(
        () => !her.loading && her.reloads > 0 && her.playing,
        timeout: 20,
        what: 'the reload',
      );
      // The catch-up path announces the same file once she is level.
      await clock.until(
        () => server.fileOf('her') == '1[1]',
        timeout: 10,
        what: 'her announce',
      );
      expect(server.positionOf('her'), greaterThan(300));
      expect((kai.position - her.position).abs(), lessThan(3));
      expect(
        server.roomPauseChanges.where((c) => c.startsWith('her')),
        isEmpty,
      );
    });
  });

  test('a reload after a reconnect keeps a paused room paused', () {
    return eachSeed(31, (seed) async {
      await start(seed);
      await clock.wait(10);
      await kai.userPause();
      await clock.until(() => !her.playing, timeout: 5, what: 'her to pause');
      her.cutStream(recoverAfter: 0);
      server.zombie('her');
      her.switchNetwork(NetKind.cellular);
      await reconnected();
      await clock.until(
        () => !her.loading && her.reloads > 0 && !her.completed,
        timeout: 20,
        what: 'the reload',
      );
      await clock.wait(5);
      expect(kai.playing, isFalse);
      expect(her.playing, isFalse);
      expect(
        server.roomPauseChanges.where((c) => c.startsWith('her')),
        isEmpty,
      );
    });
  });

  test('an episode change after a reconnect still announces from 0', () {
    return eachSeed(41, (seed) async {
      await start(seed);
      await clock.wait(10);
      server.zombie('her');
      her.switchNetwork(NetKind.cellular);
      await reconnected();
      await clock.until(
        () => server.fileOf('her') == '1[1]',
        timeout: 10,
        what: 'her catch-up announce',
      );
      await her.changeEpisode(2);
      await clock.until(
        () => server.fileOf('her') == '1[2]',
        timeout: 5,
        what: 'her announce',
      );
      expect(her.sync.followEpisode, isNull);
      await clock.until(() => kai.episode == 2, timeout: 10, what: 'kai');
    });
  });
}
