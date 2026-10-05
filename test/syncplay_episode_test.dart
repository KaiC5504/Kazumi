@Timeout(Duration(minutes: 4))
library;

import 'package:flutter_test/flutter_test.dart';

import 'support/syncplay_sim.dart';

// Moving between episodes together. Episodes are 6 minutes long here so the
// scenarios start near the end.
const _speed = 20.0;

void main() {
  setUpSyncplayStorage();

  late VirtualClock clock;
  late SimSyncplayServer server;
  late SimViewer me;
  late SimViewer her;
  late GapRecorder gaps;

  Future<void> startWatching({
    required double mine,
    required double hers,
    NetworkProfile herNetwork = NetworkProfile.nanningToHk,
    double herLoadTime = 1.5,
    bool herAutoPlayNext = true,
    int seed = 1,
  }) async {
    clock = VirtualClock(_speed);
    server = await SimSyncplayServer.start(clock, seed: seed);
    me = SimViewer('kai', clock, network: NetworkProfile.australiaToHk);
    her = SimViewer(
      'her',
      clock,
      network: herNetwork,
      loadTime: herLoadTime,
      autoPlayNext: herAutoPlayNext,
    );
    await me.join(server, at: mine - 20);
    await her.join(server, at: mine - 20);
    // Let her settle into the room first, so the gap set up below is drift
    // rather than a fresh join.
    await clock.wait(10);
    me.place(mine);
    her.place(hers);
    gaps = GapRecorder(clock, me, her);
    server.roomPauseChanges.clear();
  }

  tearDown(() async {
    gaps.stop();
    await her.leave();
    await me.leave();
    await server.close();
  });

  String logs() =>
      [...me.log, ...her.log, ...server.roomPauseChanges].join('\n');

  bool bothPlaying(int episode) =>
      me.episode == episode &&
      her.episode == episode &&
      !me.loading &&
      !her.loading &&
      me.playing &&
      her.playing;

  void expectNoSpinners() {
    expect(me.syncSeeksWhilePlaying, isEmpty, reason: logs());
    expect(her.syncSeeksWhilePlaying, isEmpty, reason: logs());
  }

  test(
    'you finish first: you wait at the start, she sees her whole ending',
    () async {
      await startWatching(mine: 340.5, hers: 338);
      await clock.until(
        () => me.episode == 2 && !me.loading && !me.playing,
        timeout: 40,
        what: 'kai to wait at the start of episode 2',
      );
      await clock.until(() => bothPlaying(2), timeout: 30, what: 'both on 2');
      expect(her.furthest[1], greaterThan(359), reason: logs());
      expect(
        her.syncPauses,
        0,
        reason: 'your wait never paused her\n${logs()}',
      );
      expect(
        server.roomPauseChanges.where((c) => c.contains('paused')),
        isEmpty,
        reason: logs(),
      );
      await clock.wait(30);
      expectNoSpinners();
      expect(gaps.lastGap, lessThan(2), reason: '$gaps\n${logs()}');
    },
  );

  test('her next episode takes 8 s to load: you start when she does', () async {
    await startWatching(mine: 340.5, hers: 339, herLoadTime: 8);
    await clock.until(() => bothPlaying(2), timeout: 60, what: 'both on 2');
    await clock.wait(30);
    expectNoSpinners();
    expect(gaps.maxGap, lessThan(2.5), reason: '$gaps\n${logs()}');
  });

  test(
    'she skips to the next episode mid-way: you follow, she waits for you',
    () async {
      await startWatching(mine: 100, hers: 100);
      await clock.wait(5);
      await her.changeEpisode(2);
      await clock.until(() => bothPlaying(2), timeout: 30, what: 'both on 2');
      expect(her.syncPauses, 1, reason: 'she waited for you\n${logs()}');
      await clock.wait(30);
      expectNoSpinners();
      expect(gaps.lastGap, lessThan(2), reason: '$gaps\n${logs()}');
    },
  );

  test(
    'auto-play next is off on her phone: she still follows you at the end',
    () async {
      await startWatching(mine: 340.5, hers: 338, herAutoPlayNext: false);
      await clock.until(() => bothPlaying(2), timeout: 60, what: 'both on 2');
      expect(her.furthest[1], greaterThan(359), reason: logs());
      expect(her.sync.followEpisode, isNull);
    },
  );

  test('she leaves while you wait: you carry on alone', () async {
    await startWatching(mine: 345, hers: 340);
    await clock.until(
      () => me.episode == 2 && !me.loading && !me.playing,
      timeout: 40,
      what: 'kai to wait',
    );
    await her.leave();
    await clock.until(() => me.playing, timeout: 10, what: 'kai to resume');
  });

  test(
    'you press play while waiting: you go ahead, she catches up later',
    () async {
      await startWatching(mine: 345, hers: 335);
      await clock.until(
        () => me.episode == 2 && !me.loading && !me.playing,
        timeout: 40,
        what: 'kai to wait',
      );
      await me.userPlay();
      expect(her.episode, 1, reason: 'pressing play does not drag her along');
      await clock.until(() => bothPlaying(2), timeout: 60, what: 'both on 2');
      await clock.wait(5);
      final arrivalGap = (me.position - her.position).abs();
      await clock.wait(90);
      expectNoSpinners();
      expect(
        gaps.lastGap,
        lessThan(arrivalGap - 3),
        reason: 'closing at 5%\n$gaps\n${logs()}',
      );
    },
  );

  test(
    'you both finish at the same moment: nobody gets stuck waiting',
    () async {
      await startWatching(mine: 345, hers: 345);
      await clock.until(() => bothPlaying(2), timeout: 40, what: 'both on 2');
      await clock.wait(20);
      expect(me.playing && her.playing, isTrue, reason: logs());
      expectNoSpinners();
      expect(gaps.lastGap, lessThan(2), reason: '$gaps\n${logs()}');
    },
  );

  test('her lossy evening line at the boundary', () async {
    await startWatching(
      mine: 340.5,
      hers: 338,
      herNetwork: NetworkProfile.nanningToSgEvening,
      seed: 3,
    );
    await clock.until(() => bothPlaying(2), timeout: 60, what: 'both on 2');
    expect(her.furthest[1], greaterThan(359), reason: logs());
    await clock.wait(40);
    expectNoSpinners();
    expect(gaps.lastGap, lessThan(3), reason: '$gaps\n${logs()}');
  });

  test('three episodes in a row stay together', () async {
    await startWatching(mine: 330, hers: 329);
    await clock.until(() => bothPlaying(2), timeout: 60, what: 'both on 2');
    me.place(330);
    her.place(328.5);
    await clock.until(() => bothPlaying(3), timeout: 60, what: 'both on 3');
    await clock.wait(20);
    expectNoSpinners();
    expect(her.furthest[2], greaterThan(359), reason: logs());
    expect(gaps.lastGap, lessThan(2), reason: '$gaps\n${logs()}');
  });
}
