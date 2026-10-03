import 'dart:async';
import 'dart:io';

import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/shaders/shader_asset_service.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/upscale/lan_share.dart';
import 'package:kazumi/services/upscale/upscale_baker.dart';
import 'package:kazumi/services/upscale/upscaled_import_service.dart';
import 'package:kazumi/services/upscale/upscaled_package.dart';
import 'package:kazumi/utils/device.dart';
import 'package:mobx/mobx.dart';
import 'package:path/path.dart' as path;

/// Bakes, exports, imports and shares pre-upscaled episodes.
///
/// Baking and sharing run on desktop; importing and pulling are meant for
/// devices too weak to run the quality tier live.
class UpscaleController {
  UpscaleController(
    this._repository,
    this._downloadManager,
    this._downloadController,
    this._shaderAssetService,
  ) {
    _lanServer = LanShareServer(sharedEpisodes);
  }

  final IDownloadRepository _repository;
  final IDownloadManager _downloadManager;
  final DownloadController _downloadController;
  final ShaderAssetService _shaderAssetService;
  final importService = UpscaledImportService();
  late final LanShareServer _lanServer;

  /// Keyed by '${recordKey}_$episodeNumber', 0..1.
  final ObservableMap<String, double> bakeProgress =
      ObservableMap<String, double>();
  final ObservableMap<String, double> exportProgress =
      ObservableMap<String, double>();
  final Observable<bool> lanShareRunning = Observable(false);

  FfmpegInfo? _ffmpeg;
  final List<(String, int)> _bakeQueue = [];
  UpscaleBaker? _activeBaker;
  String? _activeKey;

  bool get canBake => isDesktop();

  static String progressKey(String recordKey, int episodeNumber) =>
      '${recordKey}_$episodeNumber';

  Future<void> init() async {
    for (final record in _repository.getAllRecords()) {
      var changed = false;
      for (final episode in record.episodes.values) {
        final interrupted =
            episode.upscaleStatus == UpscaleStatus.queued ||
            episode.upscaleStatus == UpscaleStatus.baking;
        final missing =
            episode.upscaleStatus == UpscaleStatus.done &&
            !File(episode.upscaledVideoPath).existsSync();
        if (interrupted || missing) {
          episode.upscaleStatus = UpscaleStatus.none;
          episode.upscaledVideoPath = '';
          changed = true;
        }
      }
      if (changed) await _repository.putRecord(record);
    }
    if (canBake && GStorage.getSetting(SettingsKeys.lanShareEnabled)) {
      try {
        await startLanShare();
      } catch (e) {
        KazumiLogger().w(
          'UpscaleController: LAN share failed to start',
          error: e,
        );
      }
    }
  }

  Future<(FfmpegInfo?, String?)> detectFfmpeg() async {
    final (info, error) = await UpscaleBaker.detect(
      GStorage.getSetting(SettingsKeys.upscaleFfmpegPath),
    );
    _ffmpeg = info;
    return (info, error);
  }

  /// Returns an error message, or null once the episode is queued.
  Future<String?> enqueueBake(String recordKey, int episodeNumber) async {
    if (!canBake) return '仅支持在电脑端烘焙';
    final episode = _repository.getRecord(recordKey)?.episodes[episodeNumber];
    if (episode == null || episode.status != DownloadStatus.completed) {
      return '请先完成下载';
    }
    if (episode.preUpscaled) return '该集已是超分版本';
    if (_ffmpeg == null) {
      final (info, error) = await detectFfmpeg();
      if (info == null) return error ?? '未找到可用的 ffmpeg';
    }
    if (_bakeQueue.contains((recordKey, episodeNumber)) ||
        _activeKey == progressKey(recordKey, episodeNumber)) {
      return null;
    }
    _bakeQueue.add((recordKey, episodeNumber));
    await _updateEpisode(recordKey, episodeNumber, (e) {
      e.upscaleStatus = UpscaleStatus.queued;
    });
    unawaited(_pumpBakeQueue());
    return null;
  }

  Future<void> cancelBake(String recordKey, int episodeNumber) async {
    final key = progressKey(recordKey, episodeNumber);
    if (_activeKey == key) {
      _activeBaker?.cancel();
      return;
    }
    _bakeQueue.remove((recordKey, episodeNumber));
    await _updateEpisode(recordKey, episodeNumber, (e) {
      e.upscaleStatus = UpscaleStatus.none;
    });
  }

  Future<void> _pumpBakeQueue() async {
    if (_activeKey != null) return;
    while (_bakeQueue.isNotEmpty) {
      final (recordKey, episodeNumber) = _bakeQueue.removeAt(0);
      await _bakeOne(recordKey, episodeNumber);
    }
  }

  Future<void> _bakeOne(String recordKey, int episodeNumber) async {
    final record = _repository.getRecord(recordKey);
    final episode = record?.episodes[episodeNumber];
    final ffmpeg = _ffmpeg;
    if (record == null || episode == null || ffmpeg == null) return;

    final key = progressKey(recordKey, episodeNumber);
    final baker = UpscaleBaker();
    _activeKey = key;
    _activeBaker = baker;
    runInAction(() => bakeProgress[key] = 0);
    await _updateEpisode(recordKey, episodeNumber, (e) {
      e.upscaleStatus = UpscaleStatus.baking;
    });

    final output = path.join(
      episode.downloadDirectory,
      'upscaled',
      upscaledVideoFileName,
    );
    final int targetHeight = GStorage.getSetting(
      SettingsKeys.upscaleBakeHeight,
    );
    final stopwatch = Stopwatch()..start();
    try {
      final shader = await UpscaleBaker.buildCombinedShader(
        _shaderAssetService.shadersDirectory.path,
      );
      await baker.bake(
        ffmpeg: ffmpeg,
        input: episode.localM3u8Path,
        output: output,
        shaderPath: shader,
        targetHeight: targetHeight,
        onProgress: (p) => runInAction(() => bakeProgress[key] = p),
      );
      KazumiLogger().i(
        'UpscaleController: baked $key in ${stopwatch.elapsed.inSeconds}s',
      );
      await _updateEpisode(recordKey, episodeNumber, (e) {
        e.upscaleStatus = UpscaleStatus.done;
        e.upscaledVideoPath = output;
        e.upscaledHeight = targetHeight;
      });
      if (GStorage.getSetting(SettingsKeys.upscaleAutoExport) &&
          GStorage.getSetting(SettingsKeys.upscaleExportDirectory).isNotEmpty) {
        final error = await export(recordKey, episodeNumber);
        if (error != null) {
          KazumiLogger().w('UpscaleController: auto export failed: $error');
        }
      }
    } on UpscaleBakeCancelled {
      await _updateEpisode(recordKey, episodeNumber, (e) {
        e.upscaleStatus = UpscaleStatus.none;
      });
    } catch (e) {
      KazumiLogger().e('UpscaleController: bake failed for $key', error: e);
      await _updateEpisode(recordKey, episodeNumber, (ep) {
        ep.upscaleStatus = UpscaleStatus.failed;
        ep.errorMessage = '超分失败: $e';
      });
    } finally {
      runInAction(() => bakeProgress.remove(key));
      _activeKey = null;
      _activeBaker = null;
    }
  }

  /// Copies a baked episode into the configured export folder. Returns an
  /// error message on failure.
  Future<String?> export(String recordKey, int episodeNumber) async {
    final exportRoot = GStorage.getSetting(SettingsKeys.upscaleExportDirectory);
    if (exportRoot.isEmpty) return '请先在下载设置中选择导出文件夹';
    final record = _repository.getRecord(recordKey);
    final episode = record?.episodes[episodeNumber];
    if (record == null ||
        episode == null ||
        episode.upscaleStatus != UpscaleStatus.done) {
      return '该集尚未完成超分';
    }

    final key = progressKey(recordKey, episodeNumber);
    runInAction(() => exportProgress[key] = 0);
    try {
      final video = File(episode.upscaledVideoPath);
      final danmaku = File(
        path.join(episode.downloadDirectory, upscaledDanmakuFileName),
      );
      final hasDanmaku = await danmaku.exists();
      final size = await video.length();
      final manifest = UpscaledEpisodeManifest.fromEpisode(
        record,
        episode,
        width: 0,
        height: episode.upscaledHeight,
        sizeBytes: size,
        hasDanmaku: hasDanmaku,
      );
      final dir = Directory(
        path.join(
          exportRoot,
          upscaledExportFolderName,
          upscaledExportDirName(manifest),
        ),
      );
      await dir.create(recursive: true);

      // Write the manifest last so a half-copied folder is never importable.
      final manifestFile = File(path.join(dir.path, upscaledManifestFileName));
      if (await manifestFile.exists()) await manifestFile.delete();

      final target = path.join(dir.path, upscaledVideoFileName);
      final partial = '$target.part';
      await importService.copy(
        video.path,
        partial,
        expectedBytes: size,
        onProgress: (p) => runInAction(() => exportProgress[key] = p),
      );
      final existing = File(target);
      if (await existing.exists()) await existing.delete();
      await File(partial).rename(target);
      if (hasDanmaku) {
        await danmaku.copy(path.join(dir.path, upscaledDanmakuFileName));
      }
      await manifestFile.writeAsString(manifest.encode(), flush: true);
      return null;
    } catch (e) {
      KazumiLogger().e('UpscaleController: export failed for $key', error: e);
      return '导出失败: $e';
    } finally {
      runInAction(() => exportProgress.remove(key));
    }
  }

  bool isAlreadyDownloaded(UpscaledEpisodeManifest manifest) =>
      _repository
          .getRecord(manifest.recordKey)
          ?.episodes[manifest.episodeNumber] !=
      null;

  Future<void> importCandidate(
    UpscaledImportCandidate candidate, {
    void Function(double)? onProgress,
  }) async {
    final manifest = candidate.manifest;
    final (record, episode) = manifest.toDownloadEntities();
    final targetDir = await _downloadManager.episodeDirectoryFor(
      manifest.bangumiId,
      manifest.pluginName,
      manifest.episodeNumber,
    );
    final stagingDir = '$targetDir.importing';

    await _deleteIfExists(stagingDir);
    await importService.copy(
      candidate.videoPath,
      path.join(stagingDir, upscaledVideoFileName),
      expectedBytes: manifest.sizeBytes,
      onProgress: onProgress,
    );
    if (candidate.danmakuPath != null) {
      try {
        await importService.copy(
          candidate.danmakuPath!,
          path.join(stagingDir, upscaledDanmakuFileName),
        );
      } catch (e) {
        KazumiLogger().w('UpscaleController: danmaku import skipped', error: e);
      }
    }

    // Only drop the existing download once the replacement is fully on disk.
    if (isAlreadyDownloaded(manifest)) {
      await _downloadController.deleteEpisode(
        manifest.bangumiId,
        manifest.pluginName,
        manifest.episodeNumber,
      );
    }
    await _deleteIfExists(targetDir);
    await Directory(stagingDir).rename(targetDir);

    final videoPath = path.join(targetDir, upscaledVideoFileName);
    episode
      ..status = DownloadStatus.completed
      ..progressPercent = 1.0
      ..downloadedSegments = 1
      ..localM3u8Path = videoPath
      ..downloadDirectory = targetDir
      ..completedAt = DateTime.now()
      ..totalBytes = await File(videoPath).length();
    await _saveEpisode(record, episode);
  }

  List<SharedUpscaledEpisode> sharedEpisodes() {
    final shared = <SharedUpscaledEpisode>[];
    for (final record in _repository.getAllRecords()) {
      for (final episode in record.episodes.values) {
        if (episode.upscaleStatus != UpscaleStatus.done) continue;
        final video = File(episode.upscaledVideoPath);
        if (!video.existsSync()) continue;
        final danmaku = File(
          path.join(episode.downloadDirectory, upscaledDanmakuFileName),
        );
        final hasDanmaku = danmaku.existsSync();
        shared.add(
          SharedUpscaledEpisode(
            manifest: UpscaledEpisodeManifest.fromEpisode(
              record,
              episode,
              width: 0,
              height: episode.upscaledHeight,
              sizeBytes: video.lengthSync(),
              hasDanmaku: hasDanmaku,
            ),
            videoPath: video.path,
            danmakuPath: hasDanmaku ? danmaku.path : null,
          ),
        );
      }
    }
    return shared;
  }

  String lanShareToken() {
    var token = GStorage.getSetting(SettingsKeys.lanShareToken);
    if (token.isEmpty) {
      token = generateLanShareToken();
      GStorage.putSetting<String>(SettingsKeys.lanShareToken, token);
    }
    return token;
  }

  Future<void> startLanShare() async {
    await _lanServer.start(lanShareToken());
    runInAction(() => lanShareRunning.value = true);
  }

  Future<void> stopLanShare() async {
    await _lanServer.stop();
    runInAction(() => lanShareRunning.value = false);
  }

  Future<void> pullFromLan(
    LanShareClient client,
    UpscaledEpisodeManifest manifest,
  ) async {
    if (isAlreadyDownloaded(manifest)) {
      await _downloadController.deleteEpisode(
        manifest.bangumiId,
        manifest.pluginName,
        manifest.episodeNumber,
      );
    }
    final (record, episode) = manifest.toDownloadEntities();
    final targetDir = await _downloadManager.episodeDirectoryFor(
      manifest.bangumiId,
      manifest.pluginName,
      manifest.episodeNumber,
    );
    await Directory(targetDir).create(recursive: true);
    if (manifest.hasDanmaku) {
      try {
        final bytes = await client.download(client.danmakuUri(manifest));
        await File(
          path.join(targetDir, upscaledDanmakuFileName),
        ).writeAsBytes(bytes, flush: true);
      } catch (e) {
        KazumiLogger().w('UpscaleController: danmaku pull skipped', error: e);
      }
    }
    episode
      ..downloadDirectory = targetDir
      ..networkM3u8Url = client.videoUri(manifest).toString();
    await _downloadController.enqueuePreUpscaled(record, episode);
  }

  Future<void> _saveEpisode(
    DownloadRecord record,
    DownloadEpisode episode,
  ) async {
    final existing = _repository.getRecord(record.key);
    final target = existing ?? record;
    target.episodes[episode.episodeNumber] = episode;
    await _repository.putRecord(target);
    _downloadController.syncRecord(record.key);
  }

  Future<void> _updateEpisode(
    String recordKey,
    int episodeNumber,
    void Function(DownloadEpisode episode) update,
  ) async {
    final record = _repository.getRecord(recordKey);
    final episode = record?.episodes[episodeNumber];
    if (record == null || episode == null) return;
    update(episode);
    await _repository.putRecord(record);
    _downloadController.syncRecord(recordKey);
  }

  static Future<void> _deleteIfExists(String dirPath) async {
    final dir = Directory(dirPath);
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
