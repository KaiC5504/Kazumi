import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/library/host_router.dart';
import 'package:kazumi/services/library/route_probe.dart';

final sg = Uri.parse('https://kazumi.kaic5504.com');
final hk = Uri.parse('https://hk.kaic5504.com');
final at = DateTime(2026, 10, 7, 21);
const failed = HostMeasurement(rttMs: null, bytesPerSecond: null);
HostMeasurement m(int rtt, double mbps) =>
    HostMeasurement(rttMs: rtt, bytesPerSecond: mbps * 1024 * 1024);

void main() {
  test('17 her (Unicom): HK', () {
    final r = HostRouter.decide(sg, [hk], {hk: m(33, 60), sg: m(224, 0.2)}, at);
    expect(r.chosenHost, hk.toString());
  });

  test('18 owner in Australia: HK when Singapore is only a bit better', () {
    final r = HostRouter.decide(sg, [hk], {hk: m(120, 5), sg: m(95, 5.5)}, at);
    expect(r.chosenHost, hk.toString());
  });

  test('19 owner in Malaysia: Singapore when clearly better', () {
    final r = HostRouter.decide(sg, [hk], {hk: m(45, 20), sg: m(15, 40)}, at);
    expect(r.chosenHost, sg.toString());
  });

  test('a failed Singapore probe never wins', () {
    final r = HostRouter.decide(sg, [hk], {hk: m(300, 1), sg: failed}, at);
    expect(r.chosenHost, hk.toString());
  });

  test('HK unreachable and Singapore fine: Singapore', () {
    final r = HostRouter.decide(sg, [hk], {hk: failed, sg: m(95, 5)}, at);
    expect(r.chosenHost, sg.toString());
  });

  test('modes and the no-result default', () {
    final my = HostRouter.decide(sg, [hk], {hk: m(45, 20), sg: m(15, 40)}, at);
    expect(
      HostRouter(
        server: sg,
        relays: [hk],
        mode: RouteMode.auto,
        stored: my,
      ).order,
      [sg, hk],
    );
    expect(
      HostRouter(
        server: sg,
        relays: [hk],
        mode: RouteMode.hk,
        stored: my,
      ).order,
      [hk, sg],
    );
    expect(HostRouter(server: sg, relays: [hk], mode: RouteMode.sg).order, [
      sg,
      hk,
    ]);
    expect(HostRouter(server: sg, relays: [hk], mode: RouteMode.auto).order, [
      hk,
      sg,
    ]);
  });

  test('20 a failed host rests for 2 min, then comes back first', () {
    var now = at;
    final router = HostRouter(
      server: sg,
      relays: [hk],
      mode: RouteMode.hk,
      clock: () => now,
    );
    router.reportFailure(hk);
    expect(router.order, [sg, hk]);
    now = now.add(const Duration(minutes: 2, seconds: 1));
    expect(router.order, [hk, sg]);
  });

  test('21 manual 新加坡 is obeyed even on her profile', () {
    final hers = HostRouter.decide(
      sg,
      [hk],
      {hk: m(33, 60), sg: m(224, 0.2)},
      at,
    );
    expect(
      HostRouter(
        server: sg,
        relays: [hk],
        mode: RouteMode.sg,
        stored: hers,
      ).order.first,
      sg,
    );
  });

  test('22 late result: a playlist built earlier is not reordered', () {
    final playlist = HostRouter(
      server: sg,
      relays: [hk],
      mode: RouteMode.auto,
    ).order;
    final my = HostRouter.decide(sg, [hk], {hk: m(45, 20), sg: m(15, 40)}, at);
    final later = HostRouter(
      server: sg,
      relays: [hk],
      mode: RouteMode.auto,
      stored: my,
    ).order;
    expect(playlist, [hk, sg]);
    expect(later, [sg, hk]);
    expect(() => (playlist as List).add(sg), throwsUnsupportedError);
  });

  test('stored result round-trips; garbage decodes to null', () {
    final r = HostRouter.decide(sg, [hk], {hk: m(33, 60), sg: m(224, 0.2)}, at);
    final back = RouteCheckResult.decode(r.encode())!;
    expect(back.chosenHost, r.chosenHost);
    expect(back.byHost[hk.toString()]!.rttMs, 33);
    expect(back.at, at);
    expect(RouteCheckResult.decode(''), isNull);
    expect(RouteCheckResult.decode('{bad'), isNull);
  });

  test('runRouteCheck measures every host with the injected probe', () async {
    final probed = <Uri>[];
    final r = await runRouteCheck(
      server: sg,
      relays: [hk],
      sampleFor: (h) => h.replace(path: '/speedtest/1m'),
      probe: (h, s) async {
        probed.add(h);
        return h == hk ? m(33, 60) : m(224, 0.2);
      },
      clock: () => at,
    );
    expect(probed.toSet(), {hk, sg});
    expect(r.chosenHost, hk.toString());
  });

  test('offline: runRouteCheck throws instead of returning a result', () {
    expect(
      runRouteCheck(
        server: sg,
        relays: [hk],
        sampleFor: (h) => h,
        probe: (h, s) async => failed,
        clock: () => at,
      ),
      throwsStateError,
    );
  });
}
