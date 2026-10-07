// ignore_for_file: library_private_types_in_public_api

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/glass_notice.dart';
import 'package:kazumi/pages/player/controller/player_models.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/player/syncplay_client.dart';
import 'package:kazumi/services/player/syncplay_drift.dart';
import 'package:kazumi/services/player/syncplay_endpoint.dart';
import 'package:kazumi/services/player/syncplay_watchdog.dart';
import 'package:kazumi/utils/async_session.dart';
import 'package:mobx/mobx.dart';

part 'player_syncplay_controller.g.dart';

class PlayerSyncPlayController = _PlayerSyncPlayController
    with _$PlayerSyncPlayController;

abstract class _PlayerSyncPlayController with Store {
  _PlayerSyncPlayController({
    required this.bangumiId,
    required this.currentEpisode,
    required this.currentRoad,
    required this.playing,
    required this.currentPosition,
    required this.playerPosition,
    required this.duration,
    required this.completed,
    required this.pause,
    required this.play,
    required this.seek,
    required this.setRateFactor,
    required this.clock,
  });

  final int Function() bangumiId;
  final int Function() currentEpisode;
  final int Function() currentRoad;
  final bool Function() playing;
  final Duration Function() currentPosition;
  final Duration Function() playerPosition;
  final Duration Function() duration;
  final bool Function() completed;
  final Future<void> Function({bool enableSync}) pause;
  final Future<void> Function({bool enableSync}) play;
  final Future<void> Function(Duration duration, {bool enableSync}) seek;
  final Future<void> Function(double factor) setRateFactor;
  final DateTime Function() clock;

  late final SyncDriftCorrector _drift = SyncDriftCorrector(clock: clock);
  // Last file each other watcher announced; null until they announce one.
  final Map<String, String?> _peerFiles = {};
  bool _waitingForPeers = false;
  // Paused locally because the room fell far behind, usually because
  // someone is buffering; resumes when it catches up.
  bool _waitingForRoom = false;
  // Joined a room already playing. Until this player has caught up its
  // position would drag the room back, so it holds off counting itself in.
  bool _announceWhenCaughtUp = false;
  late final SyncPlayWatchdog _watchdog = SyncPlayWatchdog(clock: clock);
  late final ReconnectBackoff _backoff = ReconnectBackoff(clock: clock);
  String? _room;
  String? _username;
  Future<void> Function(int episode, {int currentRoad, int offset})?
      _changeEpisode;
  DateTime? _reconnectNoticeAt;
  bool _reconnectNoticeShown = false;
  // A peer's 'left' waits here so a quick rejoin shows no pills at all.
  final Map<String, DateTime> _pendingLeft = {};
  // Peers who rejoined while the server still held their old connection;
  // that connection's 'left' arrives later and must not remove them.
  final Map<String, int> _ghosts = {};
  int _reconnectAttempts = 0;

  // The backoff stops counting as running once its last attempt is spent,
  // but that attempt still needs time to land before giving up.
  bool get reconnecting => _backoff.running || _backoff.exhausted;
  @visibleForTesting
  int get reconnectAttempts => _reconnectAttempts;
  @visibleForTesting
  Iterable<String> get peers => _peerFiles.keys;

  @visibleForTesting
  bool get waitingForPeers => _waitingForPeers;

  /// Episode another watcher moved on to while this one was near the end of
  /// the current one; the player goes there once this episode finishes.
  int? followEpisode;

  /// Set before the socket opens and cleared on teardown, so unlike
  /// [syncplayRoom] it also covers the window where the connection is still
  /// being established.
  @observable
  SyncplayClient? syncplayController;
  final AsyncSessionOwner _connectionSessions = AsyncSessionOwner();
  @observable
  String syncplayRoom = '';
  @observable
  int syncplayClientRtt = 0;

  bool get hasSession => syncplayController != null;

  final StreamController<SyncPlayChatMessage> _chatStreamController =
      StreamController<SyncPlayChatMessage>.broadcast();

  Stream<SyncPlayChatMessage> get chatStream => _chatStreamController.stream;

  void emitChatMessage({
    required String username,
    required String message,
    required bool fromRemote,
  }) {
    if (_chatStreamController.isClosed) {
      return;
    }
    _chatStreamController.add(SyncPlayChatMessage(
      username: username,
      message: message,
      fromRemote: fromRemote,
    ));
  }

  Future<void> createRoom(
      String room,
      String username,
      Future<void> Function(int episode, {int currentRoad, int offset})
          changeEpisode,
      {bool quiet = false}) async {
    if (_connectionSessions.isClosed) {
      return;
    }
    _room = room;
    _username = username;
    _changeEpisode = changeEpisode;
    final session = _connectionSessions.begin();
    final previousClient = syncplayController;
    syncplayController = null;
    syncplayRoom = '';
    syncplayClientRtt = 0;
    final keepFollow = followEpisode;
    await _resetRoomState();
    if (quiet) {
      followEpisode = keepFollow;
    }
    await previousClient?.disconnect();
    if (session.isStale) {
      return;
    }
    final String syncPlayEndPoint =
        GStorage.getSetting(SettingsKeys.syncPlayEndPoint);
    KazumiLogger().i('SyncPlay: connecting to $syncPlayEndPoint');
    final parsed = parseSyncPlayEndPoint(syncPlayEndPoint);
    if (parsed == null) {
      GlassNotice.show('同步服务器地址不对',
          icon: Icons.error_outline_rounded, bottom: true);
      KazumiLogger().e('SyncPlay: invalid server address $syncPlayEndPoint');
      return;
    }
    // The watch-together library's own server has a real certificate too.
    final enableTLS = isOfficialSyncPlayEndPoint(parsed) ||
        syncPlayEndPoint.trim() ==
            GStorage.getSetting(SettingsKeys.librarySyncPlayEndPoint);
    final client = SyncplayClient(host: parsed.host, port: parsed.port);
    syncplayController = client;
    try {
      await client.connect(enableTLS: enableTLS);
      if (!_isCurrentConnection(session, client)) {
        await client.disconnect();
        return;
      }
      KazumiLogger().i('SyncPlay: connected to ${parsed.host}:${parsed.port}');
      client.onInbound = _watchdog.onInbound;
      _watchdog.onConnected();
      client.livePosition = _reportedPosition;
      client.onGeneralMessage.listen(
        (message) {
          // Only the server's Hello reply comes through here. A reconnect
          // counts once the server answers, not when our Hello is written:
          // a server that accepts and then stays silent must not reset the
          // backoff, or the loop would never give up.
          if (_isCurrentConnection(session, client) && reconnecting) {
            _reconnected();
          }
        },
        onError: (error) {
          if (!_isCurrentConnection(session, client)) {
            return;
          }
          final message =
              error is SyncplayException ? error.message : error.toString();
          KazumiLogger().e('SyncPlay: error $message', error: error);
          if (error is SyncplayConnectionException) {
            _beginReconnect();
          }
        },
      );
      client.onRoomMessage.listen(
        (message) {
          if (!_isCurrentConnection(session, client)) {
            return;
          }
          // The init reply lands after createRoom has returned, so this
          // checks the connection's own flag rather than shared state.
          if (message['type'] == 'init') {
            if (message['username'] == '') {
              if (!quiet) {
                GlassNotice.show('房间里只有你，等对方加入',
                    icon: Icons.hourglass_empty_rounded);
              }
              setPlayingBangumi();
            } else {
              _peerFiles.putIfAbsent(message['username'], () => null);
              _pendingLeft.remove(message['username']);
              if (!quiet) {
                GlassNotice.show('已跟上 ${message['username']} 的进度',
                    icon: Icons.sync_rounded);
              }
              _announceWhenCaughtUp = true;
            }
          }
          if (message['type'] == 'left') {
            final String name = message['username'];
            if (name == client.username) {
              // Our own dead connection timing out on the server.
              return;
            }
            final ghosts = _ghosts[name] ?? 0;
            if (ghosts > 0) {
              // The old connection of a peer who already rejoined.
              _ghosts[name] = ghosts - 1;
              return;
            }
            _peerFiles.remove(name);
            _pendingLeft[name] = clock();
            if (_waitingForPeers && _peersBehind().isEmpty) {
              _stopWaiting();
            }
          }
          if (message['type'] == 'joined') {
            // A peer back from a dead socket can rejoin while the server
            // still holds the old connection, so no 'left' came first.
            final known = _peerFiles.containsKey(message['username']);
            if (known) {
              _ghosts.update(message['username'], (n) => n + 1,
                  ifAbsent: () => 1);
            }
            if (message['username'] != client.username) {
              _peerFiles[message['username']] = null;
            }
            final wasAway = _pendingLeft.remove(message['username']) != null;
            if (!wasAway && !known && message['username'] != client.username) {
              GlassNotice.show('${message['username']} 加入了',
                  icon: Icons.person_add_alt_1_rounded);
            }
          }
        },
      );
      client.onFileChangedMessage.listen(
        (message) {
          if (!_isCurrentConnection(session, client)) {
            return;
          }
          KazumiLogger().i(
              'SyncPlay: file changed by ${message['setBy']}: ${message['name']}');
          final String? setBy = message['setBy'];
          if (setBy != null && setBy != client.username) {
            _peerFiles[setBy] = message['name'];
            if (_waitingForPeers && _peersBehind().isEmpty) {
              _stopWaiting(caughtUp: setBy);
            }
          }
          RegExp regExp = RegExp(r'(\d+)\[(\d+)\]');
          Match? match = regExp.firstMatch(message['name']);
          if (match != null) {
            int bangumiID = int.tryParse(match.group(1) ?? '0') ?? 0;
            int episode = int.tryParse(match.group(2) ?? '0') ?? 0;
            if (bangumiID != 0 && episode != 0 && episode != currentEpisode()) {
              if (_finishCurrentFirst(episode)) {
                followEpisode = episode;
                GlassNotice.show(
                    '${setBy ?? '对方'} 已在第 $episode 话，本集播完后跟上',
                    icon: Icons.skip_next_rounded);
              } else {
                GlassNotice.show(
                    '${message['setBy'] ?? '对方'} 切换到第 $episode 话',
                    icon: Icons.skip_next_rounded);
                changeEpisode(episode, currentRoad: currentRoad());
              }
            }
          }
        },
      );
      client.onChatMessage.listen(
        (message) {
          if (!_isCurrentConnection(session, client)) {
            return;
          }
          final String sender = (message['username'] ?? '').toString();
          final String text = (message['message'] ?? '').toString();
          final bool fromRemote = message['username'] != username;

          emitChatMessage(
            username: sender,
            message: text,
            fromRemote: fromRemote,
          );
        },
        onError: (error) {
          if (!_isCurrentConnection(session, client)) {
            return;
          }
          final message =
              error is SyncplayException ? error.message : error.toString();
          KazumiLogger().e('SyncPlay: error $message', error: error);
        },
      );
      client.onPositionChangedMessage.listen(
        (message) {
          if (!_isCurrentConnection(session, client)) {
            return;
          }
          syncplayClientRtt = (message['clientRtt'].toDouble() * 1000).toInt();
          KazumiLogger().i(
              'SyncPlay: position changed by ${message['setBy']}: [${DateTime.now().millisecondsSinceEpoch / 1000.0}] calculatedPosition ${message['calculatedPositon']} position: ${message['position']} doSeek: ${message['doSeek']} paused: ${message['paused']} clientRtt: ${message['clientRtt']} serverRtt: ${message['serverRtt']} fd: ${message['fd']}');
          if (_waitingForPeers) {
            if (playing()) {
              // Pressed play while waiting: go ahead without them.
              _stopWaiting();
            } else if (!GlassNotice.isShowing) {
              _showWaiting();
            }
            return;
          }
          // Positions from another episode, or from a player sitting at the
          // end of this one, say nothing about how far apart we are.
          if (_peersElsewhere().isNotEmpty || completed()) {
            unawaited(_stopNudge());
            _stopWaitingForRoom(resume: false);
            return;
          }
          if (_waitingForRoom) {
            final behind = playerPosition().inMilliseconds / 1000 -
                message['calculatedPositon'].toDouble();
            if (message['paused'] || message['doSeek'] || playing()) {
              // The room paused or seeked, or play was pressed: whatever
              // happens next is handled as usual.
              _stopWaitingForRoom(resume: false);
            } else if (behind < SyncDriftCorrector.settled) {
              _stopWaitingForRoom(resume: true);
              return;
            } else {
              return;
            }
          }
          // Still loading: the room's state is applied once it has.
          if (duration().inMilliseconds <= 0) {
            return;
          }
          if (message['paused'] != !playing()) {
            if (message['paused']) {
              if (message['position'] != 0) {
                pause(enableSync: false);
              }
            } else {
              if (message['position'] != 0) {
                play(enableSync: false);
              }
            }
          }
          final double roomPosition = message['calculatedPositon'].toDouble();
          final double drift =
              playerPosition().inMilliseconds / 1000 - roomPosition;
          if (message['doSeek']) {
            _jumpTo(roomPosition);
            return;
          }
          if (message['paused']) {
            unawaited(_stopNudge());
            if (drift.abs() > 1 && !_drift.holdingOff) {
              _jumpTo(roomPosition);
            }
            return;
          }
          if (message['late'] == true) {
            return;
          }
          if (_announceWhenCaughtUp) {
            if (drift.abs() >= SyncDriftCorrector.tolerance) {
              // Joining is already an interruption, so catch up in one go.
              if (!_drift.holdingOff) {
                _jumpTo(roomPosition);
              }
              return;
            }
            _announceWhenCaughtUp = false;
            unawaited(_announceFile(client));
          }
          final decision = _drift.update(drift);
          if (decision.wait) {
            KazumiLogger()
                .i('SyncPlay: ${drift.toStringAsFixed(2)}s ahead, waiting');
            _startWaitingForRoom(client, message['setBy']);
          }
          if (decision.rate != null) {
            KazumiLogger().i(
                'SyncPlay: drift ${drift.toStringAsFixed(2)}s, rate x${decision.rate}');
            unawaited(setRateFactor(decision.rate!));
          }
          if (decision.seek) {
            KazumiLogger()
                .i('SyncPlay: drift ${drift.toStringAsFixed(2)}s, seeking');
            seek(Duration(milliseconds: (roomPosition * 1000).toInt()),
                enableSync: false);
          }
        },
      );
      await client.joinRoom(room, username);
      if (!_isCurrentConnection(session, client)) {
        await client.disconnect();
        return;
      }
      syncplayRoom = room;
    } catch (e) {
      KazumiLogger().e('SyncPlay: error', error: e);
      if (!_isCurrentConnection(session, client)) {
        await client.disconnect();
        return;
      }
      syncplayController = null;
      syncplayRoom = '';
      syncplayClientRtt = 0;
      await client.disconnect();
      if (reconnecting) {
        return;
      }
      GlassNotice.show(
        '连不上同步服务器',
        icon: Icons.link_off_rounded,
        bottom: true,
        actionLabel: '重试',
        onAction: () => createRoom(room, username, changeEpisode),
      );
    }
  }

  void _reconnected() {
    _backoff.reset();
    if (_reconnectNoticeShown) {
      GlassNotice.show('已重新同步', icon: Icons.sync_rounded);
    }
    _reconnectNoticeAt = null;
    _reconnectNoticeShown = false;
  }

  void _beginReconnect() {
    if (_room == null || _changeEpisode == null) return;
    if (reconnecting) return;
    _backoff.start();
    _reconnectNoticeAt = clock().add(const Duration(seconds: 3));
  }

  /// Runs once per player tick: reconnects are driven from here rather than
  /// timers so they follow the injected clock.
  void onPlayerTick() {
    final now = clock();
    for (final entry in _pendingLeft.entries.toList()) {
      if (now.difference(entry.value) >= const Duration(seconds: 15)) {
        _pendingLeft.remove(entry.key);
        GlassNotice.show('${entry.key} 离开了',
            icon: Icons.person_remove_rounded);
      }
    }
    if (reconnecting) {
      _driveReconnect(now);
      return;
    }
    if (syncplayController == null) return;
    switch (_watchdog.onTick()) {
      case WatchAction.none:
        break;
      case WatchAction.probe:
        unawaited(requestSync());
      case WatchAction.reconnect:
        _beginReconnect();
        _driveReconnect(now);
    }
  }

  void _driveReconnect(DateTime now) {
    if (_watchdog.offline) return;
    if (!_reconnectNoticeShown &&
        _reconnectNoticeAt != null &&
        now.isAfter(_reconnectNoticeAt!)) {
      _reconnectNoticeShown = true;
      GlassNotice.show('同步重连中…',
          icon: Icons.sync_rounded, duration: const Duration(minutes: 2));
    }
    if (_backoff.exhausted) {
      // The last attempt goes out about 60 s in; give it time to land.
      if (_backoff.elapsed < const Duration(seconds: 75)) return;
      _backoff.reset();
      _reconnectNoticeShown = false;
      final room = _room!, user = _username!, change = _changeEpisode!;
      unawaited(exitRoom());
      GlassNotice.show(
        '同步中断',
        icon: Icons.link_off_rounded,
        bottom: true,
        actionLabel: '重新连接',
        onAction: () => createRoom(room, user, change),
      );
      return;
    }
    if (_backoff.due()) {
      _backoff.attempted();
      _reconnectAttempts++;
      unawaited(createRoom(_room!, _username!, _changeEpisode!, quiet: true));
    }
  }

  void onNetwork(NetKind kind) {
    if (_watchdog.onNetwork(kind) == WatchAction.reconnect &&
        (syncplayController != null || reconnecting)) {
      if (reconnecting) {
        // A fresh minute of attempts on the new network.
        _backoff.start();
      } else {
        _beginReconnect();
      }
      _driveReconnect(clock());
    }
  }

  void onResumed(Duration background) {
    if (syncplayController == null && !reconnecting) return;
    switch (_watchdog.onResumed(background)) {
      case WatchAction.none:
        break;
      case WatchAction.probe:
        unawaited(requestSync());
      case WatchAction.reconnect:
        _beginReconnect();
        _driveReconnect(clock());
    }
  }

  bool _isCurrentConnection(AsyncSession session, SyncplayClient client) {
    return session.isActive && identical(syncplayController, client);
  }

  String _currentFile() => "${bangumiId()}[${currentEpisode()}]";

  List<String> _peersElsewhere() => [
        for (final entry in _peerFiles.entries)
          if (entry.value != null && entry.value != _currentFile()) entry.key
      ];

  /// Watchers still on an earlier episode of this show.
  List<String> _peersBehind() {
    final mine = _parseFile(_currentFile());
    if (mine == null) {
      return [];
    }
    return [
      for (final entry in _peerFiles.entries)
        if (_parseFile(entry.value) case final theirs?
            when theirs.$1 == mine.$1 && theirs.$2 < mine.$2)
          entry.key
    ];
  }

  static (int, int)? _parseFile(String? file) {
    final match = RegExp(r'(\d+)\[(\d+)\]').firstMatch(file ?? '');
    if (match == null) {
      return null;
    }
    return (int.parse(match.group(1)!), int.parse(match.group(2)!));
  }

  bool _finishCurrentFirst(int episode) {
    final total = duration();
    return episode == currentEpisode() + 1 &&
        total > Duration.zero &&
        total - playerPosition() <= const Duration(minutes: 3);
  }

  double _reportedPosition() {
    return ((currentPosition().inMilliseconds -
                        playerPosition().inMilliseconds)
                    .abs() >
                2000)
        ? currentPosition().inMilliseconds.toDouble() / 1000
        : playerPosition().inMilliseconds.toDouble() / 1000;
  }

  void _jumpTo(double position) {
    unawaited(_stopNudge());
    _drift.holdOff();
    seek(Duration(milliseconds: (position * 1000).toInt()), enableSync: false);
  }

  Future<void> _stopNudge() async {
    final rate = _drift.stop();
    if (rate != null) {
      await setRateFactor(rate);
    }
  }

  /// After moving to a new episode, waits at the start for anyone still on
  /// an earlier one instead of starting without them.
  Future<void> _waitForPeers(SyncplayClient client, String previousFile) async {
    // Nobody can reach another episode without announcing it, so a watcher
    // with no file yet is still on the one we were watching together.
    for (final name in _peerFiles.keys.toList()) {
      _peerFiles[name] ??= previousFile;
    }
    if (_peersBehind().isEmpty) {
      return;
    }
    _waitingForPeers = true;
    await pause(enableSync: false);
    if (!identical(syncplayController, client) || _peersBehind().isEmpty) {
      _stopWaiting();
      return;
    }
    _showWaiting();
  }

  void _showWaiting() {
    GlassNotice.show(
      '${_peersBehind().join('、')} 还在上一话，等 TA 跟上',
      icon: Icons.hourglass_top_rounded,
      bottom: true,
      actionLabel: '不等了',
      onAction: _stopWaiting,
      duration: const Duration(hours: 1),
    );
  }

  void _stopWaiting({String? caughtUp}) {
    if (!_waitingForPeers) {
      return;
    }
    _waitingForPeers = false;
    _drift.holdOff();
    if (caughtUp != null) {
      GlassNotice.show('$caughtUp 跟上了', icon: Icons.sync_rounded);
    } else {
      GlassNotice.hide();
    }
    if (!playing()) {
      play(enableSync: false);
    }
  }

  void _startWaitingForRoom(SyncplayClient client, String? slowest) {
    _waitingForRoom = true;
    pause(enableSync: false);
    final who =
        (slowest == null || slowest.isEmpty || slowest == client.username)
            ? '对方'
            : slowest;
    GlassNotice.show(
      '等 $who 跟上…',
      icon: Icons.hourglass_top_rounded,
      bottom: true,
      actionLabel: '不等了',
      onAction: () => _stopWaitingForRoom(resume: true),
      duration: const Duration(minutes: 10),
    );
  }

  void _stopWaitingForRoom({required bool resume}) {
    if (!_waitingForRoom) {
      return;
    }
    _waitingForRoom = false;
    GlassNotice.hide();
    if (resume) {
      _drift.holdOff();
      if (!playing()) {
        play(enableSync: false);
      }
    }
  }

  /// Lets the server count this player when working out where the room is;
  /// the room position is the slowest player that has a file.
  Future<void> _announceFile(SyncplayClient client) async {
    await _runBestEffortSync(
        () => client.setSyncPlayPlaying(_currentFile(), 10800, 220514438));
  }

  Future<void> _resetRoomState() async {
    if (_waitingForPeers) {
      _waitingForPeers = false;
      GlassNotice.hide();
    }
    _stopWaitingForRoom(resume: false);
    _announceWhenCaughtUp = false;
    _peerFiles.clear();
    followEpisode = null;
    await _stopNudge();
  }

  void setCurrentPosition({bool? forceSyncPlaying, double? forceSyncPosition}) {
    if (syncplayController == null) {
      return;
    }
    // Waiting for someone is local: the room keeps playing for them.
    forceSyncPlaying ??= playing() || _waitingForPeers || _waitingForRoom;
    syncplayController!.setPaused(!forceSyncPlaying);
    syncplayController!.setPosition(forceSyncPosition ?? _reportedPosition());
  }

  Future<void> setPlayingBangumi(
      {bool? forceSyncPlaying, double? forceSyncPosition}) async {
    final client = syncplayController;
    if (client == null) {
      return;
    }
    final previousFile = client.ownFileName;
    final file = _currentFile();
    if (previousFile != file) {
      followEpisode = null;
      _drift.holdOff();
      await _stopNudge();
    }
    await _runBestEffortSync(() async {
      await client.setSyncPlayPlaying(file, 10800, 220514438);
      if (!identical(syncplayController, client)) {
        return;
      }
      setCurrentPosition(
          forceSyncPlaying: forceSyncPlaying,
          forceSyncPosition: forceSyncPosition);
      await client.sendSyncPlaySyncRequest(doSeek: null);
    });
    if (previousFile != null &&
        previousFile != file &&
        identical(syncplayController, client)) {
      await _waitForPeers(client, previousFile);
    }
  }

  Future<void> requestSync({bool? doSeek}) async {
    final client = syncplayController;
    if (client == null) {
      return;
    }
    await _runBestEffortSync(
        () => client.sendSyncPlaySyncRequest(doSeek: doSeek));
  }

  Future<void> sendChatMessage(String message) async {
    final client = syncplayController;
    if (client == null) {
      return;
    }
    await _runBestEffortSync(() => client.sendChatMessage(message));
  }

  Future<void> _runBestEffortSync(Future<void> Function() operation) async {
    try {
      await operation();
    } on SyncplayConnectionException {
      // Socket handlers report active connection failures.
    }
  }

  @action
  Future<void> exitRoom() async {
    _backoff.reset();
    _room = null;
    _pendingLeft.clear();
    _ghosts.clear();
    // The next room starts from whatever network it opens on.
    _watchdog.forgetNetwork();
    _reconnectNoticeAt = null;
    if (_reconnectNoticeShown) {
      _reconnectNoticeShown = false;
      GlassNotice.hide();
    }
    _connectionSessions.cancel();
    final controller = syncplayController;
    syncplayController = null;
    syncplayRoom = '';
    syncplayClientRtt = 0;
    await _resetRoomState();
    if (controller == null) {
      return;
    }
    await controller.disconnect();
  }

  Future<void> dispose() async {
    _connectionSessions.close();
    await exitRoom();
    await _chatStreamController.close();
  }
}
