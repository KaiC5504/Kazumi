import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/player/syncplay_drift.dart';

void main() {
  group('SyncDriftCorrector', () {
    late DateTime now;
    late SyncDriftCorrector drift;

    setUp(() {
      now = DateTime(2026);
      drift = SyncDriftCorrector(clock: () => now);
    });

    test('leaves drift under three seconds alone', () {
      for (final gap in [0.4, -1.5, 2.9, -2.9]) {
        expect(drift.update(gap), (seek: false, rate: null, wait: false));
      }
    });

    test('slows down when ahead until within a second', () {
      expect(drift.update(5), (seek: false, rate: 0.95, wait: false));
      expect(drift.update(3), (seek: false, rate: null, wait: false));
      expect(drift.update(1.5), (seek: false, rate: null, wait: false));
      expect(drift.update(0.8), (seek: false, rate: 1.0, wait: false));
      expect(drift.rateFactor, 1.0);
    });

    test('speeds up when behind', () {
      expect(drift.update(-4), (seek: false, rate: 1.05, wait: false));
      expect(drift.update(-0.5), (seek: false, rate: 1.0, wait: false));
    });

    test('stops nudging if the gap flips sides', () {
      drift.update(4);
      expect(drift.update(-2), (seek: false, rate: 1.0, wait: false));
    });

    test('far behind: seeks only after the gap is seen three times', () {
      expect(drift.update(-15), (seek: false, rate: null, wait: false));
      expect(drift.update(-15), (seek: false, rate: null, wait: false));
      expect(drift.update(-15), (seek: true, rate: null, wait: false));
    });

    test('far ahead: waits instead of seeking back', () {
      drift.update(15);
      drift.update(15);
      expect(drift.update(15), (seek: false, rate: null, wait: true));
    });

    test('a single big gap between normal ones never acts', () {
      for (var i = 0; i < 5; i++) {
        expect(drift.update(15).wait, isFalse);
        expect(drift.update(-15).seek, isFalse);
        drift.update(0.5);
      }
    });

    test('acting on a big gap restores the normal rate', () {
      drift.update(5);
      drift.update(12);
      drift.update(12);
      expect(drift.update(12), (seek: false, rate: 1.0, wait: true));
    });

    test('does nothing for eight seconds after a jump', () {
      drift.holdOff();
      expect(drift.update(20), (seek: false, rate: null, wait: false));
      expect(drift.update(5), (seek: false, rate: null, wait: false));
      now = now.add(const Duration(seconds: 9));
      expect(drift.update(5), (seek: false, rate: 0.95, wait: false));
    });
  });

  group('SyncplayRttWindow', () {
    test('median ignores one slow sample', () {
      final rtt = SyncplayRttWindow();
      for (final sample in [0.05, 0.06, 0.05, 2.0, 0.07]) {
        rtt.add(sample);
      }
      expect(rtt.median, 0.06);
    });

    test('a message far slower than usual is late', () {
      final rtt = SyncplayRttWindow();
      for (final sample in [0.2, 0.22, 0.21]) {
        rtt.add(sample);
      }
      expect(rtt.isLate(0.25), isFalse);
      expect(rtt.isLate(0.9), isTrue);
    });

    test('a fast link never calls a sub-300ms message late', () {
      final rtt = SyncplayRttWindow();
      for (final sample in [0.02, 0.02, 0.02]) {
        rtt.add(sample);
      }
      expect(rtt.isLate(0.25), isFalse);
    });

    test('needs a few samples before judging', () {
      final rtt = SyncplayRttWindow()..add(0.05);
      expect(rtt.isLate(3), isFalse);
    });
  });
}
