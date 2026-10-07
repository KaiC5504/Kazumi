/// What a player's "completed" means. On a broken stream mpv reports
/// completed once ffmpeg runs out of reconnects, which upstream treated as
/// the end of the episode (Predidit/Kazumi#1544).
enum EndAction { none, trueEnd, replay, reload, giveUp }

class EndDecision {
  const EndDecision(
    this.action, {
    this.resumeAt = Duration.zero,
    this.switchHost = false,
  });

  final EndAction action;
  final Duration resumeAt;
  final bool switchHost;
}

class PlaybackEndGuard {
  PlaybackEndGuard({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static const nearEnd = Duration(seconds: 30);
  static const maxIncidents = 3;
  // Spaced so a reload doesn't hit the same outage that caused the EOF.
  static const attemptGaps = [
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
  ];
  static const recovered = Duration(seconds: 5);
  static const cleanPlayToReset = Duration(minutes: 2);

  final DateTime Function() _clock;
  String? _fileKey;
  int _incidents = 0;
  int _attempts = 0;
  bool _inIncident = false;
  bool _awaitingReload = false;
  bool _gaveUp = false;
  DateTime? _failedAt;
  Duration _lastGood = Duration.zero;
  DateTime? _cleanSince;

  int get incidents => _incidents;
  int get attempts => _attempts;
  Duration get lastGoodPosition => _lastGood;

  void onEpisodeStarted(String fileKey) {
    if (fileKey != _fileKey) {
      _fileKey = fileKey;
      _incidents = 0;
      _attempts = 0;
      _inIncident = false;
      _lastGood = Duration.zero;
    } else if (_gaveUp) {
      // The user tapped retry after the error: a fresh start.
      _incidents = 0;
      _attempts = 0;
      _inIncident = false;
    }
    _awaitingReload = false;
    _gaveUp = false;
    _failedAt = null;
    _cleanSince = null;
  }

  void onTick({
    required Duration position,
    required bool playing,
    required bool completed,
  }) {
    if (!playing || completed || _awaitingReload) {
      _cleanSince = null;
      return;
    }
    if (position > Duration.zero) _lastGood = position;
    // mpv recovered by itself mid-wait: the next EOF waits its full gap.
    _failedAt = null;
    final now = _clock();
    _cleanSince ??= now;
    final clean = now.difference(_cleanSince!);
    if (_inIncident && clean >= recovered) {
      _inIncident = false;
      _attempts = 0;
    }
    if (_incidents > 0 && clean >= cleanPlayToReset) _incidents = 0;
  }

  EndDecision onCompleted({
    required Duration position,
    required Duration duration,
    required bool resumedNearEnd,
  }) {
    if (_awaitingReload || _gaveUp) return const EndDecision(EndAction.none);
    if (duration <= Duration.zero) return const EndDecision(EndAction.trueEnd);
    if (resumedNearEnd) return const EndDecision(EndAction.replay);
    final at = _lastGood > Duration.zero ? _lastGood : position;
    if (at >= duration - nearEnd) return const EndDecision(EndAction.trueEnd);
    if (!_inIncident) {
      if (_incidents >= maxIncidents) return _giveUp();
      _incidents++;
      _inIncident = true;
      _attempts = 0;
    }
    if (_attempts >= attemptGaps.length) return _giveUp();
    final now = _clock();
    _failedAt ??= now;
    if (now.difference(_failedAt!) < attemptGaps[_attempts]) {
      return const EndDecision(EndAction.none);
    }
    _attempts++;
    _awaitingReload = true;
    _failedAt = null;
    _cleanSince = null;
    return EndDecision(
      EndAction.reload,
      resumeAt: at,
      switchHost: _attempts == attemptGaps.length,
    );
  }

  /// The reload never reached the player (the episode didn't resolve, or
  /// isn't downloaded) and the caller already shows its error. Like giving
  /// up, a refresh then starts with a fresh budget.
  void onReloadFailed() {
    if (!_awaitingReload) return;
    _awaitingReload = false;
    _gaveUp = true;
  }

  EndDecision _giveUp() {
    _gaveUp = true;
    return const EndDecision(EndAction.giveUp);
  }
}

enum EndStep { nothing, replay, advance, followRoom, reload, giveUp }

/// One tick of the player page's end-of-episode handling, shared by the app
/// and the watch-together simulator so the lab can't pass on logic the app
/// doesn't run.
({EndStep step, EndDecision? decision}) decideEndStep({
  required PlaybackEndGuard guard,
  required bool completed,
  required bool loading,
  required Duration position,
  required Duration duration,
  required bool playing,
  required bool resumedNearEnd,
  required bool hasNextEpisode,
  required bool autoPlayNext,
  required bool roomWantsNext,
}) {
  guard.onTick(position: position, playing: playing, completed: completed);
  if (!completed || loading) return (step: EndStep.nothing, decision: null);
  final decision = guard.onCompleted(
    position: position,
    duration: duration,
    resumedNearEnd: resumedNearEnd,
  );
  final step = switch (decision.action) {
    EndAction.none => EndStep.nothing,
    EndAction.replay => EndStep.replay,
    EndAction.reload => EndStep.reload,
    EndAction.giveUp => EndStep.giveUp,
    EndAction.trueEnd =>
      !hasNextEpisode
          ? EndStep.nothing
          : autoPlayNext
          ? EndStep.advance
          : roomWantsNext
          ? EndStep.followRoom
          : EndStep.nothing,
  };
  return (step: step, decision: decision);
}
