import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/player/player_controller.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/services/library/library_api.dart';
import 'package:kazumi/services/library/library_invite.dart';
import 'package:kazumi/services/library/library_playback.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/upscale/upscaled_package.dart';
import 'package:mobx/mobx.dart';
import 'package:path/path.dart' as path;

/// The shared "watch together" library: episodes baked on the owner's PC,
/// hosted on his server, downloaded ahead and cleaned up behind on each
/// viewer's device, plus a lobby where either person picks what to watch.
class LibraryController implements OfflinePlaybackHooks {
  LibraryController(
    this._repository,
    this._downloadController,
    this._downloadManager,
  );

  final IDownloadRepository _repository;
  final DownloadController _downloadController;
  final IDownloadManager _downloadManager;

  static const _heartbeatInterval = Duration(seconds: 3);
  static const _prefetchAhead = 2;
  static const _watchedFraction = 0.9;

  final ObservableList<LibraryEpisode> episodes =
      ObservableList<LibraryEpisode>();
  final Observable<LibraryRoomState> room = Observable(LibraryRoomState.empty);
  final Observable<bool> loading = Observable(false);
  final Observable<String?> error = Observable(null);
  final Observable<String?> notice = Observable(null);
  final Observable<LibraryInvite?> pendingInvite = Observable(null);
  final Observable<int> configVersion = Observable(0);

  final StreamController<LibraryEpisode> _remotePicks =
      StreamController<LibraryEpisode>.broadcast();

  /// Episodes someone else in the room picked while this device sat in the
  /// lobby. The lobby page opens them.
  Stream<LibraryEpisode> get remotePicks => _remotePicks.stream;

  StreamSubscription<Uri>? _linkSubscription;
  String? _lastLink;
  DateTime _lastLinkAt = DateTime.fromMillisecondsSinceEpoch(0);

  Timer? _heartbeat;
  bool _heartbeatBusy = false;
  bool _inLobby = false;
  int? _lastSelectionSeq;

  String? _playingId;
  Timer? _watchTimer;
  final Set<String> _watchedHere = {};

  bool get isConfigured => server.isNotEmpty && key.isNotEmpty;
  String get server => GStorage.getSetting(SettingsKeys.libraryServer);
  String get key => GStorage.getSetting(SettingsKeys.libraryKey);
  String get syncRoom => GStorage.getSetting(SettingsKeys.libraryRoom);
  String get displayName =>
      GStorage.getSetting(SettingsKeys.libraryDisplayName);
  bool get wifiOnly => GStorage.getSetting(SettingsKeys.libraryWifiOnly);
  String? get playingId => _playingId;

  String get deviceId {
    var id = GStorage.getSetting(SettingsKeys.libraryDeviceId);
    if (id.isEmpty) {
      final random = Random.secure();
      id = List.generate(
        16,
        (_) => random.nextInt(16).toRadixString(16),
      ).join();
      GStorage.putSetting<String>(SettingsKeys.libraryDeviceId, id);
    }
    return id;
  }

  LibraryApi? get _api => isConfigured ? LibraryApi(server, key) : null;

  Future<void> init() async {
    if (!Platform.isIOS && !Platform.isAndroid) return;
    try {
      _linkSubscription = AppLinks().uriLinkStream.listen(
        _handleLink,
        onError: (Object e) =>
            KazumiLogger().w('LibraryController: app link error', error: e),
      );
    } catch (e) {
      KazumiLogger().w('LibraryController: app links unavailable', error: e);
    }
  }

  void _handleLink(Uri uri) {
    final text = uri.toString();
    final now = DateTime.now();
    // Cold starts can deliver the launch link twice.
    if (text == _lastLink && now.difference(_lastLinkAt).inSeconds < 5) {
      return;
    }
    _lastLink = text;
    _lastLinkAt = now;
    final invite = LibraryInvite.parse(text);
    if (invite == null) return;
    runInAction(() => pendingInvite.value = invite);
    // Give the startup route time to settle before stacking the lobby on it.
    Future.delayed(const Duration(milliseconds: 1200), openLobbyRoute);
  }

  void openLobbyRoute() {
    final context = rootNavigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    try {
      if (context.routeState(listen: false).uri.path.startsWith('/library')) {
        return;
      }
    } catch (_) {}
    context.pushNamed('/library/');
  }

  /// Validates the invite against the server before saving anything.
  Future<String?> acceptInvite(LibraryInvite invite, String name) async {
    try {
      final config = await LibraryApi(invite.server, invite.key).config();
      await GStorage.putSetting<String>(
        SettingsKeys.libraryServer,
        invite.server,
      );
      await GStorage.putSetting<String>(SettingsKeys.libraryKey, invite.key);
      await GStorage.putSetting<String>(
        SettingsKeys.libraryDisplayName,
        name.trim(),
      );
      await _applyConfig(config);
      runInAction(() {
        pendingInvite.value = null;
        configVersion.value++;
      });
      return null;
    } on LibraryException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
    }
  }

  /// [SettingsKeys.librarySyncPlayEndPoint] is only set while the server
  /// offers TLS, because the player requests TLS from exactly that endpoint.
  Future<void> _applyConfig(LibraryConfig config) async {
    await GStorage.putSetting<String>(SettingsKeys.libraryRoom, config.room);
    if (config.syncPlayEndPoint.isEmpty) return;
    await GStorage.putSetting<String>(
      SettingsKeys.syncPlayEndPoint,
      config.syncPlayEndPoint,
    );
    await GStorage.putSetting<String>(
      SettingsKeys.librarySyncPlayEndPoint,
      config.syncPlayTls ? config.syncPlayEndPoint : '',
    );
  }

  Future<void> _refreshConfig() async {
    try {
      final config = await _api?.config();
      if (config != null) await _applyConfig(config);
    } catch (e) {
      KazumiLogger().w('LibraryController: config refresh failed', error: e);
    }
  }

  void showInvite(LibraryInvite invite) =>
      runInAction(() => pendingInvite.value = invite);

  void dismissInvite() => runInAction(() => pendingInvite.value = null);

  Future<void> setDisplayName(String name) async {
    await GStorage.putSetting<String>(
      SettingsKeys.libraryDisplayName,
      name.trim(),
    );
    runInAction(() => configVersion.value++);
  }

  Future<void> setWifiOnly(bool value) async {
    await GStorage.putSetting<bool>(SettingsKeys.libraryWifiOnly, value);
    runInAction(() => configVersion.value++);
    if (!value) await prefetchFromLobby();
  }

  Future<void> leaveLibrary() async {
    await leaveLobby();
    for (final key in [
      SettingsKeys.libraryServer,
      SettingsKeys.libraryKey,
      SettingsKeys.libraryRoom,
    ]) {
      await GStorage.putSetting<String>(key, '');
    }
    runInAction(() {
      episodes.clear();
      room.value = LibraryRoomState.empty;
      configVersion.value++;
    });
  }

  Future<void> refresh() async {
    final api = _api;
    if (api == null) return;
    runInAction(() {
      loading.value = true;
      error.value = null;
    });
    try {
      final list = await api.episodes();
      runInAction(() {
        episodes
          ..clear()
          ..addAll(list);
      });
    } on LibraryException catch (e) {
      runInAction(() => error.value = e.message);
    } catch (e) {
      runInAction(() => error.value = '$e');
    } finally {
      runInAction(() => loading.value = false);
    }
  }

  Future<void> enterLobby() async {
    _inLobby = true;
    _lastSelectionSeq = null;
    _startHeartbeat();
    await _refreshConfig();
    await refresh();
    await cleanup();
    await prefetchFromLobby();
  }

  Future<void> leaveLobby() async {
    _inLobby = false;
    if (_playingId == null) {
      _heartbeat?.cancel();
      _heartbeat = null;
      await _beat(state: 'idle');
    }
  }

  void _startHeartbeat() {
    _heartbeat ??= Timer.periodic(_heartbeatInterval, (_) => _beat());
    unawaited(_beat());
  }

  Future<void> _beat({String? state}) async {
    final api = _api;
    if (api == null || _heartbeatBusy) return;
    _heartbeatBusy = true;
    try {
      final result = await api.heartbeat(
        deviceId: deviceId,
        name: displayName,
        state: state ?? (_playingId != null ? 'watching' : 'lobby'),
        episodeId: _playingId,
      );
      runInAction(() => room.value = result);
      await _handleSelection(result.selection);
    } catch (e) {
      // Presence is best-effort; the next beat retries.
    } finally {
      _heartbeatBusy = false;
    }
  }

  Future<void> _handleSelection(LibrarySelection? selection) async {
    if (selection == null) return;
    final previous = _lastSelectionSeq;
    _lastSelectionSeq = selection.seq;
    // The first beat only records where the room is, so an old pick never
    // yanks someone into an episode when they open the lobby.
    if (previous == null || selection.seq <= previous) return;
    if (selection.byDeviceId == deviceId || !_inLobby || _playingId != null) {
      return;
    }
    var episode = _byId(selection.episodeId);
    if (episode == null) {
      await refresh();
      episode = _byId(selection.episodeId);
    }
    if (episode != null) _remotePicks.add(episode);
  }

  LibraryEpisode? _byId(String id) {
    for (final e in episodes) {
      if (e.id == id) return e;
    }
    return null;
  }

  List<LibraryEpisode> seriesOf(LibraryEpisode episode) =>
      episodes
          .where((e) => e.manifest.recordKey == episode.manifest.recordKey)
          .toList()
        ..sort(
          (a, b) =>
              a.manifest.episodeNumber.compareTo(b.manifest.episodeNumber),
        );

  DownloadEpisode? localEpisode(LibraryEpisode episode) => _repository
      .getRecord(episode.manifest.recordKey)
      ?.episodes[episode.manifest.episodeNumber];

  /// Observable copy for UI; [localEpisode] reads storage directly.
  DownloadEpisode? observedLocal(LibraryEpisode episode) => _downloadController
      .getRecordSnapshot(episode.manifest.recordKey)
      ?.episodes[episode.manifest.episodeNumber];

  bool isWatchedByMe(LibraryEpisode episode) =>
      _watchedHere.contains(episode.id) ||
      episode.watchedBy.contains(displayName);

  /// Opens [episode] in the player. Every episode of the series goes into
  /// the playlist, local or not, so both devices number them the same way
  /// and SyncPlay episode switches line up.
  Future<void> openEpisode(
    BuildContext context,
    LibraryEpisode episode, {
    bool announce = true,
  }) async {
    final api = _api;
    if (api == null) return;
    if (announce) {
      unawaited(_announce(api, episode));
    }

    final series = seriesOf(episode);
    final playlist = <DownloadEpisode>[];
    final remote = <int, String>{};
    for (final e in series) {
      final local = localEpisode(e);
      final ready =
          local != null &&
          local.preUpscaled &&
          local.status == DownloadStatus.completed;
      if (ready) {
        playlist.add(local);
      } else {
        playlist.add(e.manifest.toDownloadEntities().$2);
        remote[e.manifest.episodeNumber] = api.videoUri(e.id).toString();
      }
    }

    final manifest = episode.manifest;
    final bangumiItem = BangumiItem(
      id: manifest.bangumiId,
      type: 2,
      name: manifest.bangumiName,
      nameCn: manifest.bangumiName,
      summary: '',
      airDate: '',
      airWeekday: 0,
      rank: 0,
      images: {'large': manifest.bangumiCover},
      tags: [],
      alias: [],
      ratingScore: 0.0,
      votes: 0,
      votesCount: [],
      info: '',
    );
    if (!context.mounted) return;
    context.pushNamed(
      '/video/',
      arguments: OfflineVideoPlaybackArgs(
        bangumiItem: bangumiItem,
        pluginName: manifest.pluginName,
        episodeNumber: manifest.episodeNumber,
        road: manifest.road,
        downloadedEpisodes: playlist,
        remoteVideoUrls: remote,
        hooks: this,
      ),
    );
  }

  Future<void> _announce(LibraryApi api, LibraryEpisode episode) async {
    try {
      final result = await api.select(
        deviceId: deviceId,
        name: displayName,
        episodeId: episode.id,
      );
      _lastSelectionSeq = result.selection?.seq ?? _lastSelectionSeq;
      runInAction(() => room.value = result);
    } catch (e) {
      KazumiLogger().w('LibraryController: select failed', error: e);
    }
  }

  @override
  void onEpisodeStarted(
    int episodeNumber,
    PlayerController player,
    EpisodeChanger changeEpisode,
  ) {
    LibraryEpisode? current;
    for (final e in episodes) {
      if (e.manifest.bangumiId == player.bangumiId &&
          e.manifest.episodeNumber == episodeNumber) {
        current = e;
      }
    }
    if (current == null) return;
    _playingId = current.id;
    _startHeartbeat();

    final roomName = syncRoom;
    if (roomName.isNotEmpty && !player.syncplay.hasSession) {
      unawaited(
        player.createSyncPlayRoom(roomName, displayName, changeEpisode),
      );
    }

    _watchTimer?.cancel();
    final watching = current;
    _watchTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      final duration = player.playback.duration;
      final position = player.playback.currentPosition;
      if (duration.inMinutes < 2) return;
      if (position.inMilliseconds / duration.inMilliseconds >=
          _watchedFraction) {
        timer.cancel();
        unawaited(_markWatched(watching));
      }
    });

    unawaited(_prefetchAfter(watching));
  }

  @override
  void onPlaybackClosed() {
    _watchTimer?.cancel();
    _watchTimer = null;
    _playingId = null;
    if (_inLobby) {
      unawaited(_beat());
      unawaited(refresh().then((_) => cleanup()));
    } else {
      _heartbeat?.cancel();
      _heartbeat = null;
      unawaited(_beat(state: 'idle'));
    }
  }

  Future<void> _markWatched(LibraryEpisode episode) async {
    _watchedHere.add(episode.id);
    try {
      await _api?.markWatched(episode.id, displayName);
    } catch (e) {
      KazumiLogger().w('LibraryController: mark watched failed', error: e);
    }
  }

  /// In the lobby, get the next unwatched episode of each series ready so
  /// the first one doesn't have to stream.
  Future<void> prefetchFromLobby() async {
    final seen = <String>{};
    for (final e in episodes) {
      if (!seen.add(e.manifest.recordKey)) continue;
      final next = seriesOf(e).where((s) => !isWatchedByMe(s)).take(1);
      for (final target in next) {
        await _download(target);
      }
    }
  }

  Future<void> _prefetchAfter(LibraryEpisode current) async {
    final ahead = seriesOf(current)
        .where((e) => e.manifest.episodeNumber > current.manifest.episodeNumber)
        .take(_prefetchAhead);
    for (final e in ahead) {
      await _download(e);
    }
    await cleanup();
  }

  Future<bool> _allowedToDownload() async {
    if (!wifiOnly) return true;
    try {
      final results = await Connectivity().checkConnectivity();
      final ok =
          results.contains(ConnectivityResult.wifi) ||
          results.contains(ConnectivityResult.ethernet);
      runInAction(() => notice.value = ok ? null : '当前不是 Wi-Fi，已暂停自动下载');
      return ok;
    } catch (_) {
      return true;
    }
  }

  Future<void> _download(LibraryEpisode episode) async {
    final api = _api;
    if (api == null) return;
    final local = localEpisode(episode);
    // Anything already on the device, including an original-quality download
    // of the same episode, is left alone.
    if (local != null && local.status != DownloadStatus.failed) return;
    if (!await _allowedToDownload()) return;

    final manifest = episode.manifest;
    if (local != null) {
      await _downloadController.deleteEpisode(
        manifest.bangumiId,
        manifest.pluginName,
        manifest.episodeNumber,
      );
    }
    final (record, entity) = manifest.toDownloadEntities();
    final targetDir = await _downloadManager.episodeDirectoryFor(
      manifest.bangumiId,
      manifest.pluginName,
      manifest.episodeNumber,
    );
    await Directory(targetDir).create(recursive: true);
    if (manifest.hasDanmaku) {
      try {
        final bytes = await api.download(api.danmakuUri(episode.id));
        await File(
          path.join(targetDir, upscaledDanmakuFileName),
        ).writeAsBytes(bytes, flush: true);
      } catch (e) {
        KazumiLogger().w('LibraryController: danmaku skipped', error: e);
      }
    }
    entity
      ..downloadDirectory = targetDir
      ..networkM3u8Url = api.videoUri(episode.id).toString();
    await _downloadController.enqueuePreUpscaled(record, entity);
  }

  /// Removes library episodes this person has finished, except the one
  /// playing and the ones queued up after it.
  Future<void> cleanup() async {
    final api = _api;
    if (api == null) return;
    final keep = <String>{};
    final playing = _playingId == null ? null : _byId(_playingId!);
    if (playing != null) {
      keep.add(playing.id);
      keep.addAll(
        seriesOf(playing)
            .where(
              (e) => e.manifest.episodeNumber > playing.manifest.episodeNumber,
            )
            .take(_prefetchAhead)
            .map((e) => e.id),
      );
    }

    for (final record in _repository.getAllRecords()) {
      for (final local in record.episodes.values.toList()) {
        if (!local.preUpscaled || !api.ownsUrl(local.networkM3u8Url)) continue;
        final episode = episodes.firstWhere(
          (e) =>
              e.manifest.recordKey == record.key &&
              e.manifest.episodeNumber == local.episodeNumber,
          orElse: () => _orphan,
        );
        if (identical(episode, _orphan) || keep.contains(episode.id)) continue;
        if (!isWatchedByMe(episode)) continue;
        await _downloadController.deleteEpisode(
          record.bangumiId,
          record.pluginName,
          local.episodeNumber,
        );
      }
    }
  }

  static final _orphan = LibraryEpisode(
    id: '',
    manifest: UpscaledEpisodeManifest.fromJson(const {
      'version': 1,
      'bangumiId': 0,
      'pluginName': '',
      'episodeNumber': 0,
    }),
    watchedBy: const [],
  );

  void dispose() {
    _linkSubscription?.cancel();
    _heartbeat?.cancel();
    _watchTimer?.cancel();
    _remotePicks.close();
  }
}
