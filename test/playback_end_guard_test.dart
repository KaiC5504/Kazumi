import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/player/playback_end_guard.dart';

void main() {
  late DateTime now;
  late PlaybackEndGuard guard;
  const len = Duration(minutes: 24);

  setUp(() {
    now = DateTime(2026, 10, 7, 21);
    guard = PlaybackEndGuard(clock: () => now)..onEpisodeStarted('1[5]');
  });

  void wait(int s) => now = now.add(Duration(seconds: s));
  void playTo(Duration p) =>
      guard.onTick(position: p, playing: true, completed: false);
  EndDecision complete(Duration p, {bool resumedNearEnd = false}) => guard
      .onCompleted(position: p, duration: len, resumedNearEnd: resumedNearEnd);

  /// Ticks once a second with the stream broken until the guard acts.
  EndDecision brokenUntilAction(Duration p, {int maxSeconds = 30}) {
    for (var i = 0; i < maxSeconds; i++) {
      final d = complete(p);
      if (d.action != EndAction.none) return d;
      wait(1);
    }
    fail('guard never acted');
  }

  test("unknown duration keeps today's behaviour", () {
    expect(
      guard
          .onCompleted(
            position: Duration.zero,
            duration: Duration.zero,
            resumedNearEnd: false,
          )
          .action,
      EndAction.trueEnd,
    );
  });

  test('stale near-end resume replays', () {
    expect(complete(len, resumedNearEnd: true).action, EndAction.replay);
  });

  test('completion within 30 s of the end is the real end, at once', () {
    playTo(len - const Duration(seconds: 12));
    expect(
      complete(len - const Duration(seconds: 12)).action,
      EndAction.trueEnd,
    );
  });

  test('mid-episode EOF waits 2 s, then reloads at the last good position', () {
    playTo(const Duration(minutes: 12));
    expect(complete(const Duration(minutes: 12)).action, EndAction.none);
    wait(1);
    expect(complete(const Duration(minutes: 12)).action, EndAction.none);
    wait(1);
    final d = complete(const Duration(minutes: 12));
    expect(d.action, EndAction.reload);
    expect(d.resumeAt, const Duration(minutes: 12));
    expect(d.switchHost, isFalse);
  });

  test('uses the last good position when mpv reports a bogus one', () {
    playTo(const Duration(minutes: 8));
    final d = brokenUntilAction(Duration.zero);
    expect(d.action, EndAction.reload);
    expect(d.resumeAt, const Duration(minutes: 8));
  });

  test('ignores completed ticks while a reload is loading', () {
    playTo(const Duration(minutes: 8));
    expect(
      brokenUntilAction(const Duration(minutes: 8)).action,
      EndAction.reload,
    );
    wait(5);
    expect(complete(const Duration(minutes: 8)).action, EndAction.none);
  });

  test('one outage: attempts 2 s, 4 s, 8 s apart; the third switches host; '
      'then gives up once', () {
    playTo(const Duration(minutes: 8));
    final gaps = <int>[];
    final switches = <bool>[];
    var t = 0;
    for (var attempt = 0; attempt < 3; attempt++) {
      final start = t;
      EndDecision d;
      while ((d = complete(const Duration(minutes: 8))).action ==
          EndAction.none) {
        wait(1);
        t++;
      }
      expect(d.action, EndAction.reload);
      gaps.add(t - start);
      switches.add(d.switchHost);
      guard.onEpisodeStarted('1[5]'); // the reload loads and fails again
    }
    expect(gaps, [2, 4, 8]);
    expect(switches, [false, false, true]);
    expect(complete(const Duration(minutes: 8)).action, EndAction.giveUp);
    wait(1);
    expect(
      complete(const Duration(minutes: 8)).action,
      EndAction.none,
      reason: 'reports the failure once, not every tick',
    );
  });

  test(
    'a reload that plays 5 s ends the outage; the next drop starts fresh',
    () {
      playTo(const Duration(minutes: 8));
      brokenUntilAction(const Duration(minutes: 8));
      guard.onEpisodeStarted('1[5]');
      for (var s = 1; s <= 6; s++) {
        wait(1);
        playTo(Duration(minutes: 8, seconds: s));
      }
      expect(guard.attempts, 0);
      final d = brokenUntilAction(const Duration(minutes: 8, seconds: 6));
      expect(d.switchHost, isFalse);
      expect(guard.incidents, 2);
    },
  );

  test('mpv recovering by itself mid-wait restarts the gap', () {
    playTo(const Duration(minutes: 8));
    expect(complete(const Duration(minutes: 8)).action, EndAction.none);
    for (var s = 1; s <= 3; s++) {
      wait(1);
      playTo(Duration(minutes: 8, seconds: s));
    }
    const p = Duration(minutes: 8, seconds: 3);
    expect(complete(p).action, EndAction.none);
    wait(1);
    expect(complete(p).action, EndAction.none);
    wait(1);
    expect(complete(p).action, EndAction.reload);
  });

  test('three separate outages are fine; a fourth within 2 min gives up', () {
    for (var i = 0; i < 3; i++) {
      playTo(Duration(minutes: 5 + i));
      expect(
        brokenUntilAction(Duration(minutes: 5 + i)).action,
        EndAction.reload,
      );
      guard.onEpisodeStarted('1[5]');
      for (var s = 1; s <= 6; s++) {
        wait(1);
        playTo(Duration(minutes: 5 + i, seconds: s));
      }
    }
    expect(guard.incidents, 3);
    expect(complete(const Duration(minutes: 9)).action, EndAction.giveUp);
  });

  test('retry after giving up gets a fresh budget', () {
    for (var i = 0; i < 3; i++) {
      playTo(Duration(minutes: 5 + i));
      brokenUntilAction(Duration(minutes: 5 + i));
      guard.onEpisodeStarted('1[5]');
      for (var s = 1; s <= 6; s++) {
        wait(1);
        playTo(Duration(minutes: 5 + i, seconds: s));
      }
    }
    expect(complete(const Duration(minutes: 9)).action, EndAction.giveUp);
    guard.onEpisodeStarted('1[5]'); // the refresh button
    expect(guard.incidents, 0);
    expect(
      brokenUntilAction(const Duration(minutes: 9)).action,
      EndAction.reload,
    );
  });

  test('two clean minutes refill the outage budget', () {
    playTo(const Duration(minutes: 5));
    brokenUntilAction(const Duration(minutes: 5));
    guard.onEpisodeStarted('1[5]');
    for (var s = 0; s <= 121; s++) {
      wait(1);
      playTo(Duration(minutes: 5, seconds: s));
    }
    expect(guard.incidents, 0);
  });

  test('a new episode resets everything', () {
    playTo(const Duration(minutes: 3));
    brokenUntilAction(const Duration(minutes: 3));
    guard.onEpisodeStarted('1[6]');
    expect(guard.incidents, 0);
    expect(guard.attempts, 0);
    expect(guard.lastGoodPosition, Duration.zero);
  });

  test('a seek to the end finishes the episode', () {
    playTo(const Duration(minutes: 10));
    guard.onSeek(len);
    expect(complete(len).action, EndAction.trueEnd);
  });

  test('a seek to just before the end finishes the episode', () {
    playTo(const Duration(minutes: 10));
    guard.onSeek(len - const Duration(milliseconds: 500));
    expect(complete(len).action, EndAction.trueEnd);
  });

  test('a stale tick from before the seek is ignored', () {
    playTo(const Duration(minutes: 22, seconds: 30));
    guard.onSeek(len);
    playTo(const Duration(minutes: 22, seconds: 30));
    expect(complete(len).action, EndAction.trueEnd);
  });

  test('ticks count again once the seek has landed', () {
    playTo(const Duration(minutes: 20));
    guard.onSeek(const Duration(minutes: 10));
    playTo(const Duration(minutes: 20));
    expect(guard.lastGoodPosition, const Duration(minutes: 10));
    wait(1);
    playTo(const Duration(minutes: 10, seconds: 1));
    wait(1);
    playTo(const Duration(minutes: 10, seconds: 2));
    expect(
      brokenUntilAction(const Duration(minutes: 10, seconds: 2)).resumeAt,
      const Duration(minutes: 10, seconds: 2),
    );
  });

  test('a seek that never lands stops masking ticks', () {
    guard.onSeek(const Duration(minutes: 10));
    wait(PlaybackEndGuard.seekSettle.inSeconds);
    playTo(const Duration(minutes: 4));
    expect(guard.lastGoodPosition, const Duration(minutes: 4));
  });

  test('retry only resumes the episode the position belongs to', () {
    playTo(const Duration(minutes: 23, seconds: 10));
    expect(
      guard.resumeFor(PlaybackEndGuard.keyFor(1, 5)),
      const Duration(minutes: 23, seconds: 10),
    );
    expect(guard.resumeFor(PlaybackEndGuard.keyFor(1, 6)), Duration.zero);
  });
}
