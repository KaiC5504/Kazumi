@Timeout(Duration(minutes: 4))
library;

import 'package:flutter_test/flutter_test.dart';

import 'support/syncplay_sim.dart';

// Two people watching the same episode, through the real sync controller and
// client, over simulated links. 20x time: a 5 minute scenario takes 15 s.
const _speed = 20.0;

void main() {
  setUpSyncplayStorage();

  late VirtualClock clock;
  late SimSyncplayServer server;
  late SimViewer me;
  late SimViewer her;
  late GapRecorder gaps;

  Future<void> startWatching({
    NetworkProfile mine = NetworkProfile.australiaToHk,
    NetworkProfile hers = NetworkProfile.nanningToHk,
    double mySkew = 1.0,
    double herSkew = 1.0,
    double startGap = 0.3,
    int seed = 1,
  }) async {
    clock = VirtualClock(_speed);
    server = await SimSyncplayServer.start(clock, seed: seed);
    me = SimViewer(
      'kai',
      clock,
      network: mine,
      skew: mySkew,
      episodeLength: 1440,
    );
    her = SimViewer(
      'her',
      clock,
      network: hers,
      skew: herSkew,
      episodeLength: 1440,
    );
    await me.join(server, at: 60);
    await her.join(server, at: 60);
    // Joins start level, but a slow join leaves both well past 60 and the
    // server already holds that. Moving her back would put her behind the
    // room before she has announced, and her catch-up would jump her. Let
    // the catch-up finish instead: a late first message on a lossy line can
    // still make it jump once, which is by design and not what these tests
    // watch for.
    await clock.until(
      () => server.fileOf('her') != null,
      what: 'her to catch up',
    );
    me.place(her.position + startGap);
    me.seeks.clear();
    her.seeks.clear();
    gaps = GapRecorder(clock, me, her);
    server.roomPauseChanges.clear();
  }

  tearDown(() async {
    gaps.stop();
    await her.leave();
    await me.leave();
    await server.close();
  });

  void expectNoSpinners() {
    expect(
      me.syncSeeksWhilePlaying,
      isEmpty,
      reason: 'kai jumped:\n${me.log.join('\n')}',
    );
    expect(
      her.syncSeeksWhilePlaying,
      isEmpty,
      reason: 'she jumped:\n${her.log.join('\n')}',
    );
  }

  test(
    'iPad and iPhone on the same Wi-Fi stay together without jumps',
    () async {
      await startWatching(
        mine: NetworkProfile.sameWifi,
        hers: NetworkProfile.sameWifi,
        herSkew: 0.9995,
      );
      await clock.wait(300);
      expectNoSpinners();
      expect(gaps.maxGap, lessThan(3), reason: '$gaps');
    },
  );

  test('Australia and Nanning both through Hong Kong', () async {
    await startWatching();
    await clock.wait(300);
    expectNoSpinners();
    expect(gaps.maxGap, lessThan(3), reason: '$gaps');
    expect(me.rates, isEmpty, reason: 'no drift to correct');
  });

  test('her old congested route: late messages cause no jumps', () async {
    await startWatching(
      mine: const NetworkProfile(
        'Australia to Singapore',
        rtt: 0.209,
        jitter: 0.02,
      ),
      hers: NetworkProfile.nanningToSgEvening,
    );
    await clock.wait(300);
    expectNoSpinners();
    expect(gaps.p95, lessThan(3), reason: '$gaps');
  });

  test(
    'a device clock running 1% fast is reined in by speed, not jumps',
    () async {
      await startWatching(mySkew: 1.01);
      await clock.wait(300);
      expectNoSpinners();
      expect(me.rates, isNotEmpty, reason: 'drifts 3s every 5 minutes');
      expect(gaps.maxGap, lessThan(4.5), reason: '$gaps');
    },
  );

  test('her buffering for 6 s: you slow down to let her catch up', () async {
    await startWatching(hers: NetworkProfile.nanningToSgEvening);
    await clock.wait(30);
    her.stall(6);
    await clock.wait(170);
    expectNoSpinners();
    expect(me.rates.first, 0.95, reason: me.log.join('\n'));
    expect(gaps.lastGap, lessThan(1.5), reason: '$gaps\n${me.log.join('\n')}');
  });

  test(
    'her buffering for 25 s: you wait for her instead of jumping back',
    () async {
      await startWatching(hers: NetworkProfile.nanningToSgEvening);
      await clock.wait(20);
      her.stall(25);
      await clock.until(() => !me.playing, timeout: 20, what: 'kai to wait');
      expect(
        server.roomPauseChanges,
        isEmpty,
        reason: 'waiting is local; she must not be paused',
      );
      await clock.until(() => me.playing, timeout: 40, what: 'kai to carry on');
      await clock.wait(60);
      expectNoSpinners();
      expect(me.syncPauses, 1, reason: me.log.join('\n'));
      expect(gaps.lastGap, lessThan(3), reason: '$gaps\n${me.log.join('\n')}');
    },
  );

  test(
    'she joins late at the start: she jumps to you, you never wait',
    () async {
      clock = VirtualClock(_speed);
      server = await SimSyncplayServer.start(clock);
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
      await me.join(server, at: 600);
      await her.join(server, at: 0);
      gaps = GapRecorder(clock, me, her);
      await clock.wait(30);
      expect(me.syncPauses, 0, reason: me.log.join('\n'));
      expect(me.seeks, isEmpty);
      expect(
        her.seeks.first.to,
        closeTo(me.position - 25, 6),
        reason: her.log.join('\n'),
      );
      await clock.wait(60);
      expect(gaps.lastGap, lessThan(3), reason: '$gaps');
      expect(me.syncSeeksWhilePlaying, isEmpty);
    },
  );

  test('you pause, she pauses; you resume, she resumes', () async {
    await startWatching();
    await clock.wait(20);
    await me.userPause();
    await clock.until(() => !her.playing, timeout: 3, what: 'her to pause');
    await clock.wait(15);
    expect(
      her.playing,
      isFalse,
      reason: [...me.log, ...her.log, ...server.roomPauseChanges].join('\n'),
    );
    expect((me.position - her.position).abs(), lessThan(1.2));
    await me.userPlay();
    await clock.until(() => her.playing, timeout: 3, what: 'her to resume');
    await clock.wait(30);
    expectNoSpinners();
    expect(gaps.lastGap, lessThan(1.5), reason: '$gaps');
  });

  test('she skips ahead 90 s: you jump with her right away', () async {
    await startWatching(hers: NetworkProfile.nanningToSgEvening);
    await clock.wait(20);
    final target = her.position + 90;
    await her.userSeek(target);
    await clock.until(
      () => me.seeks.isNotEmpty,
      timeout: 6,
      what: 'kai to follow',
    );
    expect(me.seeks.single.to, closeTo(target, 1.5));
    await clock.wait(30);
    expect(me.seeks, hasLength(1), reason: me.log.join('\n'));
    expect(gaps.lastGap, lessThan(2), reason: '$gaps');
  });

  test('her connection drops and she reconnects 8 s behind', () async {
    await startWatching(hers: NetworkProfile.nanningToSgEvening);
    await clock.wait(20);
    her.place(her.position - 8);
    await her.reconnect(server);
    await clock.wait(60);
    expect(me.syncSeeksWhilePlaying, isEmpty, reason: me.log.join('\n'));
    expect(
      her.syncSeeksWhilePlaying,
      hasLength(1),
      reason: 'one catch-up jump on rejoining\n${her.log.join('\n')}',
    );
    expect(gaps.lastGap, lessThan(3), reason: '$gaps\n${her.log.join('\n')}');
  });

  test('her old evening line, 5 minutes, several loss patterns', () async {
    for (final seed in [11, 12, 13]) {
      await startWatching(
        mine: const NetworkProfile(
          'Australia to Singapore',
          rtt: 0.209,
          jitter: 0.02,
        ),
        hers: NetworkProfile.nanningToSgEvening,
        herSkew: 0.9997,
        seed: seed,
      );
      await clock.wait(300);
      expectNoSpinners();
      expect(gaps.p95, lessThan(3), reason: 'seed $seed: $gaps');
      if (seed != 13) {
        gaps.stop();
        await her.leave();
        await me.leave();
        await server.close();
      }
    }
  });

  test('she pauses on a lossy line; the pause still arrives', () async {
    await startWatching(hers: NetworkProfile.nanningToSgEvening, seed: 7);
    await clock.wait(20);
    await her.userPause();
    await clock.until(() => !me.playing, timeout: 8, what: 'kai to pause');
    await her.userPlay();
    await clock.until(() => me.playing, timeout: 8, what: 'kai to resume');
    await clock.wait(40);
    expectNoSpinners();
  });
}
