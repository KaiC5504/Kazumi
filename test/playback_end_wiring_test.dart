import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/player/playback_end_guard.dart';

void main() {
  const len = Duration(minutes: 24);
  late DateTime now;
  late PlaybackEndGuard guard;
  setUp(() {
    now = DateTime(2026, 10, 7, 21);
    guard = PlaybackEndGuard(clock: () => now)..onEpisodeStarted('1[5]');
  });

  ({EndStep step, EndDecision? decision}) tick(
    Duration p, {
    bool completed = true,
    bool auto = true,
    bool room = false,
    bool next = true,
  }) => decideEndStep(
    guard: guard,
    completed: completed,
    loading: false,
    position: p,
    duration: len,
    playing: !completed,
    resumedNearEnd: false,
    hasNextEpisode: next,
    autoPlayNext: auto,
    roomWantsNext: room,
  );

  void wait(int s) => now = now.add(Duration(seconds: s));

  test('single advance at the real end even with the room asking too', () {
    tick(len - const Duration(seconds: 2), completed: false);
    expect(tick(len, room: true).step, EndStep.advance);
  });

  test('follows the room when autoplay is off', () {
    tick(len - const Duration(seconds: 2), completed: false);
    expect(tick(len, auto: false, room: true).step, EndStep.followRoom);
  });

  test('mid-episode EOF reloads instead of advancing', () {
    const at = Duration(minutes: 10);
    tick(at, completed: false);
    var r = tick(at, room: true);
    for (var i = 0; i < 10 && r.step == EndStep.nothing; i++) {
      wait(1);
      r = tick(at, room: true);
    }
    expect(r.step, EndStep.reload);
    expect(r.decision!.resumeAt, at);
  });

  test('both hosts down: three reloads, the third switches host, then one '
      'giveUp and silence', () {
    const at = Duration(minutes: 10);
    tick(at, completed: false);
    final steps = <EndStep>[];
    final switches = <bool>[];
    for (var s = 0; s < 40; s++) {
      final r = tick(at);
      if (r.step != EndStep.nothing) {
        steps.add(r.step);
        if (r.step == EndStep.reload) {
          switches.add(r.decision!.switchHost);
          guard.onEpisodeStarted('1[5]');
        }
      }
      wait(1);
    }
    expect(steps, [
      EndStep.reload,
      EndStep.reload,
      EndStep.reload,
      EndStep.giveUp,
    ]);
    expect(switches, [false, false, true]);
  });
}
