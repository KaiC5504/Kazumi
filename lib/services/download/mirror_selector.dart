import 'package:flutter/foundation.dart';

/// One file reachable through several hosts, e.g. the library server and a
/// relay with a better route into mainland China. Each part goes to the host
/// that has been fastest lately; a host that fails is rested for a while, and
/// every [exploreEvery] picks another host gets a part so a recovered or
/// faster route is noticed mid-download.
class MirrorSet {
  MirrorSet(
    List<String> urls, {
    this.exploreEvery = 8,
    this.restAfterFailure = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) : urls = List.unmodifiable(urls),
       _clock = clock ?? DateTime.now;

  /// In preference order; the first wins until speeds are known.
  final List<String> urls;
  final int exploreEvery;
  final Duration restAfterFailure;
  final DateTime Function() _clock;

  final Map<String, double> _speed = {};
  final Map<String, DateTime> _restUntil = {};
  int _picks = 0;

  String pick() {
    final now = _clock();
    final awake = urls
        .where((u) => !(_restUntil[u]?.isAfter(now) ?? false))
        .toList();
    final pool = awake.isEmpty ? urls : awake;
    if (pool.length == 1) return pool.first;

    _picks++;
    final best = _fastest(pool);
    if (_picks % exploreEvery != 0) return best;
    final others = pool.where((u) => u != best).toList();
    return others[(_picks ~/ exploreEvery) % others.length];
  }

  String _fastest(List<String> pool) {
    String? best;
    var bestSpeed = -1.0;
    for (final url in pool) {
      final speed = _speed[url];
      if (speed != null && speed > bestSpeed) {
        best = url;
        bestSpeed = speed;
      }
    }
    return best ?? pool.first;
  }

  /// Bytes per second last measured for [url], smoothed.
  double? speedOf(String url) => _speed[url];

  void reportSuccess(String url, int bytes, Duration took) {
    if (bytes <= 0 || took <= Duration.zero) return;
    final speed =
        bytes / (took.inMicroseconds / Duration.microsecondsPerSecond);
    final old = _speed[url];
    _speed[url] = old == null ? speed : old * 0.6 + speed * 0.4;
    _restUntil.remove(url);
  }

  void reportFailure(String url) {
    _restUntil[url] = _clock().add(restAfterFailure);
    final old = _speed[url];
    if (old != null) _speed[url] = old / 2;
  }
}

/// Lets whoever queues a download tell the download manager which other URLs
/// serve the same file. Lives for the app session. A download resumed after a
/// restart, or queued by an older build, gets its set from [expand].
class MirrorRegistry {
  static final Map<String, MirrorSet> _sets = {};

  /// Every URL serving the same file as the given one, in preference order,
  /// or null if it isn't known to be mirrored.
  static List<String>? Function(String url)? expand;

  static void register(List<String> urls) {
    if (urls.length < 2) return;
    final set = MirrorSet(urls);
    for (final url in urls) {
      _sets[url] = set;
    }
  }

  static MirrorSet forUrl(String url) {
    final known = _sets[url];
    if (known != null) return known;
    final urls = expand?.call(url);
    if (urls == null || urls.length < 2) return MirrorSet([url]);
    register(urls.contains(url) ? urls : [...urls, url]);
    return _sets[url]!;
  }

  @visibleForTesting
  static void reset() {
    _sets.clear();
    expand = null;
  }
}
