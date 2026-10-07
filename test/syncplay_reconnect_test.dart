@Timeout(Duration(minutes: 6))
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
  late GapRecorder gaps;

  Future<void> start({int seed = 1}) async {
    clock = VirtualClock(_speed);
    server = await SimSyncplayServer.start(clock, seed: seed);
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
    await me.join(server, at: 60);
    await her.join(server, at: 60);
    gaps = GapRecorder(clock, me, her);
    // Joining shows its own pills; the tests are about what comes after.
    simNotices.clear();
  }

  tearDown(() async {
    gaps.stop();
    await her.leave();
    await me.leave();
    await server.close();
  });

  test(
    'zombie socket after Wi-Fi to 4G: back in sync within 15 s, no tap',
    () async {
      await start();
      // She joined about 1.6 s after him, inside the 3 s the drift corrector
      // leaves alone; line them up so the drift check below means something.
      her.place(me.position);
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
    },
  );

  test(
    'silent zombie without a network event is caught by the watchdog',
    () async {
      await start(seed: 2);
      await clock.wait(20);
      final t0 = clock.seconds;
      server.zombie('her');
      await clock.until(
        () => her.sync.reconnectAttempts > 0,
        timeout: 15,
        what: 'watchdog to fire',
      );
      // Checked on 1 s ticks: the probe lands 6-7 s after her last State
      // and the reconnect 3-4 s after that. Under load the last tick can
      // slip just past 11.
      expect(clock.seconds - t0, inInclusiveRange(8.5, 11.5));
    },
  );

  test('server-side reset reconnects instead of 同步中断', () async {
    await start(seed: 3);
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

  test('no network for 20 s holds, then reconnects at once', () async {
    await start(seed: 4);
    await clock.wait(20);
    server.zombie('her');
    her.switchNetwork(NetKind.none);
    await clock.wait(20);
    expect(her.sync.reconnectAttempts, 0);
    her.switchNetwork(NetKind.wifi);
    await clock.until(() => her.sync.reconnectAttempts > 0, timeout: 3);
  });

  test('a server that accepts and never answers ends in 同步中断', () async {
    await start(seed: 5);
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

  test('her old connection timing out later keeps her in the room', () async {
    await start(seed: 6);
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

  test('he reconnects after missing her rejoin: no stale 离开了', () async {
    await start(seed: 7);
    await clock.wait(20);
    await server.reset('her');
    await clock.wait(0.5); // her 'left' reaches him and waits out the debounce
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

  test('a new room on another network joins normally, not quietly', () async {
    await start(seed: 8);
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
}
