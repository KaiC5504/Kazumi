import 'package:kazumi/services/skip/episode_fingerprint.dart';
import 'package:kazumi/services/skip/fingerprint_matcher.dart';
import 'package:kazumi/services/skip/skip_segments.dart';

/// Compares every episode with up to [maxPeers] of its nearest neighbours and
/// keeps the opening and ending most of those comparisons agree on.
///
/// Pure and synchronous so it can run in an isolate.
Map<int, SkipSegments> detectSkipSegments(
  Map<int, EpisodeFingerprint> prints, {
  int maxPeers = 6,
}) {
  final result = <int, SkipSegments>{};
  for (final MapEntry(key: episode, value: target) in prints.entries) {
    final peers = prints.keys.where((e) => e != episode).toList()
      ..sort((a, b) => (a - episode).abs().compareTo((b - episode).abs()));

    final openings = <(double, double)>[];
    final endings = <(double, double)>[];
    for (final peer in peers.take(maxPeers)) {
      final other = prints[peer]!;
      final head = matchFingerprints(target.head, other.head);
      if (head != null) openings.add((head.aStart, head.aEnd));
      final tail = matchFingerprints(target.tail, other.tail);
      if (tail != null) {
        endings.add((
          target.tailStart + tail.aStart,
          target.tailStart + tail.aEnd,
        ));
      }
    }

    final opening = consensusRange(openings);
    var ending = consensusRange(endings);
    if (opening != null && ending != null && ending.$1 < opening.$2) {
      ending = null;
    }
    result[episode] = SkipSegments(
      opening: opening == null
          ? null
          : SkipRange(opening.$1, opening.$2, SkipSource.fingerprint),
      ending: ending == null
          ? null
          : SkipRange(
              ending.$1,
              ending.$2.clamp(ending.$1, target.duration).toDouble(),
              SkipSource.fingerprint,
            ),
    );
  }
  return result;
}
