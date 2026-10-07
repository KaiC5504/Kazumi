import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
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
import 'package:kazumi/services/download/mirror_selector.dart';
import 'package:kazumi/services/library/host_router.dart';
import 'package:kazumi/services/library/library_api.dart';
import 'package:kazumi/services/library/library_invite.dart';
import 'package:kazumi/services/library/library_playback.dart';
import 'package:kazumi/services/library/route_check_store.dart';
import 'package:kazumi/services/library/route_probe.dart';
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
  ) {
    MirrorRegistry.expand = _mirrorUrlsFor;
  }

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
  final Observable<int> routeVersion = Observable(0);
  late final RouteCheckStore _routeStore = RouteCheckStore(
    read: () => GStorage.getSetting(SettingsKeys.libraryRouteCheck),
    write: (v) =>
        GStorage.putSetting<String>(SettingsKeys.libraryRouteCheck, v),
  );
  HostRouter? _router;

  final StreamController<LibraryEpisode> _remotePicks =
      StreamController<LibraryEpisode>.broadcast();

  /// Episodes someone else in the room picked while this device sat in the
  /// lobby. The lobby page opens them.
  Stream<LibraryEpisode> get remotePicks => _remotePicks.stream;

  StreamSubscription<Uri>? _linkSubscription;
  String? _lastLink;
  DateTime _lastLinkAt = DateTime.fromMillisecondsSinceEpoch(0);

  Timer? _heartbeat;
  Future<void>? _beatInFlight;
  AppLifecycleListener? _lifecycle;
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

  LibraryApi? get _api => isConfigured
      ? LibraryApi(server, key, apiHost: router.order.first)
      : null;

  /// Lobby calls go through the chosen host; one retry on the other host
  /// when it can't be reached.
  Future<T> _call<T>(Future<T> Function(LibraryApi api) call) async {
    final order = router.order;
    try {
      return await call(LibraryApi(server, key, apiHost: order.first));
    } on LibraryException catch (e) {
      final status = e.statusCode;
      // A relay without the /api route answers 404 itself.
      final unreachable =
          status == null ||
          status >= 500 ||
          (status == HttpStatus.notFound && router.isRelay(order.first));
      if (!unreachable || order.length < 2) rethrow;
      router.reportFailure(order.first);
      return call(LibraryApi(server, key, apiHost: order[1]));
    }
  }

  RouteMode get routeMode =>
      RouteMode.parse(GStorage.getSetting(SettingsKeys.libraryRoute));

  RouteCheckResult? get storedRoute => _routeStore.stored;

  HostRouter get router {
    final server = LibraryApi.normalizeServer(this.server);
    final relays = [for (final m in _mirrors) LibraryApi.normalizeServer(m)];
    final stored = _routeStore.stored;
    final current = _router;
    if (current != null &&
        current.server == server &&
        current.mode == routeMode &&
        current.stored?.at == stored?.at &&
        listEquals(current.relays, relays)) {
      return current;
    }
    return _router = HostRouter(
      server: server,
      relays: relays,
      mode: routeMode,
      stored: stored,
    );
  }

  Future<void> setRouteMode(RouteMode mode) async {
    await GStorage.putSetting<String>(
      SettingsKeys.libraryRoute,
      mode.storageValue,
    );
    runInAction(() => routeVersion.value++);
  }

  Future<RouteCheckResult?> _check({required bool force}) async {
    final RouteCheckResult? result;
    try {
      final r = router;
      result = await _routeStore.ensure(
        configured: isConfigured,
        force: force,
        check: () async {
          final sampleId = await _sampleEpisodeId();
          final api = LibraryApi(server, key);
          return runRouteCheck(
            server: r.server,
            relays: r.relays,
            sampleFor: (host) => sampleId == null
                ? host.replace(path: '/speedtest/1m.bin')
                : api.videoUri(sampleId, via: host),
          );
        },
      );
    } catch (e) {
      KazumiLogger().w('LibraryController: route check failed', error: e);
      return null;
    }
    runInAction(() => routeVersion.value++);
    return result;
  }

  /// At launch the lobby hasn't loaded episodes yet. A real episode keeps
  /// Singapore comparable: it has no /speedtest file, so a 404 there would
  /// count as unreachable.
  Future<String?> _sampleEpisodeId() async {
    if (episodes.isNotEmpty) return episodes.first.id;
    try {
      final list = await _call((api) => api.episodes());
      return list.isEmpty ? null : list.first.id;
    } catch (_) {
      return null;
    }
  }

  /// Background, once ever: the answer is stored and reused.
  void scheduleRouteCheckOnce() {
    try {
      if (!isConfigured || _routeStore.stored != null) return;
    } catch (_) {
      return;
    }
    unawaited(_check(force: false));
  }

  Future<RouteCheckResult?> recheckRoute() => _check(force: true);

  /// Relays from the last server config. Kept in settings so downloads
  /// resumed before the lobby is opened can use them too.
  List<String> get _mirrors => GStorage.getSetting(
    SettingsKeys.libraryMirrors,
  ).split('\n').where((m) => m.isNotEmpty).toList();

  List<Uri> _hostsFor(LibraryApi api) => router.order;

  List<String>? _mirrorUrlsFor(String url) {
    final api = _api;
    if (api == null || !api.ownsUrl(url)) return null;
    return [for (final host in _hostsFor(api)) LibraryApi.rehost(url, host)];
  }

  Future<void> init() async {
    // A backgrounded phone or a PC minimised to the tray can't follow a pick,
    // so it leaves the room until it's back on screen.
    _lifecycle = AppLifecycleListener(
      onHide: () {
        if (_inLobby && _playingId == null) unawaited(_leaveRoom());
      },
      onShow: () {
        if (_inLobby && _heartbeat == null) {
          _lastSelectionSeq = null;
          _startHeartbeat();
        }
      },
    );
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
      scheduleRouteCheckOnce();
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
    await GStorage.putSetting<String>(
      SettingsKeys.libraryMirrors,
      config.mirrors.join('\n'),
    );
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
      if (!isConfigured) return;
      await _applyConfig(await _call((api) => api.config()));
    } catch (e) {
      KazumiLogger().w('LibraryController: config refresh failed', error: e);
    }
  }

  /// Returns an error message, or null once the invite is ready to accept.
  Future<String?> redeemCode(String text) async {
    final code = normalizeInviteCode(text);
    if (code == null) return '邀请码是 8 位字母和数字';
    try {
      final key = await LibraryApi.redeem(defaultLibraryServer, code);
      showInvite(LibraryInvite(server: defaultLibraryServer, key: key));
      return null;
    } on LibraryException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
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
      SettingsKeys.libraryMirrors,
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
      final list = await _call((api) => api.episodes());
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

  List<String> _videoUrls(LibraryApi api, LibraryEpisode episode) => [
    for (final host in _hostsFor(api))
      api.videoUri(episode.id, via: host).toString(),
  ];

  Future<void> leaveLobby() async {
    _inLobby = false;
    if (_playingId == null) await _leaveRoom();
  }

  /// Leaves the room right away instead of waiting for the server to time
  /// this device out. Also called just before the desktop app exits.
  Future<void> sayGoodbye() async {
    try {
      await _leaveRoom().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  Future<void> _leaveRoom() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    final api = _api;
    if (api == null) return;
    // A beat still on the wire would land after the goodbye and put this
    // device straight back in the room.
    await _beatInFlight;
    try {
      await _call((api) => api.leave(deviceId));
    } catch (e) {
      KazumiLogger().w('LibraryController: leave failed', error: e);
    }
  }

  void _startHeartbeat() {
    _heartbeat ??= Timer.periodic(_heartbeatInterval, (_) => _beat());
    unawaited(_beat());
  }

  Future<void> _beat() async {
    final api = _api;
    if (api == null || _beatInFlight != null) return;
    final done = Completer<void>();
    _beatInFlight = done.future;
    try {
      final result = await _call(
        (api) => api.heartbeat(
          deviceId: deviceId,
          name: displayName,
          state: _playingId != null ? 'watching' : 'lobby',
          episodeId: _playingId,
        ),
      );
      runInAction(() => room.value = result);
      await _handleSelection(result.selection);
    } catch (e) {
      // Presence is best-effort; the next beat retries.
    } finally {
      _beatInFlight = null;
      done.complete();
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
      unawaited(_announce(episode));
    }

    final series = seriesOf(episode);
    final playlist = <DownloadEpisode>[];
    final remote = <int, List<String>>{};
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
        remote[e.manifest.episodeNumber] = _videoUrls(api, e);
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

  Future<void> _announce(LibraryEpisode episode) async {
    try {
      final result = await _call(
        (api) => api.select(
          deviceId: deviceId,
          name: displayName,
          episodeId: episode.id,
        ),
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
    if (roomName.isNotEmpty && !player.syncplay.inRoom) {
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
  void onStreamHostFailed(String failedUrl) {
    KazumiLogger().w('LibraryController: stream host failed $failedUrl');
    final uri = Uri.tryParse(failedUrl);
    if (uri == null || !isConfigured) return;
    router.reportFailure(
      Uri(
        scheme: uri.scheme,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
      ),
    );
    runInAction(() => routeVersion.value++);
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
      unawaited(_leaveRoom());
    }
  }

  Future<void> _markWatched(LibraryEpisode episode) async {
    _watchedHere.add(episode.id);
    try {
      if (!isConfigured) return;
      await _call((api) => api.markWatched(episode.id, displayName));
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
    final urls = _videoUrls(api, episode);
    final local = localEpisode(episode);
    // Anything already on the device, including an original-quality download
    // of the same episode, is left alone. One still in progress keeps its URL
    // but can fall back to the other hosts.
    if (local != null && local.status != DownloadStatus.failed) {
      final queued = local.networkM3u8Url;
      if (local.preUpscaled && api.ownsUrl(queued)) {
        MirrorRegistry.register([queued, ...urls.where((u) => u != queued)]);
      }
      return;
    }
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
      for (final host in _hostsFor(api)) {
        try {
          final bytes = await api.download(
            api.danmakuUri(episode.id, via: host),
          );
          await File(
            path.join(targetDir, upscaledDanmakuFileName),
          ).writeAsBytes(bytes, flush: true);
          break;
        } catch (e) {
          KazumiLogger().w(
            'LibraryController: danmaku via ${host.host} failed',
            error: e,
          );
        }
      }
    }
    MirrorRegistry.register(urls);
    entity
      ..downloadDirectory = targetDir
      ..networkM3u8Url = urls.first;
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
    _lifecycle?.dispose();
    _heartbeat?.cancel();
    _watchTimer?.cancel();
    _remotePicks.close();
  }
}
