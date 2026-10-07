// A watch-together room in miniature: real PlayerSyncPlayController and
// SyncplayClient instances talk over loopback sockets to a server that keeps
// room state the way the Syncplay server does, through links with their own
// delay, jitter and loss spikes. Time runs faster than the wall clock.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/bean/dialog/glass_notice.dart';
import 'package:kazumi/pages/player/controller/player_syncplay_controller.dart';
import 'package:kazumi/services/player/playback_end_guard.dart';
import 'package:kazumi/services/player/syncplay_watchdog.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class VirtualClock {
  VirtualClock(this.speed);

  final double speed;
  final Stopwatch _watch = Stopwatch()..start();
  final DateTime _origin = DateTime(2026, 10, 6, 23);

  double get seconds => _watch.elapsedMicroseconds / 1e6 * speed;

  DateTime now() =>
      _origin.add(Duration(microseconds: (seconds * 1e6).round()));

  Duration real(double virtualSeconds) =>
      Duration(microseconds: max(0, (virtualSeconds * 1e6 / speed).round()));

  Future<void> wait(double virtualSeconds) =>
      Future<void>.delayed(real(virtualSeconds));

  Future<void> until(
    bool Function() condition, {
    double timeout = 120,
    String? what,
  }) async {
    final deadline = seconds + timeout;
    while (!condition()) {
      if (seconds > deadline) {
        fail('timed out after ${timeout}s waiting for ${what ?? 'condition'}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }
}

/// One viewer's connection to the sync server. Spikes model TCP
/// retransmissions on a lossy line: a message is held up and everything
/// behind it queues, since the stream stays in order.
class NetworkProfile {
  const NetworkProfile(
    this.label, {
    required this.rtt,
    this.jitter = 0,
    this.spikeChance = 0,
    this.spikeMin = 0.5,
    this.spikeMax = 3,
  });

  final String label;
  final double rtt;
  final double jitter;
  final double spikeChance;
  final double spikeMin;
  final double spikeMax;

  static const sameWifi = NetworkProfile(
    'same Wi-Fi',
    rtt: 0.012,
    jitter: 0.004,
  );
  static const australiaToHk = NetworkProfile(
    'Australia to HK',
    rtt: 0.161,
    jitter: 0.012,
  );
  static const nanningToHk = NetworkProfile(
    'Nanning Unicom to HK',
    rtt: 0.04,
    jitter: 0.01,
  );
  static const nanningToSgEvening = NetworkProfile(
    'Nanning Unicom to Singapore at 11pm',
    rtt: 0.22,
    jitter: 0.04,
    spikeChance: 0.2,
    spikeMin: 0.6,
    spikeMax: 3,
  );
}

class _Link {
  _Link(this.clock, this.profile, this.random);

  final VirtualClock clock;
  NetworkProfile profile;
  final Random random;
  final _InOrder _down = _InOrder();
  final _InOrder _up = _InOrder();
  double blackholeUntil = 0;
  bool dead = false;

  double _delay() {
    var delay =
        profile.rtt / 2 + (random.nextDouble() * 2 - 1) * profile.jitter / 2;
    if (random.nextDouble() < profile.spikeChance) {
      delay +=
          profile.spikeMin +
          random.nextDouble() * (profile.spikeMax - profile.spikeMin);
    }
    return max(0.001, delay);
  }

  /// Runs [deliver] once the message arrives, passing how long it took.
  void down(void Function(double took) deliver) => _send(_down, deliver);

  void up(void Function(double took) deliver) => _send(_up, deliver);

  void _send(_InOrder queue, void Function(double took) deliver) {
    if (dead) return;
    final delay = _delay();
    var at = clock.seconds + delay;
    if (clock.seconds < blackholeUntil) at = max(at, blackholeUntil + delay);
    queue.add(clock, at, deliver);
  }
}

/// One direction of a TCP stream: nothing overtakes an earlier message, so
/// a held-up one delays everything queued behind it.
class _InOrder {
  final List<(double at, double sent, void Function(double took))> _queue = [];
  Timer? _timer;

  void add(VirtualClock clock, double at, void Function(double took) deliver) {
    final sent = clock.seconds;
    if (_queue.isNotEmpty) at = max(at, _queue.last.$1);
    _queue.add((at, sent, deliver));
    _arm(clock);
  }

  void _arm(VirtualClock clock) {
    if (_timer != null || _queue.isEmpty) return;
    _timer = Timer(clock.real(_queue.first.$1 - clock.seconds), () {
      _timer = null;
      while (_queue.isNotEmpty && _queue.first.$1 <= clock.seconds) {
        final (at, sent, deliver) = _queue.removeAt(0);
        deliver(at - sent);
      }
      _arm(clock);
    });
  }
}

class _Watcher {
  _Watcher(this.socket, this.link);

  final Socket socket;
  final _Link link;
  bool profileGuessed = false;
  String? name;
  String? file;
  double position = 0;
  double updatedAt = 0;
  int? pendingClientAck;
  int serverIgnoring = 0;
}

/// Keeps room state like syncplay.server: the room position is the slowest
/// watcher's (anyone with a file, whatever the file), any state whose paused
/// flag differs from the room's pauses or resumes it, and a seek moves
/// everyone.
class SimSyncplayServer {
  SimSyncplayServer._(this.clock, this._server, this._random)
    : openedAt = clock.seconds;

  final VirtualClock clock;
  final double openedAt;
  final ServerSocket _server;
  final Random _random;
  final List<_Watcher> _watchers = [];
  final Map<String, NetworkProfile> _profiles = {};
  final List<NetworkProfile> _nextProfiles = [];
  final Set<String> _silenced = {};
  bool paused = true;
  int _serverAcks = 0;
  Timer? _ticker;

  /// Pause/resume changes the room took from each viewer, for spotting a
  /// local pause that leaked out.
  final List<String> roomPauseChanges = [];

  int get port => _server.port;

  static Future<SimSyncplayServer> start(
    VirtualClock clock, {
    int seed = 1,
  }) async {
    final server = SimSyncplayServer._(
      clock,
      await ServerSocket.bind('127.0.0.1', 0),
      Random(seed),
    );
    // A client that hangs up at teardown, mid-dial or mid-write, surfaces
    // as a SocketException (10053 on Windows) in the zone that accepted
    // it, after the socket's own listeners are gone. It isn't the
    // scenario's; anything else still fails the test.
    runZonedGuarded(
      () => server._server.listen(server._accept, onError: (_) {}),
      (error, stack) {
        if (error is SocketException) return;
        Error.throwWithStackTrace(error, stack);
      },
    );
    server._ticker = Timer.periodic(clock.real(1), (_) => server._tick());
    return server;
  }

  /// The next connection uses [profile].
  void expect(NetworkProfile profile) => _nextProfiles.add(profile);

  void _accept(Socket socket) {
    // Writes racing a client that already hung up are expected at teardown.
    socket.done.catchError((_) {});
    // A controller reconnecting on its own gives no notice; it gets its
    // name's profile once its Hello arrives.
    final guessed = _nextProfiles.isEmpty;
    final profile = guessed
        ? NetworkProfile.sameWifi
        : _nextProfiles.removeAt(0);
    final watcher = _Watcher(socket, _Link(clock, profile, _random))
      ..profileGuessed = guessed;
    _watchers.add(watcher);
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) => watcher.link.up((_) => _receive(watcher, line)),
          onDone: () => watcher.link.up((_) => _drop(watcher)),
          onError: (_) {},
        );
  }

  double _positionOf(_Watcher watcher) =>
      watcher.position + (paused ? 0 : clock.seconds - watcher.updatedAt);

  _Watcher? get _slowest {
    _Watcher? slowest;
    for (final watcher in _watchers) {
      if (watcher.name == null || watcher.file == null) continue;
      if (slowest == null || _positionOf(watcher) < _positionOf(slowest)) {
        slowest = watcher;
      }
    }
    return slowest;
  }

  void _settlePositions() {
    for (final watcher in _watchers) {
      watcher.position = _positionOf(watcher);
      watcher.updatedAt = clock.seconds;
    }
  }

  void _receive(_Watcher watcher, String line) {
    if (!_watchers.contains(watcher)) return;
    final message = json.decode(line) as Map<String, dynamic>;
    if (message['Hello'] case final Map hello) {
      watcher.name = hello['username'];
      if (_silenced.contains(watcher.name)) {
        watcher.link.dead = true;
        return;
      }
      if (watcher.profileGuessed) {
        watcher.link.profile = _profiles[watcher.name!] ?? watcher.link.profile;
      }
      _profiles[watcher.name!] = watcher.link.profile;
      final others = _watchers.where((w) => w != watcher && w.name != null);
      _send(watcher, {
        'Hello': {
          'username': watcher.name,
          'room': {'name': hello['room']['name']},
        },
      });
      _send(watcher, {
        'Set': {
          'playlistIndex': {
            'user': others.isEmpty ? null : others.first.name,
            'index': 0,
          },
        },
      });
      for (final other in others) {
        _send(other, _userEvent(watcher.name!, 'joined'));
      }
      return;
    }
    if (message['Set'] case final Map set) {
      if (set['file'] case final Map file) {
        watcher.file = file['name'];
        for (final other in _watchers) {
          if (other == watcher || other.name == null) continue;
          _send(other, {
            'Set': {
              'user': {
                watcher.name: {
                  'room': {'name': 'room'},
                  'file': file,
                },
              },
            },
          });
        }
      }
      return;
    }
    if (message['State'] case final Map state) {
      final ignoring = state['ignoringOnTheFly'];
      if (ignoring is Map) {
        if (ignoring['client'] case final int ack) {
          watcher.pendingClientAck = ack;
        }
        if (ignoring['server'] == watcher.serverIgnoring) {
          watcher.serverIgnoring = 0;
        }
      }
      if (watcher.serverIgnoring != 0) return;
      final playstate = state['playstate'] as Map;
      final bool wantsPaused = playstate['paused'] ?? true;
      var position = (playstate['position'] as num).toDouble();
      if (!wantsPaused && !paused) {
        position += watcher.link.profile.rtt / 2;
      }
      if (wantsPaused != paused) {
        _settlePositions();
        paused = wantsPaused;
        roomPauseChanges.add(
          '${watcher.name} ${paused ? 'paused' : 'resumed'}'
          ' at ${clock.seconds.toStringAsFixed(1)}',
        );
        watcher.position = position;
        watcher.updatedAt = clock.seconds;
        _force(watcher, position, doSeek: false);
        return;
      }
      if (playstate['doSeek'] == true) {
        for (final other in _watchers) {
          other.position = position;
          other.updatedAt = clock.seconds;
        }
        _force(watcher, position, doSeek: true);
        return;
      }
      watcher.position = position;
      watcher.updatedAt = clock.seconds;
    }
  }

  void _force(_Watcher setter, double position, {required bool doSeek}) {
    for (final other in _watchers) {
      if (other == setter || other.name == null) continue;
      other.serverIgnoring = ++_serverAcks;
      _sendState(other, position, setBy: setter.name!, doSeek: doSeek);
    }
  }

  void _tick() {
    final slowest = _slowest;
    final position = slowest == null ? 0.0 : _positionOf(slowest);
    for (final watcher in _watchers) {
      if (watcher.name == null) continue;
      _sendState(
        watcher,
        position,
        setBy: slowest?.name ?? watcher.name!,
        doSeek: false,
      );
    }
  }

  void _sendState(
    _Watcher watcher,
    double position, {
    required String setBy,
    required bool doSeek,
  }) {
    final clientAck = watcher.pendingClientAck;
    watcher.pendingClientAck = null;
    final serverAck = watcher.serverIgnoring;
    final senderRtt = _profiles[setBy]?.rtt ?? 0;
    final bool isPaused = paused;
    watcher.link.down((took) {
      // The client times the round trip with the wall clock, so the
      // timestamp it gets back is aged by the simulated delay instead.
      final rtt = took + watcher.link.profile.rtt / 2;
      _write(watcher, {
        'State': {
          if (clientAck != null || serverAck != 0)
            'ignoringOnTheFly': {
              'client': ?clientAck,
              if (serverAck != 0) 'server': serverAck,
            },
          'ping': {
            'latencyCalculation': clock.seconds,
            'clientLatencyCalculation':
                DateTime.now().microsecondsSinceEpoch / 1e6 - rtt / clock.speed,
            'serverRtt': senderRtt,
          },
          'playstate': {
            'position': position,
            'paused': isPaused,
            'doSeek': doSeek,
            'setBy': setBy,
          },
        },
      });
    });
  }

  /// The watcher named [name]'s connection stops delivering in both
  /// directions without closing, like a phone that changed networks.
  void zombie(String name) {
    for (final w in _watchers) {
      if (w.name == name) w.link.dead = true;
    }
  }

  /// Nothing gets through for [seconds]; queued data arrives afterwards.
  void blackhole(String name, double seconds) {
    for (final w in _watchers) {
      if (w.name == name) w.link.blackholeUntil = clock.seconds + seconds;
    }
  }

  /// Closes [name]'s socket from the server side (a TLS reset).
  Future<void> reset(String name) async {
    for (final w in List.of(_watchers)) {
      if (w.name == name) {
        _drop(w);
        w.socket.destroy();
      }
    }
  }

  /// Every later connection from [name] is accepted and then never
  /// answered, like a half-hung server or a throttling middlebox.
  void silence(String name) => _silenced.add(name);

  /// The server finally times out [name]'s dead connections and tells the
  /// room they left.
  void dropGhosts(String name) {
    for (final w in List.of(_watchers)) {
      if (w.name == name && w.link.dead) _drop(w);
    }
  }

  /// Watchers the server still holds for [name], ghosts included.
  int watchersNamed(String name) =>
      _watchers.where((w) => w.name == name).length;

  _Watcher? _newest(String name) {
    _Watcher? newest;
    for (final w in _watchers) {
      if (w.name == name) newest = w;
    }
    return newest;
  }

  /// Where the server has [name]'s newest connection, as the room counts it.
  double? positionOf(String name) {
    final w = _newest(name);
    return w == null ? null : _positionOf(w);
  }

  /// The file [name]'s newest connection has announced, if any.
  String? fileOf(String name) => _newest(name)?.file;

  Map<String, dynamic> _userEvent(String name, String event) => {
    'Set': {
      'user': {
        name: {
          'room': {'name': 'room'},
          'event': {event: true},
        },
      },
    },
  };

  void _drop(_Watcher watcher) {
    if (!_watchers.remove(watcher)) return;
    for (final other in _watchers) {
      if (other.name != null && watcher.name != null) {
        _send(other, _userEvent(watcher.name!, 'left'));
      }
    }
  }

  void _send(_Watcher watcher, Map<String, dynamic> message) =>
      watcher.link.down((_) => _write(watcher, message));

  void _write(_Watcher watcher, Map<String, dynamic> message) {
    if (!_watchers.contains(watcher)) return;
    try {
      watcher.socket.write('${json.encode(message)}\r\n');
    } catch (_) {}
  }

  Future<void> close() async {
    _ticker?.cancel();
    // Accepted sockets live in start()'s guarded zone: an error on a future
    // of theirs never reaches a caller in another zone, so awaiting their
    // close() could hang. destroy() returns nothing to wait on.
    for (final watcher in List.of(_watchers)) {
      watcher.socket.destroy();
    }
    await _server.close();
  }
}

class SimSeek {
  SimSeek(
    this.at,
    this.from,
    this.to, {
    required this.bySync,
    required this.whilePlaying,
  });
  final double at;
  final double from;
  final double to;
  final bool bySync;
  final bool whilePlaying;

  @override
  String toString() =>
      '${bySync ? 'sync' : 'user'} seek at ${at.toStringAsFixed(1)}: '
      '${from.toStringAsFixed(1)} -> ${to.toStringAsFixed(1)}';
}

/// A server the episode streams from; [downUntil] is when it starts
/// answering again.
class SimHost {
  SimHost(this.name, this.loadTime);
  final String name;
  final double loadTime;
  double downUntil = 0;
}

/// A player as the sync controller sees it, plus the bits of PlayerController
/// and the player page that drive syncing: the one-second tick, auto-play
/// next, and announcing a newly loaded episode.
class SimViewer {
  SimViewer(
    this.name,
    this.clock, {
    required this.network,
    this.skew = 1.0,
    this.loadTime = 1.5,
    this.autoPlayNext = true,
    this.episodeLength = 360,
  }) {
    sync = PlayerSyncPlayController(
      bangumiId: () => 1,
      currentEpisode: () => episode,
      currentRoad: () => 0,
      playing: () => playing,
      currentPosition: () => _duration(position),
      playerPosition: () => _duration(position),
      duration: () => loading ? Duration.zero : _duration(episodeLength),
      completed: () => completed,
      pause: _pause,
      play: _play,
      seek: _seek,
      setRateFactor: _setRate,
      clock: clock.now,
    );
  }

  final String name;
  final VirtualClock clock;
  final NetworkProfile network;

  /// How fast this device's playback runs against real time; a hair off 1.0
  /// on real hardware.
  final double skew;
  double loadTime;
  bool autoPlayNext;
  final double episodeLength;
  late final PlayerSyncPlayController sync;

  int episode = 1;
  bool playing = false;
  bool loading = false;
  double rateFactor = 1.0;
  double _anchorPosition = 0;
  double _anchorAt = 0;
  double _stallFrom = 0;
  double _stallUntil = 0;
  Timer? _tick;

  final List<SimSeek> seeks = [];
  final List<double> rates = [];
  final List<String> log = [];
  final Map<int, double> furthest = {};
  int syncPauses = 0;
  int syncPlays = 0;

  /// Streams from these hosts, first one used; empty means a local file.
  List<SimHost> hosts = [];
  int hostIndex = 0;
  bool _eof = false;
  double _streamDownUntil = 0;
  late final PlaybackEndGuard endGuard = PlaybackEndGuard(clock: clock.now);
  int reloads = 0;
  int giveUps = 0;
  final List<int> episodeChanges = [];

  static Duration _duration(double seconds) =>
      Duration(microseconds: (seconds * 1e6).round());

  double get position {
    if (loading) return 0;
    if (_eof) return _anchorPosition;
    var position = _anchorPosition;
    if (playing) {
      final now = clock.seconds;
      var elapsed = now - _anchorAt;
      final stallStart = max(_anchorAt, _stallFrom);
      final stallEnd = min(now, _stallUntil);
      if (stallEnd > stallStart) elapsed -= stallEnd - stallStart;
      position += elapsed * rateFactor * skew;
    }
    return min(position, episodeLength);
  }

  bool get completed => !loading && (_eof || position >= episodeLength - 0.05);

  bool get buffering =>
      clock.seconds >= _stallFrom && clock.seconds < _stallUntil;

  List<SimSeek> get syncSeeksWhilePlaying => [
    for (final s in seeks)
      if (s.bySync && s.whilePlaying) s,
  ];

  void _anchor() {
    _anchorPosition = position;
    _anchorAt = clock.seconds;
  }

  void _note(String event) =>
      log.add('${clock.seconds.toStringAsFixed(1)} $name: $event');

  /// The stream dies here like mpv's broken-stream EOF: completed at the
  /// current position. Loads fail until [recoverAfter] seconds have passed.
  void cutStream({double recoverAfter = double.infinity}) {
    _anchor();
    playing = false;
    _eof = true;
    _streamDownUntil = clock.seconds + recoverAfter;
    _note('stream cut at ${position.toStringAsFixed(1)}');
  }

  bool get _sourceDown {
    if (clock.seconds < _streamDownUntil) return true;
    if (hosts.isEmpty) return false;
    return clock.seconds < hosts[hostIndex % hosts.length].downUntil;
  }

  /// Starts watching [episode], joins the room and keeps the player page's
  /// one-second tick running. [at] is where the playhead was when the room
  /// opened, so viewers who join back to back start level.
  Future<void> join(
    SimSyncplayServer server, {
    int episode = 1,
    double at = 0,
    bool startPlaying = true,
  }) async {
    this.episode = episode;
    _anchorPosition = at;
    // Joining takes a few ms of wall time, which the 20x clock stretches
    // into seconds, more so on Windows' 15.6 ms timer ticks. Counting from
    // the moment of joining put the second viewer up to 3 s behind, past
    // the drift corrector's line, and she jumped on arrival.
    _anchorAt = server.openedAt;
    playing = startPlaying;
    // As PlayerController.init does; without it the first reload would look
    // like a new file and wipe the guard's outage count.
    endGuard.onEpisodeStarted('1[$episode]');
    server.expect(network);
    await GStorage.putSetting(
      SettingsKeys.syncPlayEndPoint,
      '127.0.0.1:${server.port}',
    );
    await sync.createRoom('room', name, changeEpisode);
    // PlayerController reports the current network as the room opens.
    sync.onNetwork(NetKind.wifi);
    await clock.until(
      () => sync.syncplayController?.username == name,
      what: '$name to join',
    );
    await clock.wait(network.rtt * 2 + 0.5);
    _tick ??= Timer.periodic(clock.real(1), (_) => _onTick());
  }

  void _onTick() {
    sync.onPlayerTick();
    final p = position;
    if (!loading && p > (furthest[episode] ?? 0)) furthest[episode] = p;
    final end = decideEndStep(
      guard: endGuard,
      completed: completed,
      loading: loading,
      position: _duration(p),
      duration: _duration(episodeLength),
      playing: playing,
      resumedNearEnd: false,
      hasNextEpisode: true,
      autoPlayNext: autoPlayNext,
      roomWantsNext: sync.followEpisode == episode + 1,
    );
    switch (end.step) {
      case EndStep.advance:
      case EndStep.followRoom:
        unawaited(changeEpisode(episode + 1));
        return;
      case EndStep.reload:
        reloads++;
        if (end.decision!.switchHost && hosts.length > 1) hostIndex++;
        _note('reload at ${end.decision!.resumeAt.inSeconds}');
        unawaited(
          changeEpisode(episode, offset: end.decision!.resumeAt.inSeconds),
        );
        return;
      case EndStep.giveUp:
        giveUps++;
        _note('gave up');
        return;
      case EndStep.replay:
      case EndStep.nothing:
        break;
    }
    sync.setCurrentPosition();
  }

  Future<void> changeEpisode(
    int episode, {
    int currentRoad = 0,
    int offset = 0,
  }) async {
    if (loading && this.episode == episode) return;
    if (this.episode != episode) episodeChanges.add(episode);
    _note('loading episode $episode');
    sync.onEpisodeLoading('1[$episode]', _duration(offset.toDouble()));
    this.episode = episode;
    loading = true;
    playing = false;
    rateFactor = 1.0;
    _anchorPosition = 0;
    _anchorAt = clock.seconds;
    await clock.wait(
      hosts.isEmpty ? loadTime : hosts[hostIndex % hosts.length].loadTime,
    );
    if (this.episode != episode) return;
    loading = false;
    _anchorPosition = offset.toDouble();
    _anchorAt = clock.seconds;
    endGuard.onEpisodeStarted('1[$episode]');
    if (_sourceDown) {
      _eof = true;
      playing = false;
      _note('load failed at $offset');
      return;
    }
    _eof = false;
    playing = true;
    _note('playing episode $episode');
    await sync.onEpisodeLoaded();
  }

  void switchNetwork(NetKind kind) => sync.onNetwork(kind);

  void resumeAfter(double seconds) =>
      sync.onResumed(Duration(milliseconds: (seconds * 1000).round()));

  /// Puts the playhead at [at] without a seek, e.g. to set up a gap.
  void place(double at) {
    _anchorPosition = at;
    _anchorAt = clock.seconds;
  }

  /// Playback freezes (buffering) for [seconds] while still "playing".
  void stall(double seconds) {
    _anchor();
    _stallFrom = clock.seconds;
    _stallUntil = clock.seconds + seconds;
    _note('buffering for ${seconds}s');
  }

  Future<void> userPause() => _pause(enableSync: true);

  Future<void> userPlay() => _play(enableSync: true);

  Future<void> userSeek(double to) => _seek(_duration(to), enableSync: true);

  Future<void> _pause({bool enableSync = true}) async {
    _anchor();
    playing = false;
    if (!enableSync) syncPauses++;
    _note(
      '${enableSync ? 'user' : 'sync'} pause at ${position.toStringAsFixed(1)}',
    );
    if (sync.hasSession) {
      sync.setCurrentPosition();
      if (enableSync) await sync.requestSync();
    }
  }

  Future<void> _play({bool enableSync = true}) async {
    if (completed) return;
    _anchor();
    playing = true;
    if (!enableSync) syncPlays++;
    _note(
      '${enableSync ? 'user' : 'sync'} play at ${position.toStringAsFixed(1)}',
    );
    if (sync.hasSession) {
      sync.setCurrentPosition();
      if (enableSync) await sync.requestSync();
    }
  }

  Future<void> _seek(Duration to, {bool enableSync = true}) async {
    final from = position;
    final target = to.inMicroseconds / 1e6;
    seeks.add(
      SimSeek(
        clock.seconds,
        from,
        target,
        bySync: !enableSync,
        whilePlaying: playing,
      ),
    );
    _note(
      '${enableSync ? 'user' : 'sync'} seek '
      '${from.toStringAsFixed(1)} -> ${target.toStringAsFixed(1)}',
    );
    _anchorPosition = target;
    _anchorAt = clock.seconds;
    if (sync.hasSession) {
      sync.setCurrentPosition();
      if (enableSync) await sync.requestSync(doSeek: true);
    }
  }

  Future<void> _setRate(double factor) async {
    _anchor();
    rateFactor = factor;
    rates.add(factor);
    _note('rate x$factor at ${position.toStringAsFixed(1)}');
  }

  /// Drops the connection and joins again on the same player, like tapping
  /// 重新连接 after 同步中断.
  Future<void> reconnect(SimSyncplayServer server) async {
    server.expect(network);
    await sync.createRoom('room', name, changeEpisode);
    await clock.until(
      () => sync.syncplayController?.username == name,
      what: '$name to rejoin',
    );
  }

  Future<void> leave() async {
    _tick?.cancel();
    await sync.dispose();
  }
}

/// Samples the gap between two viewers while both are actually playing the
/// same episode.
class GapRecorder {
  GapRecorder(this.clock, this.a, this.b, {this.every = 0.5}) {
    _timer = Timer.periodic(clock.real(every), (_) => _sample());
  }

  final VirtualClock clock;
  final SimViewer a;
  final SimViewer b;
  final double every;
  late final Timer _timer;
  final List<double> gaps = [];
  double secondsOver3 = 0;

  void _sample() {
    if (a.loading || b.loading || a.episode != b.episode) return;
    if (!a.playing || !b.playing) return;
    final gap = (a.position - b.position).abs();
    gaps.add(gap);
    if (gap > 3) secondsOver3 += every;
  }

  double get maxGap => gaps.isEmpty ? 0 : gaps.reduce(max);
  double get lastGap => gaps.isEmpty ? double.nan : gaps.last;

  /// Gap at the 95th percentile of samples.
  double get p95 {
    if (gaps.isEmpty) return 0;
    final sorted = List.of(gaps)..sort();
    return sorted[((sorted.length - 1) * 0.95).round()];
  }

  void stop() => _timer.cancel();

  @override
  String toString() =>
      'gap max ${maxGap.toStringAsFixed(2)}s, '
      'p95 ${p95.toStringAsFixed(2)}s, last ${lastGap.toStringAsFixed(2)}s, '
      '>3s for ${secondsOver3.toStringAsFixed(1)}s';
}

/// Every pill any viewer showed. GlassNotice draws nothing in tests.
final List<String> simNotices = [];

/// Seeds a scenario runs with: `LAB_SEEDS` counts them up from [first], and
/// `LAB_SEED` pins one to reproduce a failure.
List<int> labSeeds({int first = 1}) {
  final pinned = int.tryParse(Platform.environment['LAB_SEED'] ?? '');
  if (pinned != null) return [pinned];
  final count = int.tryParse(Platform.environment['LAB_SEEDS'] ?? '') ?? 1;
  return [for (var i = 0; i < count; i++) first + i];
}

/// Runs [body] once per seed, cleaning up after each with [stop]; a failure
/// names its seed and dumps the viewers' logs.
Future<void> forSeeds(
  List<int> seeds,
  Future<void> Function(int seed) body, {
  required Future<void> Function() stop,
  required List<SimViewer> Function() viewers,
  List<String> Function()? roomLog,
}) async {
  for (final seed in seeds) {
    try {
      await body(seed);
    } catch (e, stack) {
      for (final viewer in viewers()) {
        printOnFailure(
          '--- ${viewer.name} (seed $seed)\n${viewer.log.join('\n')}',
        );
      }
      if (roomLog != null) {
        printOnFailure('--- room (seed $seed)\n${roomLog().join('\n')}');
      }
      final message = e is TestFailure ? e.message : '$e';
      Error.throwWithStackTrace(TestFailure('seed $seed: $message'), stack);
    } finally {
      await stop();
    }
  }
}

/// Hive and the path provider, which the sync controller reads its server
/// address from.
void setUpSyncplayStorage() {
  late Directory directory;
  late PathProviderPlatform originalPaths;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    Logger.level = Level.off;
    GlassNotice.debugOnShow = simNotices.add;
    directory = await Directory.systemTemp.createTemp('kazumi_syncplay_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(directory.path);
    Hive.init(directory.path);
    await GStorage.init();
  });

  tearDownAll(() async {
    GlassNotice.debugOnShow = null;
    await Hive.close();
    PathProviderPlatform.instance = originalPaths;
    await directory.delete(recursive: true);
  });
}

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}
