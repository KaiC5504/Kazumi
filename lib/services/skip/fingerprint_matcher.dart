import 'dart:typed_data';

/// Seconds of audio covered by one raw chromaprint point (default algorithm,
/// 11025 Hz input).
const double fingerprintPointSeconds = 0.1238;

class FingerprintMatch {
  const FingerprintMatch(this.aStart, this.aEnd, this.bStart, this.bEnd);

  /// Seconds into each fingerprint.
  final double aStart;
  final double aEnd;
  final double bStart;
  final double bEnd;

  double get length => aEnd - aStart;

  @override
  String toString() =>
      'a ${aStart.toStringAsFixed(1)}-${aEnd.toStringAsFixed(1)}, '
      'b ${bStart.toStringAsFixed(1)}-${bEnd.toStringAsFixed(1)}';
}

/// Finds the longest stretch of audio [a] and [b] have in common, the way
/// Jellyfin's intro-skipper does: candidate alignments come from an inverted
/// index of fingerprint values, then each alignment is walked for points
/// within [maxBitDifference] bits, allowing gaps up to [maxGapSeconds].
FingerprintMatch? matchFingerprints(
  Uint32List a,
  Uint32List b, {
  double minSeconds = 15,
  double maxSeconds = 130,
  int maxBitDifference = 6,
  double maxGapSeconds = 3.5,
}) {
  final minPoints = (minSeconds / fingerprintPointSeconds).ceil();
  if (a.length < minPoints || b.length < minPoints) return null;

  final bIndex = <int, int>{};
  for (var j = 0; j < b.length; j++) {
    bIndex[b[j]] = j;
  }
  final shifts = <int>{};
  for (var i = 0; i < a.length; i++) {
    final value = a[i];
    // Neighbouring values catch points whose low bits jitter between encodes.
    for (var delta = -2; delta <= 2; delta++) {
      final j = bIndex[value + delta];
      if (j != null) shifts.add(j - i);
    }
  }

  final maxGapPoints = (maxGapSeconds / fingerprintPointSeconds).floor();
  var bestStart = -1;
  var bestEnd = -1;
  var bestShift = 0;
  for (final shift in shifts) {
    final from = shift < 0 ? -shift : 0;
    final to = a.length < b.length - shift ? a.length : b.length - shift;
    if (to - from < minPoints) continue;

    var runStart = -1;
    var runEnd = -1;
    void closeRun() {
      if (runStart < 0) return;
      final points = runEnd - runStart + 1;
      final seconds = points * fingerprintPointSeconds;
      if (points >= minPoints &&
          seconds <= maxSeconds &&
          points > bestEnd - bestStart + 1) {
        bestStart = runStart;
        bestEnd = runEnd;
        bestShift = shift;
      }
    }

    for (var i = from; i < to; i++) {
      if (_popCount(a[i] ^ b[i + shift]) > maxBitDifference) continue;
      if (runStart >= 0 && i - runEnd > maxGapPoints) {
        closeRun();
        runStart = -1;
      }
      if (runStart < 0) runStart = i;
      runEnd = i;
    }
    closeRun();
  }

  if (bestStart < 0) return null;
  double t(int index) => index * fingerprintPointSeconds;
  return FingerprintMatch(
    t(bestStart),
    t(bestEnd + 1),
    t(bestStart + bestShift),
    t(bestEnd + 1 + bestShift),
  );
}

/// Picks the range most comparisons agree on. One episode compared against
/// several others gives one candidate per comparison; an outlier (a recap, a
/// shared scene) loses to the cluster with the most members.
(double, double)? consensusRange(
  List<(double, double)> candidates, {
  double toleranceSeconds = 3,
}) {
  if (candidates.isEmpty) return null;
  List<(double, double)>? best;
  for (final pivot in candidates) {
    final cluster = [
      for (final c in candidates)
        if ((c.$1 - pivot.$1).abs() <= toleranceSeconds) c,
    ];
    if (best == null ||
        cluster.length > best.length ||
        (cluster.length == best.length &&
            _median(cluster.map((c) => c.$2 - c.$1)) >
                _median(best.map((c) => c.$2 - c.$1)))) {
      best = cluster;
    }
  }
  return (_median(best!.map((c) => c.$1)), _median(best.map((c) => c.$2)));
}

double _median(Iterable<double> values) {
  final sorted = values.toList()..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
}

int _popCount(int v) {
  v = v - ((v >> 1) & 0x55555555);
  v = (v & 0x33333333) + ((v >> 2) & 0x33333333);
  v = (v + (v >> 4)) & 0x0F0F0F0F;
  return ((v * 0x01010101) & 0xFFFFFFFF) >> 24;
}
