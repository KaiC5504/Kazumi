import 'package:kazumi/utils/m3u8_parser.dart';

class M3u8AdFilter {
  /// Groups shorter than this, served from outside the main content's
  /// directory, are treated as inserted ads.
  static const double maxAdGroupDuration = 120.0;

  /// Filter ad segments from a media playlist.
  ///
  /// The player's FFmpeg hls_ad_filter drops a discontinuity group only when
  /// its PTS jumps backwards, which a playlist alone can't show. Duration
  /// alone isn't a signal: some sources cut a whole episode into 20 s
  /// discontinuity groups. Inserted ads come from a different path than the
  /// episode, so only short groups from a foreign directory are dropped.
  static List<M3u8Segment> filterAds(List<M3u8Segment> segments) {
    if (segments.isEmpty) return segments;

    final groups = <int, List<M3u8Segment>>{};
    for (final seg in segments) {
      groups.putIfAbsent(seg.discontinuityGroup, () => []);
      groups[seg.discontinuityGroup]!.add(seg);
    }

    // Only one group means no ads detected
    if (groups.length <= 1) return segments;

    double durationOf(List<M3u8Segment> segs) =>
        segs.fold<double>(0.0, (sum, seg) => sum + seg.duration);

    final directoryDurations = <String, double>{};
    for (final seg in segments) {
      final dir = _directoryOf(seg.uri);
      directoryDurations[dir] = (directoryDurations[dir] ?? 0) + seg.duration;
    }
    final mainDirectory = directoryDurations.entries
        .reduce((a, b) => b.value > a.value ? b : a)
        .key;

    final adGroups = <int>{};
    for (final entry in groups.entries) {
      final segs = entry.value;
      final foreign =
          segs.every((seg) => _directoryOf(seg.uri) != mainDirectory);
      if (foreign && durationOf(segs) < maxAdGroupDuration) {
        adGroups.add(entry.key);
      }
    }

    // Losing this much is a misdetection, not ads; a kept ad beats a short
    // episode.
    final adDuration = adGroups.fold<double>(
        0.0, (sum, id) => sum + durationOf(groups[id]!));
    if (adDuration > durationOf(segments) * 0.3) return segments;

    if (adGroups.isEmpty) return segments;

    // Remove ad segments
    return segments
        .where((seg) => !adGroups.contains(seg.discontinuityGroup))
        .toList();
  }

  // Host is ignored: some CDNs spread one episode's segments across mirrors.
  static String _directoryOf(String uri) {
    final path = Uri.tryParse(uri)?.path ?? uri;
    final slash = path.lastIndexOf('/');
    return slash < 0 ? '' : path.substring(0, slash);
  }

  /// Calculate the new target duration after filtering
  static double calculateTargetDuration(List<M3u8Segment> segments) {
    if (segments.isEmpty) return 0;
    double maxSegDuration = 0;
    for (final seg in segments) {
      if (seg.duration > maxSegDuration) {
        maxSegDuration = seg.duration;
      }
    }
    return maxSegDuration;
  }
}
