/// Decides when a SyncPlay connection is dead. The server sends every client
/// a State about once a second, so silence is the reliable signal; a dead
/// socket after a network switch never errors on its own.
enum NetKind { none, wifi, cellular, ethernet, other }

enum WatchAction { none, probe, reconnect }

class SyncPlayWatchdog {
  SyncPlayWatchdog({required DateTime Function() clock}) : _clock = clock;

  static const silence = Duration(seconds: 6);
  static const probeGrace = Duration(seconds: 3);

  final DateTime Function() _clock;
  DateTime? _lastInbound;
  DateTime? _probedAt;
  NetKind? _kind;
  bool _offline = false;
  bool _reconnecting = false;

  bool get offline => _offline;

  void onConnected() {
    _lastInbound = _clock();
    _probedAt = null;
    _reconnecting = false;
  }

  void onInbound() {
    _lastInbound = _clock();
    _probedAt = null;
  }

  WatchAction onTick() {
    final last = _lastInbound;
    if (_offline || last == null) return WatchAction.none;
    if (_reconnecting) return WatchAction.none;
    final now = _clock();
    if (_probedAt != null) {
      if (now.difference(_probedAt!) >= probeGrace) {
        _reconnecting = true;
        return WatchAction.reconnect;
      }
      return WatchAction.none;
    }
    if (now.difference(last) >= silence) {
      _probedAt = now;
      return WatchAction.probe;
    }
    return WatchAction.none;
  }

  WatchAction onNetwork(NetKind kind) {
    final previous = _kind;
    _kind = kind;
    if (kind == NetKind.none) {
      _offline = true;
      return WatchAction.none;
    }
    final wasOffline = _offline;
    _offline = false;
    if (wasOffline || (previous != null && previous != kind)) {
      _reconnecting = true;
      return WatchAction.reconnect;
    }
    return WatchAction.none;
  }

  WatchAction onResumed(Duration background) {
    if (_offline) return WatchAction.none;
    if (background > const Duration(seconds: 60)) {
      _reconnecting = true;
      return WatchAction.reconnect;
    }
    if (background > const Duration(seconds: 10)) {
      _probedAt = _clock();
      return WatchAction.probe;
    }
    return WatchAction.none;
  }
}

/// About a minute of reconnect attempts; the offsets are measured from the
/// previous attempt, so a phone that was asleep doesn't fire a burst.
class ReconnectBackoff {
  ReconnectBackoff({required DateTime Function() clock}) : _clock = clock;

  static const _gaps = [0, 1, 2, 4, 8, 15, 15, 15];

  final DateTime Function() _clock;
  DateTime? _startedAt;
  DateTime? _lastAttempt;
  int _attempts = 0;

  bool get running => _startedAt != null && !exhausted;
  bool get exhausted => _attempts >= _gaps.length;
  Duration get elapsed =>
      _startedAt == null ? Duration.zero : _clock().difference(_startedAt!);

  void start() {
    _startedAt = _clock();
    _lastAttempt = null;
    _attempts = 0;
  }

  bool due() {
    if (_startedAt == null || exhausted) return false;
    final from = _lastAttempt ?? _startedAt!;
    return _clock().difference(from).inSeconds >= _gaps[_attempts];
  }

  void attempted() {
    _lastAttempt = _clock();
    _attempts++;
  }

  void reset() {
    _startedAt = null;
    _lastAttempt = null;
    _attempts = 0;
  }
}
