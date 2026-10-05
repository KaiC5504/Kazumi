import 'dart:collection';

/// Round-trip times to the Syncplay server. The median of recent samples
/// stands in for the usual delay, so one message held up by packet loss
/// doesn't skew the position estimate, and can be recognised as late.
class SyncplayRttWindow {
  SyncplayRttWindow({this.size = 10});

  final int size;
  final ListQueue<double> _samples = ListQueue();

  bool get isEmpty => _samples.isEmpty;

  double get median {
    if (_samples.isEmpty) return 0;
    final sorted = _samples.toList()..sort();
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2;
  }

  /// Whether [rtt] (seconds) is far enough above the usual delay that a
  /// position carried by that message can't be trusted.
  bool isLate(double rtt) =>
      _samples.length >= 3 && rtt > 0.3 && rtt > 2 * median;

  void add(double rtt) {
    _samples.addLast(rtt);
    while (_samples.length > size) {
      _samples.removeFirst();
    }
  }

  void clear() => _samples.clear();
}

/// [wait]: pause here until the room catches up. Used instead of seeking
/// back when far ahead, since the room is usually behind because someone is
/// buffering and would keep falling behind while they do.
typedef DriftDecision = ({bool seek, double? rate, bool wait});

/// Decides how to close the gap between this player and the room while
/// playing. Small drift is tolerated, a medium gap is closed by playing a
/// little slower or faster, and only a large gap that persists is acted on:
/// by waiting when ahead, or seeking when behind. A seek shows a loading
/// spinner, so it is the last resort.
class SyncDriftCorrector {
  SyncDriftCorrector({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static const double tolerance = 3.0;
  static const double settled = 1.0;
  static const double seekThreshold = 10.0;
  static const int seekConfirmations = 3;
  static const Duration holdOffAfterJump = Duration(seconds: 8);
  static const double slowRate = 0.95;
  static const double fastRate = 1.05;

  final DateTime Function() _clock;

  /// Multiplier on the user's playback speed currently applied.
  double rateFactor = 1.0;
  int _farCount = 0;
  DateTime? _holdUntil;

  static const DriftDecision _nothing = (seek: false, rate: null, wait: false);

  bool get holdingOff {
    final until = _holdUntil;
    return until != null && _clock().isBefore(until);
  }

  /// Call after any jump or episode change: positions are unsettled for a
  /// moment and correcting against them would bounce.
  void holdOff() {
    _holdUntil = _clock().add(holdOffAfterJump);
    _farCount = 0;
  }

  /// Drops any speed change; returns the rate to restore, if one is needed.
  double? stop() {
    _farCount = 0;
    if (rateFactor == 1.0) return null;
    rateFactor = 1.0;
    return 1.0;
  }

  /// [drift] is this player's position minus the room's, in seconds;
  /// positive means ahead.
  DriftDecision update(double drift) {
    if (holdingOff) return (seek: false, rate: stop(), wait: false);

    final gap = drift.abs();
    if (gap > seekThreshold) {
      _farCount++;
      if (_farCount < seekConfirmations) return _nothing;
      final rate = stop();
      if (drift > 0) return (seek: false, rate: rate, wait: true);
      holdOff();
      return (seek: true, rate: rate, wait: false);
    }
    _farCount = 0;

    if (rateFactor != 1.0) {
      final overshot = (rateFactor < 1.0) != (drift > 0);
      if (gap < settled || overshot) {
        return (seek: false, rate: stop(), wait: false);
      }
      return _nothing;
    }
    if (gap >= tolerance) {
      rateFactor = drift > 0 ? slowRate : fastRate;
      return (seek: false, rate: rateFactor, wait: false);
    }
    return _nothing;
  }
}
