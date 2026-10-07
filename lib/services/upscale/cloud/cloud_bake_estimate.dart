import 'dart:math';

/// Measured on 2026-10-06 (see the cloud bake spec). Retune from logs here.
class CloudBakeRates {
  /// Two concurrent bakes on a Sydney L40S.
  static const cloudRealtime = 7.7;

  /// The pod bakes two at once; a lone episode only gets one slot.
  static const cloudSlots = 2;

  /// The laptop's RTX 4070; a second concurrent bake doesn't help.
  static const localRealtime = 2.7;
  static const startupSec = 300;
  static const downloadTailSec = 60;
  static const minCapSec = 1800;
  static const unknownDurationSec = 1440;
}

class CloudBakeEstimate {
  const CloudBakeEstimate({
    required this.cloudCount,
    required this.localCount,
    required this.cloudSec,
    required this.finishSec,
    this.localOnlySec = 0,
    this.slowCloudSec = 0,
  });

  final int cloudCount;
  final int localCount;

  /// How long the pod lives: from creation until its last episode is home.
  final int cloudSec;
  final int finishSec;

  /// When the laptop alone would be done, for comparing against the pod.
  final int localOnlySec;

  /// The pod's time if nothing overlapped, each episode on a single slot.
  /// A film alone on the pod takes this long, not [cloudSec].
  final int slowCloudSec;

  int get capSec =>
      max(CloudBakeRates.minCapSec, (max(cloudSec, slowCloudSec) * 1.5).ceil());

  double cost(double pricePerHour) => cloudSec / 3600 * pricePerHour;

  double maxCost(double pricePerHour) => capSec / 3600 * pricePerHour;

  /// Extra pod time to allow for episodes added to a running session.
  static int extraCapSec(List<int> durationsSec) =>
      (_slowBakeSec(_durations(durationsSec)) * 1.5).ceil();

  static double _slowBakeSec(List<int> durations) =>
      durations.fold(0, (a, b) => a + b) *
      CloudBakeRates.cloudSlots /
      CloudBakeRates.cloudRealtime;

  static List<int> _durations(List<int> durationsSec) => [
    for (final s in durationsSec) s > 0 ? s : CloudBakeRates.unknownDurationSec,
  ];

  /// Plays both lanes over the season in order: the pod from the front once
  /// it has started, the laptop from the back after [localBusySec] of work
  /// it already has. Each episode goes to whichever lane would finish it
  /// first, so a long film can go to the pod even though the laptop is free.
  factory CloudBakeEstimate.forDurations(
    List<int> durationsSec, {
    required bool includeLocal,
    int localBusySec = 0,
  }) {
    final d = _durations(durationsSec);
    var front = 0;
    var back = d.length - 1;
    var cloudFree = CloudBakeRates.startupSec.toDouble();
    var localFree = includeLocal ? localBusySec.toDouble() : double.infinity;
    var cloudCount = 0;
    var localCount = 0;
    final onCloud = <int>[];
    while (front <= back) {
      final cloudDone = cloudFree + d[front] / CloudBakeRates.cloudRealtime;
      final localDone = localFree + d[back] / CloudBakeRates.localRealtime;
      if (cloudDone + CloudBakeRates.downloadTailSec <= localDone) {
        cloudFree = cloudDone;
        onCloud.add(d[front]);
        front++;
        cloudCount++;
      } else {
        localFree = localDone;
        back--;
        localCount++;
      }
    }
    final cloudSec = cloudCount == 0
        ? 0
        : (cloudFree + CloudBakeRates.downloadTailSec).ceil();
    final localSec = localCount == 0 ? 0 : localFree.ceil();
    final localOnly =
        localBusySec +
        d.fold(0.0, (a, s) => a + s / CloudBakeRates.localRealtime);
    return CloudBakeEstimate(
      cloudCount: cloudCount,
      localCount: localCount,
      cloudSec: cloudSec,
      finishSec: max(cloudSec, localSec),
      localOnlySec: localOnly.ceil(),
      slowCloudSec: cloudCount == 0
          ? 0
          : (CloudBakeRates.startupSec +
                    CloudBakeRates.downloadTailSec +
                    _slowBakeSec(onCloud))
                .ceil(),
    );
  }
}
