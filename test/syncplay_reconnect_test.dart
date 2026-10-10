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
  late SimViewer me;
  late SimViewer her;
  GapRecorder? gaps;
  final viewers = <SimViewer>[];

  Future<void> start({int seed = 1, bool renames = false}) async {
    clock = VirtualClock(_speed);
    server = await SimSyncplayServer.start(clock, seed: seed, renames: renames);
    me = SimViewer(
      'kai',
      clock,
      network: NetworkProfile.australiaToHk,
      episodeLength: 1440,
    );
    her = SimViewer(
      'her',
      clock,
      network: NetworkProfile.nanningToHk,
      episodeLength: 1440,
    );
    viewers.addAll([me, her]);
    await me.join(server, at: 60);
    await her.join(server, at: 60);
    gaps = GapRecorder(clock, me, her);
    // Joining shows its own pills; the tests are about what comes after.
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

  /// Runs [body] for `LAB_SEEDS` seeds counting up from [first].
  Future<void> eachSeed(int first, Future<void> Function(int seed) body) =>
      forSeeds(
        labSeeds(first: first),
        body,
        stop: stop,
        viewers: () => viewers,
      );

  test('zombie socket after Wi-Fi to 4G: back in sync within 15 s, no tap', () {
    return eachSeed(1, (seed) async {
      await start(seed: seed);
      await clock.wait(30);
      final t0 = clock.seconds;
      server.zombie('her');
      her.switchNetwork(NetKind.cellular); // the interface change arrives too
      await clock.until(
        () =>
            her.sync.syncplayController?.isConnected == true &&
            !her.sync.reconnecting,
        timeout: 30,
        what: 'her to reconnect',
      );
      await clock.until(
        () => (me.position - her.position).abs() < 1,
        timeout: 15,
        what: 'drift under 1 s',
      );
      expect(clock.seconds - t0, lessThan(15));
      expect(her.sync.reconnectAttempts, greaterThan(0));
      // The new connection carries room state again: his pause reaches her.
      await me.userPause();
      await clock.until(() => !her.playing, timeout: 5, what: 'her to pause');
      expect(me.episode, 1);
      expect(her.episode, 1);
      expect(
        simNotices.where((n) => n.contains('离开') || n.contains('加入')),
        isEmpty,
      );
    });
  });

  test('silent zombie without a network event is caught by the watchdog', () {
    return eachSeed(2, (seed) async {
      await start(seed: seed);
      await clock.wait(20);
      final t0 = clock.seconds;
      server.zombie('her');
      await clock.until(
        () => her.sync.reconnectAttempts > 0,
        timeout: 15,
        what: 'watchdog to fire',
      );
      // Checked on 1 s ticks: the probe lands 6-7 s after her last State
      // and the reconnect 3-4 s after that, so 9-10 s. At 20x a virtual
      // second is 50 ms real, about three Windows timer slices, so under
      // load one tick can land a whole virtual second late.
      expect(clock.seconds - t0, inInclusiveRange(8.5, 12.5));
    });
  });

  test('server-side reset reconnects instead of 同步中断', () {
    return eachSeed(3, (seed) async {
      await start(seed: seed);
      await clock.wait(20);
      await server.reset('her');
      await clock.until(
        () => her.sync.reconnectAttempts > 0,
        timeout: 5,
        what: 'her to notice the reset',
      );
      await clock.until(
        () =>
            her.sync.syncplayController?.isConnected == true &&
            !her.sync.reconnecting,
        timeout: 20,
        what: 'her back',
      );
      expect(simNotices.where((n) => n.contains('同步中断')), isEmpty);
      // His side saw her leave and rejoin; past the 15 s debounce that
      // still shows nothing.
      await clock.wait(16);
      expect(
        simNotices.where((n) => n.contains('离开') || n.contains('加入')),
        isEmpty,
      );
    });
  });

  test('no network for 20 s holds, then reconnects at once', () {
    return eachSeed(4, (seed) async {
      await start(seed: seed);
      await clock.wait(20);
      server.zombie('her');
      her.switchNetwork(NetKind.none);
      await clock.wait(20);
      expect(her.sync.reconnectAttempts, 0);
      her.switchNetwork(NetKind.wifi);
      await clock.until(() => her.sync.reconnectAttempts > 0, timeout: 3);
    });
  });

  test('a server that accepts and never answers ends in 同步中断', () {
    return eachSeed(5, (seed) async {
      await start(seed: seed);
      await clock.wait(20);
      server.silence('her');
      server.zombie('her');
      her.switchNetwork(NetKind.cellular);
      await clock.until(
        () => simNotices.any((n) => n.contains('同步中断')),
        timeout: 80,
        what: '同步中断',
      );
      expect(her.sync.reconnecting, isFalse);
      expect(her.sync.syncplayController, isNull);
      expect(her.sync.reconnectAttempts, 8);
      expect(simNotices.where((n) => n.contains('已重新同步')), isEmpty);
      await clock.wait(20);
      expect(her.sync.reconnectAttempts, 8);
    });
  });

  test('a server that answers Hello and then goes quiet ends in 同步中断', () {
    return eachSeed(10, (seed) async {
      await start(seed: seed);
      await clock.wait(20);
      server.hollow('her');
      server.zombie('her');
      her.switchNetwork(NetKind.cellular);
      await clock.until(
        () => simNotices.any((n) => n.contains('同步中断')),
        timeout: 60,
        what: '同步中断',
      );
      expect(her.sync.reconnecting, isFalse);
      expect(her.sync.syncplayController, isNull);
      final attempts = her.sync.reconnectAttempts;
      expect(attempts, 3);
      await clock.wait(30);
      expect(her.sync.reconnectAttempts, attempts);
    });
  });

  test('the 1.0× lock holds through reconnects and 同步中断 until she leaves', () {
    return eachSeed(11, (seed) async {
      await start(seed: seed);
      await clock.wait(20);
      expect(her.sync.speedLocked, isTrue);
      server.hollow('her');
      server.zombie('her');
      her.switchNetwork(NetKind.cellular);
      await clock.until(
        () {
          expect(her.sync.speedLocked, isTrue);
          return simNotices.any((n) => n.contains('同步中断'));
        },
        timeout: 60,
        what: '同步中断',
      );
      expect(her.sync.inRoom, isFalse);
      expect(her.sync.speedLocked, isTrue);
      await her.sync.exitRoom();
      expect(her.sync.speedLocked, isFalse);
    });
  });

  test('her old connection timing out later keeps her in the room', () {
    return eachSeed(6, (seed) async {
      await start(seed: seed);
      await clock.wait(20);
      server.zombie('her');
      her.switchNetwork(NetKind.cellular);
      await clock.until(
        () =>
            her.sync.syncplayController?.isConnected == true &&
            !her.sync.reconnecting,
        timeout: 20,
        what: 'her to reconnect',
      );
      expect(server.watchersNamed('her'), 2);
      server.dropGhosts('her');
      await clock.wait(20);
      expect(me.sync.peers, contains('her'));
      expect(her.sync.peers, contains('kai'));
      expect(
        simNotices.where((n) => n.contains('离开') || n.contains('加入')),
        isEmpty,
      );
    });
  });

  test('renamed rejoin (Syncplay her_): same person, no pills either side', () {
    return eachSeed(12, (seed) async {
      await start(seed: seed, renames: true);
      await clock.wait(20);
      server.zombie('her');
      her.switchNetwork(NetKind.cellular);
      await clock.until(
        () =>
            her.sync.syncplayController?.isConnected == true &&
            !her.sync.reconnecting,
        timeout: 20,
        what: 'her to reconnect',
      );
      expect(her.sync.syncplayController?.username, 'her_');
      await clock.wait(5);
      expect(me.sync.peers, ['her_']);
      server.dropGhosts('her');
      await clock.wait(20);
      expect(me.sync.peers, ['her_']);
      expect(her.sync.peers, ['kai']);
      expect(
        simNotices.where((n) => n.contains('离开') || n.contains('加入')),
        isEmpty,
      );
      expect(gaps!.lastGap, lessThan(1.5));
    });
  });

  test('he reconnects after missing her rejoin: no stale 离开了', () {
    return eachSeed(7, (seed) async {
      await start(seed: seed);
      await clock.wait(20);
      await server.reset('her');
      await clock.wait(
        0.5,
      ); // her 'left' reaches him and waits out the debounce
      server.zombie('kai'); // so her 'joined' never reaches him
      await clock.until(
        () =>
            her.sync.syncplayController?.isConnected == true &&
            !her.sync.reconnecting,
        timeout: 20,
        what: 'her to reconnect',
      );
      server.dropGhosts('kai');
      me.switchNetwork(NetKind.cellular);
      await clock.until(
        () =>
            me.sync.syncplayController?.isConnected == true &&
            !me.sync.reconnecting,
        timeout: 20,
        what: 'kai to reconnect',
      );
      await clock.wait(20);
      expect(me.sync.peers, contains('her'));
      expect(
        simNotices.where((n) => n.contains('离开') || n.contains('加入')),
        isEmpty,
      );
    });
  });

  test('a new room on another network joins normally, not quietly', () {
    return eachSeed(8, (seed) async {
      await start(seed: seed);
      await clock.wait(10);
      await her.sync.exitRoom();
      simNotices.clear();
      await her.reconnect(server);
      // The new room's first connectivity check finds 4G this time.
      her.switchNetwork(NetKind.cellular);
      await clock.wait(5);
      expect(her.sync.reconnectAttempts, 0);
      expect(simNotices, contains('已跟上 kai 的进度'));
    });
  });

  test('server restart: both reconnect, and her later leave still counts', () {
    return eachSeed(9, (seed) async {
      await start(seed: seed);
      await clock.wait(10);
      await server.reset('kai');
      await server.reset('her');
      await clock.until(
        () =>
            me.sync.syncplayController?.isConnected == true &&
            !me.sync.reconnecting &&
            her.sync.syncplayController?.isConnected == true &&
            !her.sync.reconnecting,
        timeout: 30,
        what: 'both back',
      );
      await clock.wait(5);
      expect(me.sync.peers, contains('her'));
      expect(her.sync.peers, contains('kai'));
      expect(
        simNotices.where((n) => n.contains('离开') || n.contains('加入')),
        isEmpty,
      );
      await her.leave();
      viewers.remove(her);
      await clock.wait(25);
      expect(me.sync.peers, isNot(contains('her')));
      expect(simNotices, contains('her 离开了'));
    });
  });

  test('leaving on purpose shows 离开了 at once, and only once', () {
    return eachSeed(1, (seed) async {
      await start(seed: seed);
      await clock.wait(5);
      final chat = <String>[];
      final sub = me.sync.chatStream.listen((m) => chat.add(m.message));
      await her.leave();
      viewers.remove(her);
      await clock.until(
        () => simNotices.contains('her 离开了'),
        timeout: 2,
        what: 'the pill without the 15 s debounce',
      );
      expect(me.sync.peers, isNot(contains('her')));
      await clock.wait(25);
      expect(simNotices.where((n) => n == 'her 离开了'), hasLength(1));
      expect(chat, isEmpty, reason: 'the goodbye is not a chat message');
      await sub.cancel();
    });
  });

  test('back after leaving on purpose shows 加入了', () {
    return eachSeed(1, (seed) async {
      await start(seed: seed);
      await clock.wait(5);
      await her.leave();
      viewers.remove(her);
      await clock.until(() => simNotices.contains('her 离开了'), timeout: 2);
      final again = SimViewer(
        'her',
        clock,
        network: NetworkProfile.nanningToHk,
        episodeLength: 1440,
      );
      viewers.add(again);
      await again.join(server, at: 60);
      await clock.until(
        () => simNotices.contains('her 加入了'),
        timeout: 5,
        what: 'her 加入了',
      );
      expect(me.sync.peers, contains('her'));
    });
  });

  test('alone in the room, leaving sends no goodbye and does not wait', () {
    return eachSeed(1, (seed) async {
      await start(seed: seed);
      await her.leave();
      viewers.remove(her);
      await clock.until(() => simNotices.contains('her 离开了'), timeout: 2);
      final before = clock.seconds;
      await me.leave();
      viewers.remove(me);
      await server.close();
      // Waiting out the goodbye's echo would take 20 s at this clock speed.
      expect(clock.seconds - before, lessThan(2));
    });
  });
}
