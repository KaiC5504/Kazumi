import 'dart:convert';

/// Which host 一起看 traffic tries first. HK by default: the partner's route
/// to Singapore loses ~20% of packets in the evening, while the owner only
/// gains from Singapore when he's near it.
enum RouteMode {
  auto,
  hk,
  sg;

  static RouteMode parse(String v) => RouteMode.values.firstWhere(
    (m) => m.name == v,
    orElse: () => RouteMode.auto,
  );

  String get storageValue => name;
}

class HostMeasurement {
  const HostMeasurement({required this.rttMs, required this.bytesPerSecond});

  final int? rttMs;
  final double? bytesPerSecond;

  bool get ok => rttMs != null && bytesPerSecond != null && bytesPerSecond! > 0;

  /// Seconds to fetch one 8 MiB download part.
  double get score => ok
      ? 3 * rttMs! / 1000 + 8 * 1024 * 1024 / bytesPerSecond!
      : double.infinity;

  Map<String, dynamic> toJson() => {'rtt': rttMs, 'bps': bytesPerSecond};

  factory HostMeasurement.fromJson(Map<String, dynamic> j) => HostMeasurement(
    rttMs: j['rtt'] as int?,
    bytesPerSecond: (j['bps'] as num?)?.toDouble(),
  );
}

class RouteCheckResult {
  const RouteCheckResult({
    required this.chosenHost,
    required this.byHost,
    required this.at,
  });

  final String chosenHost;
  final Map<String, HostMeasurement> byHost;
  final DateTime at;

  String encode() => jsonEncode({
    'chosen': chosenHost,
    'at': at.toIso8601String(),
    'hosts': {for (final e in byHost.entries) e.key: e.value.toJson()},
  });

  static RouteCheckResult? decode(String s) {
    if (s.isEmpty) return null;
    try {
      final j = jsonDecode(s) as Map<String, dynamic>;
      return RouteCheckResult(
        chosenHost: j['chosen'] as String,
        at: DateTime.parse(j['at'] as String),
        byHost: {
          for (final e in (j['hosts'] as Map<String, dynamic>).entries)
            e.key: HostMeasurement.fromJson(e.value as Map<String, dynamic>),
        },
      );
    } catch (_) {
      return null;
    }
  }
}

class HostRouter {
  HostRouter({
    required this.server,
    required this.relays,
    required this.mode,
    this.stored,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  static const rest = Duration(minutes: 2);
  static const serverMustBeat = 0.7;

  final Uri server;
  final List<Uri> relays;
  final RouteMode mode;
  final RouteCheckResult? stored;
  final DateTime Function() _clock;
  final Map<Uri, DateTime> _restUntil = {};

  bool isRelay(Uri host) => relays.contains(host);

  List<Uri> get order {
    final serverFirst = switch (mode) {
      RouteMode.sg => true,
      RouteMode.hk => false,
      RouteMode.auto => stored?.chosenHost == server.toString(),
    };
    final base = serverFirst ? [server, ...relays] : [...relays, server];
    final now = _clock();
    bool resting(Uri h) => _restUntil[h]?.isAfter(now) ?? false;
    return List.unmodifiable([
      ...base.where((h) => !resting(h)),
      ...base.where(resting),
    ]);
  }

  void reportFailure(Uri host) => _restUntil[host] = _clock().add(rest);

  static RouteCheckResult decide(
    Uri server,
    List<Uri> relays,
    Map<Uri, HostMeasurement> m,
    DateTime at,
  ) {
    final serverM = m[server];
    Uri? bestRelayHost;
    HostMeasurement? bestRelay;
    for (final r in relays) {
      final x = m[r];
      if (x != null && (bestRelay == null || x.score < bestRelay.score)) {
        bestRelay = x;
        bestRelayHost = r;
      }
    }
    final serverOk = serverM != null && serverM.ok;
    final relayOk = bestRelay != null && bestRelay.ok;
    final serverWins =
        serverOk &&
        (!relayOk || serverM.score <= serverMustBeat * bestRelay.score);
    final chosen = serverWins
        ? server
        : (bestRelayHost ?? (relays.isNotEmpty ? relays.first : server));
    return RouteCheckResult(
      chosenHost: chosen.toString(),
      at: at,
      byHost: {for (final e in m.entries) e.key.toString(): e.value},
    );
  }
}
