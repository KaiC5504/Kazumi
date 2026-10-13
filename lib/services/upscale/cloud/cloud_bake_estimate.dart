import 'dart:math';

/// Measured on 2026-10-06 and 2026-10-08 (two Fate films on a Sydney L40S).
/// Retune from logs here.
class CloudBakeRates {
  /// One bake slot on the L40S. A 7028 s film took 29 min sharing the pod
  /// (4.0x); the 2026-10-06 season gave 7.7x over both slots.
  static const slotRealtime = 3.85;
  static const cloudSlots = 2;

  /// The laptop's RTX 4070; a second concurrent bake doesn't help.
  static const localRealtime = 2.7;
  static const startupSec = 300;

  /// Home uplink to Sydney (1.3-1.5 GB films went up in 3-4 min), and the
  /// way back (3 GB came home in about 2 min).
  static const uploadBytesPerSec = 6e6;
  static const downloadBytesPerSec = 20e6;

  /// A 1440p HEVC bake against its 1080p source (2.97 GB from 1.31 GB).
  static const outputRatio = 2.3;

  /// For a source whose size is unknown: about a 1080p web encode.
  static const sourceBytesPerSec = 250e3;
  static const minCapSec = 1800;

  /// The worker refuses to live longer than this (MAX_CAP_SEC).
  static const maxCapSec = 12 * 3600;
  static const unknownDurationSec = 1440;
}

/// One episode as the estimate sees it.
class CloudLoad {
  const CloudLoad(int durationSec, [int bytes = 0])
    : durationSec = durationSec > 0
          ? durationSec
          : CloudBakeRates.unknownDurationSec,
      _bytes = bytes;

  final int durationSec;
  final int _bytes;

  int get bytes => _bytes > 0
      ? _bytes
      : (durationSec * CloudBakeRates.sourceBytesPerSec).round();
}

/// What the pod still has to do for one episode.
class PodWork {
  const PodWork({
    required this.uploadBytes,
    required this.bakeSec,
    required this.downloadBytes,
  });

  factory PodWork.fresh(CloudLoad load) => PodWork(
    uploadBytes: load.bytes.toDouble(),
    bakeSec: load.durationSec.toDouble(),
    downloadBytes: load.bytes * CloudBakeRates.outputRatio,
  );

  final double uploadBytes;

  /// Media seconds left to bake.
  final double bakeSec;
  final double downloadBytes;
}

/// Plays the pod forward: uploads one after another, [CloudBakeRates.cloudSlots]
/// bakes at a time, downloads one after another. Returns seconds from now
/// until the last episode is home, with the pod busy until [readyInSec].
double simulatePod(List<PodWork> work, {double readyInSec = 0}) {
  var uploadFree = readyInSec;
  final slots = List.filled(CloudBakeRates.cloudSlots, readyInSec);
  var downloadFree = 0.0;
  var end = readyInSec;
  for (final w in work) {
    var ready = readyInSec;
    if (w.uploadBytes > 0) {
      uploadFree += w.uploadBytes / CloudBakeRates.uploadBytesPerSec;
      ready = uploadFree;
    }
    var baked = ready;
    if (w.bakeSec > 0) {
      var slot = 0;
      for (var i = 1; i < slots.length; i++) {
        if (slots[i] < slots[slot]) slot = i;
      }
      baked = max(slots[slot], ready) + w.bakeSec / CloudBakeRates.slotRealtime;
      slots[slot] = baked;
    }
    downloadFree =
        max(downloadFree, baked) +
        w.downloadBytes / CloudBakeRates.downloadBytesPerSec;
    end = max(end, downloadFree);
  }
  return end;
}

int capFor(double podSec) => min(
  CloudBakeRates.maxCapSec,
  max(CloudBakeRates.minCapSec, (podSec * 1.5).ceil()),
);

double podCost(num sec, double pricePerHour) => sec / 3600 * pricePerHour;

/// Splits [queue] between the lanes: the pod takes from the front and the
/// laptop from the back, whichever would finish its next one first. [onPod]
/// is work the pod already holds, [podOnly] the indices the laptop must leave
/// alone, and [localFree] when the laptop could start one. Returns the pod's
/// time with everything it took, the indices the laptop took, and when the
/// laptop is done.
({double podSec, Set<int> laptop, double localFree}) splitLanes(
  List<CloudLoad> queue, {
  required double readyInSec,
  required double localFree,
  List<PodWork> onPod = const [],
  Set<int> podOnly = const {},
}) {
  final work = [...onPod];
  final laptop = <int>{};
  final left = [for (var i = 0; i < queue.length; i++) i];
  var localAt = localFree;
  while (left.isNotEmpty) {
    final back = left.lastIndexWhere((i) => !podOnly.contains(i));
    final podDone = simulatePod([
      ...work,
      PodWork.fresh(queue[left.first]),
    ], readyInSec: readyInSec);
    final localDone = back < 0
        ? double.infinity
        : localAt +
              queue[left[back]].durationSec / CloudBakeRates.localRealtime;
    if (podDone <= localDone) {
      work.add(PodWork.fresh(queue[left.removeAt(0)]));
    } else {
      localAt = localDone;
      laptop.add(left.removeAt(back));
    }
  }
  return (
    podSec: simulatePod(work, readyInSec: readyInSec),
    laptop: laptop,
    localFree: localAt,
  );
}

class CloudBakeEstimate {
  const CloudBakeEstimate({
    required this.cloudCount,
    required this.localCount,
    required this.cloudSec,
    required this.finishSec,
    this.localOnlySec = 0,
  });

  final int cloudCount;
  final int localCount;

  /// How long the pod lives: from creation until its last episode is home.
  final int cloudSec;
  final int finishSec;

  /// When the laptop alone would be done, for comparing against the pod.
  final int localOnlySec;

  int get capSec => capFor(cloudSec.toDouble());

  double cost(double pricePerHour) => podCost(cloudSec, pricePerHour);

  double maxCost(double pricePerHour) => podCost(capSec, pricePerHour);

  /// Plays both lanes over the season in order: the pod from the front once
  /// it has started, the laptop from the back after [localBusySec] of work
  /// it already has. Each episode goes to whichever lane would finish it
  /// first, so a long film can go to the pod even though the laptop is free.
  factory CloudBakeEstimate.forLoads(
    List<CloudLoad> loads, {
    required bool includeLocal,
    int localBusySec = 0,
  }) {
    final split = splitLanes(
      loads,
      readyInSec: CloudBakeRates.startupSec.toDouble(),
      localFree: includeLocal ? localBusySec.toDouble() : double.infinity,
    );
    final localCount = split.laptop.length;
    final cloudCount = loads.length - localCount;
    final cloudSec = cloudCount == 0 ? 0 : split.podSec.ceil();
    final localSec = localCount == 0 ? 0 : split.localFree.ceil();
    final localOnly =
        localBusySec +
        loads.fold(
          0.0,
          (a, l) => a + l.durationSec / CloudBakeRates.localRealtime,
        );
    return CloudBakeEstimate(
      cloudCount: cloudCount,
      localCount: localCount,
      cloudSec: cloudSec,
      finishSec: max(cloudSec, localSec),
      localOnlySec: localOnly.ceil(),
    );
  }
}
