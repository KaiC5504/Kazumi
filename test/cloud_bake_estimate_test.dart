import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/upscale/cloud/cloud_bake_estimate.dart';

void main() {
  test('a lone film: startup, upload, one slot, download', () {
    final e = CloudBakeEstimate.forLoads([
      const CloudLoad(7200, 1500000000),
    ], includeLocal: false);
    expect(
      e.cloudSec,
      (300 + 1.5e9 / 6e6 + 7200 / 3.85 + 1.5e9 * 2.3 / 20e6).ceil(),
    );
    expect(e.cost(1.09), closeTo(e.cloudSec / 3600 * 1.09, 1e-9));
    expect(e.capSec, (e.cloudSec * 1.5).ceil());
  });

  test('two films bake side by side on the two slots', () {
    final e = CloudBakeEstimate.forLoads([
      const CloudLoad(7325, 1480000000),
      const CloudLoad(7028, 1310000000),
    ], includeLocal: false);
    // The 2026-10-08 run: the pod lived about 47 minutes for both.
    expect(e.cloudSec, inInclusiveRange(2600, 2900));
  });

  test('a season keeps the measured two-slot throughput', () {
    final e = CloudBakeEstimate.forLoads(
      List.filled(12, const CloudLoad(1440, 360000000)),
      includeLocal: false,
    );
    expect(e.cloudSec, greaterThan(300 + 12 * 1440 / 7.7));
    expect(e.cloudSec, lessThan(3000));
  });

  test('an unknown duration or size gets a typical one', () {
    const load = CloudLoad(0);
    expect(load.durationSec, 1440);
    expect(load.bytes, 1440 * 250000);
  });

  test('a short episode with an idle laptop stays on the laptop', () {
    final e = CloudBakeEstimate.forLoads([
      const CloudLoad(1440),
    ], includeLocal: true);
    expect((e.cloudCount, e.localCount, e.cloudSec), (0, 1, 0));
  });

  test('work the laptop already has pushes episodes to the pod', () {
    final busy = CloudBakeEstimate.forLoads(
      [const CloudLoad(1440)],
      includeLocal: true,
      localBusySec: 2400,
    );
    expect(busy.cloudCount, 1);
    expect(busy.localOnlySec, 2400 + (1440 / 2.7).ceil());
  });

  test('the laptop takes from the back while the pod starts up', () {
    final e = CloudBakeEstimate.forLoads(
      List.filled(6, const CloudLoad(1440, 360000000)),
      includeLocal: true,
    );
    expect(e.cloudCount, greaterThan(0));
    expect(e.localCount, greaterThan(0));
    expect(e.cloudCount + e.localCount, 6);
  });

  test('a short run still gets the minimum cap', () {
    final e = CloudBakeEstimate.forLoads([
      const CloudLoad(600, 100000000),
    ], includeLocal: false);
    expect(e.capSec, 1800);
  });

  test('in-flight work only counts what is left', () {
    const baking = PodWork(uploadBytes: 0, bakeSec: 3850, downloadBytes: 5e8);
    expect(simulatePod([baking]), closeTo(1000 + 25, 1e-6));
    expect(simulatePod([baking], readyInSec: 60), closeTo(1085, 1e-6));
  });
}
