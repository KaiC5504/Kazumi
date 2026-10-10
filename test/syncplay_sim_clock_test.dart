import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/syncplay_sim.dart';

void main() {
  test('a frozen test process does not skip simulated time', () async {
    final clock = VirtualClock(20);
    await clock.wait(1);
    final before = clock.seconds;
    // Blocks the isolate the way a busy PC does; 12 s at 20x without the cap.
    sleep(const Duration(milliseconds: 600));
    final during = clock.seconds;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final after = clock.seconds;
    expect(during - before, lessThan(1.5));
    expect(after, greaterThanOrEqualTo(during));
    expect(after - before, lessThan(2));
  });

  test('the clock still runs normally between freezes', () async {
    final clock = VirtualClock(20);
    final before = clock.seconds;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(clock.seconds - before, closeTo(10, 1.5));
  });

  test('a 1x clock keeps real time through a freeze', () {
    final clock = VirtualClock(1);
    sleep(const Duration(milliseconds: 300));
    expect(clock.seconds, greaterThan(0.29));
  });
}
