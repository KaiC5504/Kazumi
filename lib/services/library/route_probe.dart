import 'dart:io';

import 'package:kazumi/services/library/host_router.dart';

typedef HostProbe = Future<HostMeasurement> Function(Uri host, Uri sample);

const _failed = HostMeasurement(rttMs: null, bytesPerSecond: null);

/// Three /healthz round trips and one 1 MiB range read. Tiny on purpose:
/// it runs once and the answer is stored.
Future<HostMeasurement> probeHost(Uri host, Uri sample) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
  try {
    final rtts = <int>[];
    for (var i = 0; i < 3; i++) {
      final w = Stopwatch()..start();
      final req = await client.getUrl(host.replace(path: '/healthz'));
      final res = await req.close().timeout(const Duration(seconds: 4));
      await res.drain<void>();
      if (res.statusCode == HttpStatus.ok) rtts.add(w.elapsedMilliseconds);
    }
    if (rtts.isEmpty) return _failed;
    rtts.sort();
    final w = Stopwatch()..start();
    final req = await client.getUrl(sample);
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1048575');
    final res = await req.close().timeout(const Duration(seconds: 5));
    // A 404 body arrives fast and would look like a great link.
    if (res.statusCode != HttpStatus.partialContent &&
        res.statusCode != HttpStatus.ok) {
      await res.drain<void>();
      return HostMeasurement(
        rttMs: rtts[rtts.length ~/ 2],
        bytesPerSecond: null,
      );
    }
    var bytes = 0;
    await for (final chunk in res.timeout(const Duration(seconds: 5))) {
      bytes += chunk.length;
      // A server that ignores Range would otherwise send the whole episode.
      if (bytes >= 1048576) break;
    }
    final secs = w.elapsedMicroseconds / 1e6;
    return HostMeasurement(
      rttMs: rtts[rtts.length ~/ 2],
      bytesPerSecond: bytes > 0 && secs > 0 ? bytes / secs : null,
    );
  } catch (_) {
    return _failed;
  } finally {
    client.close(force: true);
  }
}

Future<RouteCheckResult> runRouteCheck({
  required Uri server,
  required List<Uri> relays,
  required Uri Function(Uri host) sampleFor,
  HostProbe probe = probeHost,
  DateTime Function()? clock,
}) async {
  final hosts = [...relays, server];
  final results = await Future.wait([
    for (final h in hosts)
      probe(
        h,
        sampleFor(h),
      ).timeout(const Duration(seconds: 6), onTimeout: () => _failed),
  ]);
  // Offline, or HK down for the moment: not an answer worth keeping. Stored,
  // a brief HK outage would pin her to Singapore for good, since she never
  // opens 重新测速. The store saves nothing and the next launch measures again.
  if (!results.take(relays.length).any((m) => m.ok)) {
    throw StateError('route check: no relay reachable');
  }
  return HostRouter.decide(server, relays, {
    for (var i = 0; i < hosts.length; i++) hosts[i]: results[i],
  }, (clock ?? DateTime.now)());
}
