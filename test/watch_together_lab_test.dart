@Timeout(Duration(minutes: 30))
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/player/syncplay_watchdog.dart';

import 'support/syncplay_sim.dart';

const _speed = 20.0;

// Product bugs these scenarios found; unskip once fixed.
const _reannounceBug =
    'After a SyncPlay reconnect the new client has no own file name, so '
    'PlayerController.init treats a same-episode reload as a new episode: '
    'it announces position 0 and playing, and setPlayingBangumi clears '
    'followEpisode.';
const _reloadReportsZeroBug =
    'While a same-episode reload loads, the player reports position 0 to '
    'the room; a paused room then moves everyone to 0.';

void main() {
  setUpSyncplayStorage();

  late VirtualClock clock;
  late SimSyncplayServer server;
  late SimViewer kai; // iPad, Australia, local baked file
  late SimViewer her; // iPhone, Nanning, streams through HK
  GapRecorder? gaps;
  final viewers = <SimViewer>[];

  Future<void> start(int seed, {double at = 60, int episode = 1}) async {
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
    )..hosts = [SimHost('hk', 0.4), SimHost('sg', 6)];
    viewers.addAll([kai, her]);
    await kai.join(server, episode: episode, at: at);
    await her.join(server, episode: episode, at: at);
    // She joined about 1.6 s after him, inside the 3 s the drift corrector
    // leaves alone; line them up so "within 1 s" means something.
    her.place(kai.position);
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

  Future<void> settled({double within = 15}) => clock.until(
    () =>
        kai.episode == her.episode &&
        kai.playing &&
        her.playing &&
        (kai.position - her.position).abs() < 1,
    timeout: within,
    what: 'both playing within 1 s',
  );

  test('1 baseline: both finish ep 1 and move to ep 2 together once', () {
    return eachSeed((seed) async {
      await start(seed, at: 1380);
      await clock.until(
        () => kai.episode == 2 && her.episode == 2,
        timeout: 90,
      );
      await settled(within: 10);
      expect(kai.episodeChanges, [2]);
      expect(her.episodeChanges, [2]);
      expect(her.reloads + kai.reloads, 0);
    });
  });

  test('2 her Wi-Fi to 4G at 12:00: reload same episode, resync, no skip', () {
    return eachSeed((seed) async {
      await start(seed, at: 700);
      await clock.wait(20);
      her.cutStream(recoverAfter: 6);
      server.zombie('her');
      her.switchNetwork(NetKind.cellular);
      await settled(within: 20);
      expect(her.episodeChanges, isEmpty);
      expect(kai.episodeChanges, isEmpty);
      expect(her.reloads, inInclusiveRange(1, 2));
    });
  }, skip: _reannounceBug);

  test('3 WeChat for 90 s: back to the room position, same episode', () {
    return eachSeed((seed) async {
      await start(seed, at: 480);
      await clock.wait(10);
      her.cutStream(recoverAfter: 0);
      server.zombie('her');
      await clock.wait(90);
      her.resumeAfter(90);
      await settled(within: 20);
      expect(her.episode, 1);
      expect(her.position, greaterThan(570));
    });
  });

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

  test('6 drop inside the last 30 s counts as the end; one change each', () {
    return eachSeed((seed) async {
      await start(seed, at: 1400);
      await clock.wait(25);
      her.cutStream(recoverAfter: 0);
      await clock.until(
        () => kai.episode == 2 && her.episode == 2,
        timeout: 60,
      );
      expect(her.episodeChanges, [2]);
      expect(kai.episodeChanges, [2]);
    });
  });

  test('7 kai finished first; her drop at -60 s keeps followEpisode', () {
    return eachSeed((seed) async {
      await start(seed, at: 1400);
      her.autoPlayNext = false;
      // Kai waits (等 TA) for anyone more than 10 s behind, so she can only
      // be a minute back at his end if he tapped 不等了. Dropping her back in
      // his last second stands in for that: he finishes before he notices.
      await clock.until(() => kai.position >= 1438.8, timeout: 60);
      her.place(kai.position - 60);
      await clock.until(() => kai.episode == 2, timeout: 5);
      await clock.until(() => her.sync.followEpisode == 2, timeout: 10);
      her.cutStream(recoverAfter: 3);
      await clock.until(() => her.playing && her.episode == 1, timeout: 20);
      expect(her.sync.followEpisode, 2);
      await clock.until(() => her.episode == 2, timeout: 120);
      await settled(within: 30);
    });
  });

  test('7b followEpisode also survives a reload after a reconnect', () {
    return eachSeed((seed) async {
      await start(seed, at: 1400);
      her.autoPlayNext = false;
      await clock.until(() => kai.position >= 1438.8, timeout: 60);
      her.place(kai.position - 60);
      await clock.until(() => kai.episode == 2, timeout: 5);
      await clock.until(() => her.sync.followEpisode == 2, timeout: 10);
      her.cutStream(recoverAfter: 3);
      server.zombie('her');
      her.switchNetwork(NetKind.cellular);
      await clock.until(
        () => her.playing && her.episode == 1 && !her.sync.reconnecting,
        timeout: 20,
      );
      expect(her.sync.followEpisode, 2);
    });
  }, skip: _reannounceBug);

  test('8 SyncPlay socket reset only: no stream reload, back in sync', () {
    return eachSeed((seed) async {
      await start(seed, at: 300);
      await clock.wait(10);
      await server.reset('her');
      await settled(within: 20);
      expect(her.reloads, 0);
    });
  });

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
    skip: _reloadReportsZeroBug,
  );

  test('12b a paused room stays paused through her reconnect and reload', () {
    return eachSeed((seed) async {
      await start(seed, at: 400);
      await clock.wait(5);
      her.cutStream(recoverAfter: 3);
      server.zombie('her');
      her.switchNetwork(NetKind.cellular);
      await clock.wait(1);
      await kai.userPause();
      await clock.until(
        () => !her.loading && !her.completed && her.reloads > 0,
        timeout: 20,
      );
      await clock.wait(5);
      expect(kai.playing, isFalse, reason: 'her reload resumed the room');
      expect(her.playing, isFalse);
      expect((kai.position - her.position).abs(), lessThan(1.5));
    });
  }, skip: _reannounceBug);
}
