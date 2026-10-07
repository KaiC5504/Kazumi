import 'dart:math';

/// Measured on 2026-10-06 (see the cloud bake spec). Retune from logs here.
class CloudBakeRates {
  /// Two concurrent bakes on a Sydney L40S.
  static const cloudRealtime = 7.7;

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
  });

  final int cloudCount;
  final int localCount;

  /// How long the pod lives: from creation until its last episode is home.
  final int cloudSec;
  final int finishSec;

  int get capSec => max(CloudBakeRates.minCapSec, (cloudSec * 1.5).ceil());

  double cost(double pricePerHour) => cloudSec / 3600 * pricePerHour;

  double maxCost(double pricePerHour) => capSec / 3600 * pricePerHour;

  /// Plays both lanes over the season in order: the pod from the front once
  /// it has started, the laptop from the back, each taking the next episode
  /// as soon as it is free.
  factory CloudBakeEstimate.forDurations(
    List<int> durationsSec, {
    required bool includeLocal,
  }) {
    final d = [
      for (final s in durationsSec)
        s > 0 ? s : CloudBakeRates.unknownDurationSec,
    ];
    var front = 0;
    var back = d.length - 1;
    var cloudFree = CloudBakeRates.startupSec.toDouble();
    var localFree = includeLocal ? 0.0 : double.infinity;
    var cloudCount = 0;
    var localCount = 0;
    while (front <= back) {
      if (cloudFree <= localFree) {
        cloudFree += d[front++] / CloudBakeRates.cloudRealtime;
        cloudCount++;
      } else {
        localFree += d[back--] / CloudBakeRates.localRealtime;
        localCount++;
      }
    }
    final cloudSec = cloudCount == 0
        ? 0
        : (cloudFree + CloudBakeRates.downloadTailSec).ceil();
    final localSec = localCount == 0 ? 0 : localFree.ceil();
    return CloudBakeEstimate(
      cloudCount: cloudCount,
      localCount: localCount,
      cloudSec: cloudSec,
      finishSec: max(cloudSec, localSec),
    );
  }
}
