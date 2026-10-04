import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/skip/fingerprint_matcher.dart';

Uint32List _noise(Random random, int length) => Uint32List.fromList([
  for (var i = 0; i < length; i++) random.nextInt(1 << 32),
]);

int _points(double seconds) => (seconds / fingerprintPointSeconds).round();

void main() {
  group('matchFingerprints', () {
    test('finds a shared opening at different offsets', () {
      final random = Random(7);
      final opening = _noise(random, _points(90));
      final a = _noise(random, _points(600));
      final b = _noise(random, _points(600));
      final aAt = _points(24);
      final bAt = _points(150);
      a.setAll(aAt, opening);
      // A re-encode never reproduces the fingerprint exactly.
      b.setAll(bAt, [for (final v in opening) v ^ (1 << random.nextInt(32))]);

      final match = matchFingerprints(a, b);

      expect(match, isNotNull);
      expect(match!.aStart, closeTo(24, 0.5));
      expect(match.aEnd, closeTo(114, 0.5));
      expect(match.bStart, closeTo(150, 0.5));
      expect(match.bEnd, closeTo(240, 0.5));
    });

    test('bridges short gaps inside the match', () {
      final random = Random(11);
      final opening = _noise(random, _points(80));
      final a = _noise(random, _points(300));
      final b = _noise(random, _points(300));
      a.setAll(0, opening);
      final damaged = Uint32List.fromList(opening);
      // Two seconds of mismatch in the middle, e.g. a sponsor card overlay.
      for (var i = _points(40); i < _points(42); i++) {
        damaged[i] = ~damaged[i] & 0xFFFFFFFF;
      }
      b.setAll(_points(10), damaged);

      final match = matchFingerprints(a, b);

      expect(match, isNotNull);
      expect(match!.length, closeTo(80, 0.5));
    });

    test('returns null for unrelated audio', () {
      final random = Random(3);
      expect(
        matchFingerprints(_noise(random, 3000), _noise(random, 3000)),
        isNull,
      );
    });

    test('ignores matches shorter than the minimum', () {
      final random = Random(5);
      final jingle = _noise(random, _points(6));
      final a = _noise(random, _points(200))..setAll(100, jingle);
      final b = _noise(random, _points(200))..setAll(300, jingle);
      expect(matchFingerprints(a, b), isNull);
    });
  });

  group('consensusRange', () {
    test('takes the median of the largest cluster', () {
      final range = consensusRange([
        (30.0, 120.0),
        (31.0, 121.0),
        (300.0, 330.0),
        (30.5, 120.4),
      ]);
      expect(range, isNotNull);
      expect(range!.$1, closeTo(30.5, 0.01));
      expect(range.$2, closeTo(120.4, 0.01));
    });

    test('returns null with nothing to go on', () {
      expect(consensusRange([]), isNull);
    });
  });
}
