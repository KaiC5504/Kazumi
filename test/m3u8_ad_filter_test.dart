import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/utils/m3u8_ad_filter.dart';
import 'package:kazumi/utils/m3u8_parser.dart';

const _main = 'https://vip.example.com/20260731/30447_8497a1cc/3000k/hls';

/// Builds a media playlist where each entry is one discontinuity group of
/// `(directory, segment count, segment duration)`.
List<M3u8Segment> _playlist(List<(String, int, double)> groups) {
  final buffer = StringBuffer('#EXTM3U\n#EXT-X-TARGETDURATION:8\n');
  var n = 0;
  for (final (dir, count, duration) in groups) {
    buffer.writeln('#EXT-X-DISCONTINUITY');
    for (var i = 0; i < count; i++) {
      buffer
        ..writeln('#EXTINF:$duration,')
        ..writeln('$dir/seg${n++}.ts');
    }
  }
  buffer.writeln('#EXT-X-ENDLIST');
  return M3u8Parser.parseMediaPlaylist(
    buffer.toString(),
    '$_main/index.m3u8',
  ).segments;
}

double _minutes(List<M3u8Segment> segments) =>
    segments.fold<double>(0, (sum, s) => sum + s.duration) / 60;

void main() {
  test('an episode cut into many short groups on one path stays whole', () {
    // Shape of a DM84 episode: 24 min in 56 groups of mostly 5 segments,
    // a few longer ones. The old duration rule kept 9.3 min of it.
    final groups = <(String, int, double)>[
      for (var i = 0; i < 56; i++) (_main, i % 6 == 2 ? 15 : 5, 4.0),
    ];
    final segments = _playlist(groups);

    final filtered = M3u8AdFilter.filterAds(segments);

    expect(filtered.length, segments.length);
  });

  test('a short opening group on the main path is kept', () {
    final segments = _playlist([(_main, 22, 4.0), (_main, 300, 4.0)]);

    expect(M3u8AdFilter.filterAds(segments).length, segments.length);
  });

  test('a short group from another path is dropped as an ad', () {
    final segments = _playlist([
      (_main, 150, 4.0),
      ('https://vip.example.com/adjump/2026', 5, 3.0),
      (_main, 210, 4.0),
    ]);

    final filtered = M3u8AdFilter.filterAds(segments);

    expect(filtered.length, 360);
    expect(filtered.any((s) => s.uri.contains('adjump')), isFalse);
  });

  test('mirrors on another host with the same path are not ads', () {
    final segments = _playlist([
      (_main, 5, 4.0),
      (_main.replaceFirst('vip.', 'vip2.'), 5, 4.0),
      (_main, 5, 4.0),
      (_main.replaceFirst('vip.', 'vip2.'), 5, 4.0),
    ]);

    expect(M3u8AdFilter.filterAds(segments).length, segments.length);
  });

  test('a long part from another path is content, not an ad', () {
    final segments = _playlist([
      (_main, 180, 4.0),
      ('https://vip.example.com/20260801/part2/hls', 180, 4.0),
    ]);

    expect(_minutes(M3u8AdFilter.filterAds(segments)), closeTo(24, 0.01));
  });

  test('nothing is dropped when the "ads" would be a third of the episode', () {
    final segments = _playlist([
      for (var i = 0; i < 12; i++) ...[
        (_main, 5, 4.0),
        ('https://vip.example.com/other/$i', 5, 4.0),
      ],
    ]);

    expect(M3u8AdFilter.filterAds(segments).length, segments.length);
  });
}
