@Timeout(Duration(minutes: 30))
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/player/syncplay_watchdog.dart';

import 'support/syncplay_sim.dart';

const _speed = 20.0;

void main() {
  setUpSyncplayStorage();

  late VirtualClock clock;
  late SimSyncplayServer server;
  late SimViewer kai; // iPad, Australia, local baked file
  // iPhone, Nanning: streams through HK until the episode is downloaded.
  late SimViewer her;
  GapRecorder? gaps;
  final viewers = <SimViewer>[];

  Future<void> start(
    int seed, {
    double at = 60,
    int episode = 1,
    bool herLocal = false,
  }) async {
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
      loadTime: 0.3,
    );
    if (!herLocal) her.hosts = [SimHost('hk', 0.4), SimHost('sg', 6)];
    viewers.addAll([kai, her]);
    await kai.join(server, episode: episode, at: at);
    await her.join(server, episode: episode, at: at);
    gaps = GapRecorder(clock, kai, her);
    simNotices.clear();
  }

  Future<void> stop() async {
    gaps?.stop();
    gaps = null;
    for (final viewer in viewers.reversed) {
      await viewer.leave();
    }
    if (viewers.isNotEmpty) await server.close();
    viewers.clear();
  }

  Future<void> eachSeed(Future<void> Function(int seed) body) => forSeeds(
    labSeeds(),
    body,
    stop: stop,
    viewers: () => viewers,
    roomLog: () => [...server.roomPauseChanges, ...simNotices],
  );

  /// Registers [name] with her streaming through HK and [localName] with
  /// both playing downloads, which is most evenings.
  void bothWays(
    String name,
    String localName,
    Future<void> Function(int seed, bool local) body,
  ) {
    test(name, () => eachSeed((seed) => body(seed, false)));
    test(localName, () => eachSeed((seed) => body(seed, true)));
  }

  Future<void> reconnected() => clock.until(
    () =>
        her.sync.syncplayController?.isConnected == true &&
        !her.sync.reconnecting,
    timeout: 20,
    what: 'her to reconnect',
  );

  Iterable<String> unwantedPills() => simNotices.where(
    (n) => n.contains('同步中断') || n.contains('离开') || n.contains('加入'),
  );

  Future<void> settled({double within = 15}) => clock.until(
    () =>
        kai.episode == her.episode &&
        kai.playing &&
        her.playing &&
        (kai.position - her.position).abs() < 1,
    timeout: within,
    what: 'both playing within 1 s',
  );

  bothWays(
    '1 baseline: both finish ep 1 and move to ep 2 together once',
    'L1 both local: baseline, both move to ep 2 together once',
    (seed, local) async {
      await start(seed, at: 1380, herLocal: local);
      await clock.until(
        () => kai.episode == 2 && her.episode == 2,
        timeout: 90,
      );
      await settled(within: 10);
      expect(kai.episodeChanges, [2]);
      expect(her.episodeChanges, [2]);
      expect(her.reloads + kai.reloads, 0);
    },
  );

  bothWays(
    '2 her Wi-Fi to 4G at 12:00: reload same episode, resync, no skip',
    'L2 both local: her Wi-Fi to 4G at 12:00: only the room socket drops',
    (seed, local) async {
      await start(seed, at: 700, herLocal: local);
      await clock.wait(20);
      // A download keeps playing through the handover; a stream EOFs.
      if (!local) her.cutStream(recoverAfter: 6);
      server.zombie('her');
      her.switchNetwork(NetKind.cellular);
      await reconnected();
      await settled(within: 20);
      expect(her.episodeChanges, isEmpty);
      expect(kai.episodeChanges, isEmpty);
      if (local) {
        expect(her.reloads + kai.reloads, 0);
      } else {
        expect(her.reloads, inInclusiveRange(1, 2));
      }
      // Past the 15 s leave/join debounce.
      await clock.wait(16);
      expect(unwantedPills(), isEmpty);
    },
  );

  bothWays(
    '3 WeChat for 90 s: back to the room position, same episode',
    'L3 both local: WeChat for 90 s: back to the room position',
    (seed, local) async {
      await start(seed, at: 480, herLocal: local);
      await clock.wait(10);
      her.cutStream(recoverAfter: 0);
      server.zombie('her');
      await clock.wait(90);
      her.resumeAfter(90);
      await settled(within: 20);
      expect(her.episode, 1);
      expect(her.position, greaterThan(570));
    },
  );

  test(
    '4 flapping: 3 drops ok, a 4th inside 2 min gives up, retry recovers',
    () {
      return eachSeed((seed) async {
        await start(seed, at: 300);
        // 20 s apart: an outage only ends after 5 s of clean play, and with
        // the 2 s / 4 s retry gaps landing on 1 s ticks a 5 s outage can
        // take 11 s to recover. Three drops still fall inside a minute.
        for (var i = 0; i < 3; i++) {
          await clock.wait(20);
          her.cutStream(recoverAfter: 5);
        }
        await clock.wait(20);
        expect(her.giveUps, 0);
        expect(her.endGuard.incidents, 3);
        expect(her.reloads, inInclusiveRange(3, 6));
        her.cutStream(recoverAfter: 5);
        await clock.until(() => her.giveUps > 0, timeout: 20);
        expect(kai.episodeChanges, isEmpty);
        expect(kai.episode, 1);
        // The refresh button: reload at the last good position.
        await clock.wait(6);
        await her.changeEpisode(
          1,
          offset: her.endGuard.lastGoodPosition.inSeconds,
        );
        await clock.until(() => her.playing, timeout: 20, what: 'her back');
        // She is the slowest, so the room resumes from her spot and kai,
        // 6-10 s ahead, closes the gap at 0.95x: up to 3 minutes.
        await settled(within: 180);
      });
    },
  );

  test('5 HK relay refuses: two reloads on HK, the third on Singapore', () {
    return eachSeed((seed) async {
      await start(seed, at: 300);
      await clock.wait(10);
      her.hosts[0].downUntil = clock.seconds + 30;
      her.cutStream(recoverAfter: 0);
      await clock.until(() => her.hostIndex == 1 && her.playing, timeout: 40);
      expect(her.reloads, 3);
      await settled(within: 30);
    });
  });

  bothWays(
    '6 drop inside the last 30 s counts as the end; one change each',
    'L6 both local: drop inside the last 30 s counts as the end',
    (seed, local) async {
      await start(seed, at: 1400, herLocal: local);
      await clock.wait(25);
      her.cutStream(recoverAfter: 0);
      await clock.until(
        () => kai.episode == 2 && her.episode == 2,
        timeout: 60,
      );
      expect(her.episodeChanges, [2]);
      expect(kai.episodeChanges, [2]);
    },
  );

  bothWays(
    '7 kai finished first; her drop at -60 s keeps followEpisode',
    'L7 both local: kai finished first; her socket reset keeps followEpisode',
    (seed, local) async {
      await start(seed, at: 1400, herLocal: local);
      her.autoPlayNext = false;
      // Kai waits (等 TA) for anyone more than 10 s behind, so she can only
      // be a minute back at his end if he tapped 不等了. Dropping her back in
      // his last second stands in for that: he finishes before he notices.
      await clock.until(() => kai.position >= 1438.8, timeout: 60);
      her.place(kai.position - 60);
      await clock.until(() => kai.episode == 2, timeout: 5);
      await clock.until(() => her.sync.followEpisode == 2, timeout: 10);
      if (local) {
        await server.reset('her');
        await clock.until(() => her.sync.reconnectAttempts > 0, timeout: 5);
        await reconnected();
      } else {
        her.cutStream(recoverAfter: 3);
      }
      await clock.until(() => her.playing && her.episode == 1, timeout: 20);
      expect(her.sync.followEpisode, 2);
      await clock.until(() => her.episode == 2, timeout: 120);
      await settled(within: 30);
    },
  );

  bothWays(
    '7b followEpisode also survives a reload after a reconnect',
    'L7b both local: followEpisode survives a reconnect',
    (seed, local) async {
      await start(seed, at: 1400, herLocal: local);
      her.autoPlayNext = false;
      await clock.until(() => kai.position >= 1438.8, timeout: 60);
      her.place(kai.position - 60);
      await clock.until(() => kai.episode == 2, timeout: 5);
      await clock.until(() => her.sync.followEpisode == 2, timeout: 10);
      if (!local) her.cutStream(recoverAfter: 3);
      server.zombie('her');
      her.switchNetwork(NetKind.cellular);
      await reconnected();
      await clock.until(() => her.playing && her.episode == 1, timeout: 20);
      expect(her.sync.followEpisode, 2);
    },
  );

  bothWays(
    '8 SyncPlay socket reset only: no stream reload, back in sync',
    'L8 both local: SyncPlay socket reset only',
    (seed, local) async {
      await start(seed, at: 300, herLocal: local);
      await clock.wait(10);
      await server.reset('her');
      await clock.until(() => her.sync.reconnectAttempts > 0, timeout: 5);
      await reconnected();
      await settled(within: 20);
      expect(her.reloads, 0);
    },
  );

  test(
    '10 truncated local file on kai: 3 reloads then error, nobody advances',
    () {
      return eachSeed((seed) async {
        await start(seed, at: 1000);
        await clock.wait(5);
        kai.cutStream();
        await clock.until(() => kai.giveUps > 0, timeout: 60);
        expect(kai.reloads, 3);
        expect(kai.episodeChanges, isEmpty);
        expect(her.episodeChanges, isEmpty);
      });
    },
  );

  test('11 natural end still advances (regression guard)', () {
    return eachSeed((seed) async {
      await start(seed, at: 1430);
      await clock.until(() => kai.episode == 2, timeout: 60);
    });
  });

  test(
    '12 kai pauses while she reloads: she lands paused at the room spot',
    () {
      return eachSeed((seed) async {
        await start(seed, at: 400);
        await clock.wait(5);
        her.cutStream(recoverAfter: 3);
        await clock.wait(1);
        await kai.userPause();
        // The first reload can land while the stream is still down; wait for
        // the one that loads.
        await clock.until(
          () => !her.loading && !her.completed && her.reloads > 0,
          timeout: 20,
        );
        await clock.wait(5);
        expect(her.playing, isFalse);
        expect((kai.position - her.position).abs(), lessThan(1.5));
      });
    },
  );

  bothWays(
    '12b a paused room stays paused through her reconnect and reload',
    'L12b both local: a paused room stays paused through her reconnect',
    (seed, local) async {
      await start(seed, at: 400, herLocal: local);
      await clock.wait(5);
      if (!local) her.cutStream(recoverAfter: 3);
      server.zombie('her');
      her.switchNetwork(NetKind.cellular);
      await clock.wait(1);
      await kai.userPause();
      if (local) {
        await reconnected();
      } else {
        await clock.until(
          () => !her.loading && !her.completed && her.reloads > 0,
          timeout: 20,
        );
      }
      await clock.wait(5);
      expect(kai.playing, isFalse, reason: 'her reload resumed the room');
      expect(her.playing, isFalse);
      expect((kai.position - her.position).abs(), lessThan(1.5));
    },
  );
}
