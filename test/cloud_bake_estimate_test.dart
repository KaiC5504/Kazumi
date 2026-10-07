import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/upscale/cloud/cloud_bake_estimate.dart';

void main() {
  // 1540 s bakes in 200 s on the pod (7.7x) and ~570 s on the laptop (2.7x).
  test('the laptop takes from the back while the pod starts up', () {
    final e = CloudBakeEstimate.forDurations([
      1540,
      1540,
      1540,
    ], includeLocal: true);
    expect((e.cloudCount, e.localCount), (2, 1));
    expect(e.cloudSec, 300 + 200 + 200 + 60);
    expect(e.finishSec, 760);
    expect(e.capSec, 1800);
  });

  test('cloud only puts every episode on the pod', () {
    final e = CloudBakeEstimate.forDurations([
      1540,
      1540,
      1540,
    ], includeLocal: false);
    expect((e.cloudCount, e.localCount), (3, 0));
    expect(e.cloudSec, 960);
  });

  test('an unknown duration counts as a 24-minute episode', () {
    final e = CloudBakeEstimate.forDurations([0], includeLocal: false);
    expect(e.cloudSec, (300 + 1440 / 7.7 + 60).ceil());
  });

  test('one episode with the laptop on never reaches the pod', () {
    final e = CloudBakeEstimate.forDurations([1440], includeLocal: true);
    expect((e.cloudCount, e.localCount, e.cloudSec), (0, 1, 0));
  });

  test('the cap is 1.5x the cloud time once that passes 30 minutes', () {
    final durations = List.filled(25, 1440);
    final e = CloudBakeEstimate.forDurations(durations, includeLocal: false);
    expect(e.capSec, (e.cloudSec * 1.5).ceil());
    expect(e.cost(1.09), closeTo(e.cloudSec / 3600 * 1.09, 1e-9));
    expect(e.maxCost(1.09), closeTo(e.capSec / 3600 * 1.09, 1e-9));
  });
}
