import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/pages/download/cloud_bake_report.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/services/download/parted_transfer.dart';
import 'package:kazumi/services/library/library_api.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/shaders/shader_asset_service.dart';
import 'package:kazumi/services/skip/aniskip_client.dart';
import 'package:kazumi/services/skip/episode_fingerprint.dart';
import 'package:kazumi/services/skip/skip_detector.dart';
import 'package:kazumi/services/skip/skip_segments.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/upscale/cloud/cloud_bake_estimate.dart';
import 'package:kazumi/services/upscale/cloud/cloud_bake_session.dart';
import 'package:kazumi/services/upscale/cloud/cloud_bake_worker_client.dart';
import 'package:kazumi/services/upscale/cloud/cloud_worker_script.dart';
import 'package:kazumi/services/upscale/cloud/runpod_api.dart';
import 'package:kazumi/services/upscale/keep_awake.dart';
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
  final ObservableMap<String, double> uploadProgress =
      ObservableMap<String, double>();
  final Observable<bool> lanShareRunning = Observable(false);

  FfmpegInfo? _ffmpeg;
  final List<(String, int)> _bakeQueue = [];
  bool _baking = false;
  UpscaleBaker? _activeBaker;
  String? _activeKey;
  (String, int)? _activeItem;
  final List<(String, int)> _uploadQueue = [];
  bool _uploading = false;
  Completer<void>? _uploadCancel;

  /// Progress key of the episode being uploaded; the rest of
  /// [uploadProgress] is waiting in the queue.
  final Observable<String?> activeUpload = Observable(null);

  /// Ids of the episodes the library server holds, from the last refresh.
  final ObservableSet<String> libraryIds = ObservableSet<String>();
  Future<void>? _libraryRefresh;
  Future<void> _skipAnalysis = Future.value();

  /// Record keys whose openings and endings are being analysed.
  final ObservableSet<String> analyzingSkips = ObservableSet<String>();

  // One local bake at a time: one already saturates the GPU, and both the
  // bake queue and a cloud session's laptop lane feed it.
  Future<void> _gpu = Future.value();

  CloudBakeSession? _cloud;
  final Observable<CloudBakeSessionView?> cloudSession = Observable(null);

  /// Keyed like [bakeProgress]; present while the cloud holds the episode.
  final ObservableMap<String, CloudEpisodePhase> cloudPhases =
      ObservableMap<String, CloudEpisodePhase>();

  bool get canBake => isDesktop();

  static String progressKey(String recordKey, int episodeNumber) =>
      '${recordKey}_$episodeNumber';

  Future<void> init() async {
    final adopted = <(String, int)>[];
    for (final record in _repository.getAllRecords()) {
      var changed = false;
      for (final episode in record.episodes.values) {
        if (adoptCloudBake(episode)) {
          adopted.add((record.key, episode.episodeNumber));
          changed = true;
          continue;
        }
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
    if (adopted.isNotEmpty) unawaited(_finishAdopted(adopted));
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

  /// Episodes baked off this machine (e.g. on a rented GPU) arrive as
  /// upscaled/video.mp4 plus a cloud_baked.json marker; treat them as if
  /// they had been baked here.
  @visibleForTesting
  static bool adoptCloudBake(DownloadEpisode episode) {
    if (episode.preUpscaled || episode.upscaleStatus == UpscaleStatus.done) {
      return false;
    }
    if (episode.downloadDirectory.isEmpty) return false;
    final dir = path.join(episode.downloadDirectory, 'upscaled');
    final marker = File(path.join(dir, cloudBakeMarkerFileName));
    final video = File(path.join(dir, upscaledVideoFileName));
    if (!marker.existsSync() || !video.existsSync()) return false;
    var height = 1440;
    try {
      final json =
          jsonDecode(marker.readAsStringSync()) as Map<String, dynamic>;
      height = (json['height'] as num?)?.toInt() ?? height;
    } catch (e) {
      KazumiLogger().w('UpscaleController: bad cloud bake marker', error: e);
    }
    episode
      ..upscaleStatus = UpscaleStatus.done
      ..upscaledVideoPath = video.path
      ..upscaledHeight = height;
    KazumiLogger().i('UpscaleController: adopted cloud bake ${video.path}');
    return true;
  }

  /// Runs the same follow-up a local bake gets: skip detection, then the
  /// auto export if it's on.
  Future<void> _finishAdopted(List<(String, int)> adopted) async {
    for (final recordKey in {for (final (key, _) in adopted) key}) {
      _downloadController.syncRecord(recordKey);
      try {
        await analyzeSkips(recordKey);
      } catch (e) {
        KazumiLogger().w('UpscaleController: skip analysis failed', error: e);
      }
    }
    if (!GStorage.getSetting(SettingsKeys.upscaleAutoExport) ||
        GStorage.getSetting(SettingsKeys.upscaleExportDirectory).isEmpty) {
      return;
    }
    for (final (recordKey, episodeNumber) in adopted) {
      final error = await export(recordKey, episodeNumber);
      if (error != null) {
        KazumiLogger().w('UpscaleController: auto export failed: $error');
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
    if (cloudHolds(recordKey, episodeNumber)) return '该集正在云端烘焙';
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

  bool get hasRunpodKey =>
      GStorage.getSetting(SettingsKeys.runpodApiKey).isNotEmpty;

  RunpodApi _runpod() =>
      RunpodApi(GStorage.getSetting(SettingsKeys.runpodApiKey));

  bool cloudHolds(String recordKey, int episodeNumber) =>
      _cloud?.holds(recordKey, episodeNumber) ?? false;

  /// Queued for the pod but not uploaded yet, so it can still be taken back.
  bool cloudQueued(String recordKey, int episodeNumber) =>
      _cloud?.queued(recordKey, episodeNumber) ?? false;

  bool get cloudRunning => _cloud != null;

  Future<FfmpegInfo> _requireCloud() async {
    if (!canBake) throw const CloudBakeException('仅支持在电脑端烘焙');
    if (!hasRunpodKey) {
      throw const CloudBakeException('请先在下载设置中填写 Runpod API Key');
    }
    final ffmpeg = _ffmpeg;
    if (ffmpeg != null) return ffmpeg;
    final (info, error) = await detectFfmpeg();
    if (info == null) throw CloudBakeException(error ?? '未找到可用的 ffmpeg');
    return info;
  }

  /// What a cloud bake of [recordKey] would take: every episode that still
  /// needs one, or only [episodeNumber]. A single episode may come out of
  /// the local queue, as long as the laptop hasn't started it.
  Future<List<CloudJob>> _cloudJobs(
    FfmpegInfo ffmpeg,
    String recordKey, {
    int? episodeNumber,
  }) async {
    final record = _repository.getRecord(recordKey);
    if (record == null) throw const CloudBakeException('找不到该番剧');
    final episodes =
        record.episodes.values
            .where(
              (e) =>
                  (episodeNumber == null || e.episodeNumber == episodeNumber) &&
                  e.status == DownloadStatus.completed &&
                  !e.preUpscaled &&
                  e.upscaleStatus != UpscaleStatus.done &&
                  (episodeNumber != null ||
                      !_bakeQueue.contains((recordKey, e.episodeNumber))) &&
                  _activeKey != progressKey(recordKey, e.episodeNumber) &&
                  !cloudHolds(recordKey, e.episodeNumber),
            )
            .toList()
          ..sort((a, b) => a.episodeNumber.compareTo(b.episodeNumber));
    if (episodes.isEmpty) {
      throw CloudBakeException(episodeNumber == null ? '没有可烘焙的剧集' : '该集无法上云烘焙');
    }
    return [
      for (final e in episodes)
        CloudJob(
          recordKey: recordKey,
          episodeNumber: e.episodeNumber,
          durationSec: await _durationSec(ffmpeg, e),
          outputPath: path.join(
            e.downloadDirectory,
            'upscaled',
            upscaledVideoFileName,
          ),
          cloudOnly: episodeNumber != null,
          bytes: _sourceBytes(e),
        ),
    ];
  }

  /// HLS downloads are remuxed before upload, which keeps their size.
  static int _sourceBytes(DownloadEpisode episode) {
    final input = episode.localM3u8Path;
    if (!input.toLowerCase().endsWith('.m3u8')) {
      try {
        return File(input).lengthSync();
      } on FileSystemException {
        return 0;
      }
    }
    return episode.totalBytes;
  }

  Future<int> _durationSec(FfmpegInfo ffmpeg, DownloadEpisode episode) async =>
      await UpscaleBaker.probeDurationUs(
        ffmpeg.executable,
        episode.localM3u8Path,
      ) ~/
      1000000;

  /// Bake time the laptop already owes: the rest of the episode on the GPU
  /// and everything queued behind it.
  Future<int> _localBusySec(FfmpegInfo ffmpeg) async {
    var media = 0.0;
    final active = _activeItem;
    for (final (recordKey, episodeNumber) in [?active, ..._bakeQueue]) {
      final episode = _repository.getRecord(recordKey)?.episodes[episodeNumber];
      if (episode == null) continue;
      var sec = (await _durationSec(ffmpeg, episode)).toDouble();
      if (sec <= 0) sec = CloudBakeRates.unknownDurationSec.toDouble();
      if ((recordKey, episodeNumber) == active) {
        sec *= 1 - (bakeProgress[progressKey(recordKey, episodeNumber)] ?? 0);
      }
      media += sec;
    }
    return (media / CloudBakeRates.localRealtime).ceil();
  }

  /// Prices a cloud bake of every episode of [recordKey] that still needs
  /// one, or only [episodeNumber], which then goes to the pod whatever the
  /// estimate says. Throws [CloudBakeException] or [RunpodException] with a
  /// message for the user.
  Future<CloudBakeQuote> quoteCloudBake(
    String recordKey, {
    int? episodeNumber,
  }) async {
    if (_cloud != null) throw const CloudBakeException('云端 GPU 正在收尾，请稍后再试');
    final ffmpeg = await _requireCloud();
    final jobs = await _cloudJobs(
      ffmpeg,
      recordKey,
      episodeNumber: episodeNumber,
    );
    final int height = GStorage.getSetting(SettingsKeys.upscaleBakeHeight);
    final bool includeLocal =
        episodeNumber == null &&
        GStorage.getSetting(SettingsKeys.cloudBakeIncludeLocal);
    final offer = await _runpod().sydneyOffer();
    return CloudBakeQuote(
      recordKey: recordKey,
      jobs: jobs,
      offer: offer,
      includeLocal: includeLocal,
      height: height,
      estimate: CloudBakeEstimate.forLoads(
        [for (final j in jobs) j.load],
        includeLocal: includeLocal,
        localBusySec: includeLocal ? await _localBusySec(ffmpeg) : 0,
      ),
    );
  }

  /// Adds to the running cloud session: one episode, or every episode of the
  /// show that still needs a bake. Returns how many were queued, or null
  /// when there is no session taking more and a new one has to be quoted.
  Future<int?> addToCloud(String recordKey, {int? episodeNumber}) async {
    final session = _cloud;
    if (session == null) return null;
    final ffmpeg = await _requireCloud();
    final probed = await _cloudJobs(
      ffmpeg,
      recordKey,
      episodeNumber: episodeNumber,
    );
    if (!identical(session, _cloud)) return null;
    final jobs = _notOnLaptop(probed);
    if (jobs.isEmpty) throw const CloudBakeException('该集已在本机烘焙');
    final added = session.add(jobs);
    if (!added) {
      throw const CloudBakeException('云端 GPU 正在收尾，请稍后再试');
    }
    await _takeFromLocalQueue(jobs);
    return jobs.length;
  }

  /// Takes a cloud-queued episode back before its upload starts.
  Future<void> removeFromCloud(String recordKey, int episodeNumber) async =>
      _cloud?.remove(recordKey, episodeNumber);

  /// Drops what the laptop started or finished while the caller awaited.
  List<CloudJob> _notOnLaptop(List<CloudJob> jobs) => [
    for (final job in jobs)
      if (_activeKey != progressKey(job.recordKey, job.episodeNumber) &&
          _repository
                  .getRecord(job.recordKey)
                  ?.episodes[job.episodeNumber]
                  ?.upscaleStatus !=
              UpscaleStatus.done)
        job,
  ];

  Future<void> _takeFromLocalQueue(List<CloudJob> jobs) async {
    // All out of the queue before the first await, or the laptop could
    // pick up a later one meanwhile.
    for (final job in jobs) {
      _bakeQueue.remove((job.recordKey, job.episodeNumber));
    }
    for (final job in jobs) {
      await _updateEpisode(job.recordKey, job.episodeNumber, (e) {
        e.upscaleStatus = UpscaleStatus.queued;
      });
    }
  }

  Future<void> startCloudBake(CloudBakeQuote quote) async {
    if (_cloud != null) throw const CloudBakeException('已有云端烘焙在进行');
    final ffmpeg = _ffmpeg;
    if (ffmpeg == null) throw const CloudBakeException('未找到可用的 ffmpeg');
    const script = packedCloudWorker;
    final shader = await File(
      await UpscaleBaker.buildCombinedShader(
        _shaderAssetService.shadersDirectory.path,
      ),
    ).readAsString();
    if (_cloud != null) throw const CloudBakeException('已有云端烘焙在进行');
    final jobs = _notOnLaptop(quote.jobs);
    if (jobs.isEmpty) throw const CloudBakeException('该集已在本机烘焙');

    final session = CloudBakeSession(
      api: _runpod(),
      connect: (uri, token) => CloudBakeWorkerClient(uri, token),
      jobs: jobs,
      includeLocal: quote.includeLocal,
      workerScript: script,
      capSec: quote.estimate.capSec,
      pricePerHour: quote.offer.pricePerHour,
      shader: shader,
      targetHeight: quote.height,
      prepareInput: (job) => _cloudInput(ffmpeg, job),
      bakeLocally: (job) =>
          _onGpu(() => _bakeOne(job.recordKey, job.episodeNumber)),
      onCloudBaked: (job) => _adoptCloudOutput(job, quote.height),
      onReturned: (job) =>
          _updateEpisode(job.recordKey, job.episodeNumber, (e) {
            e.upscaleStatus = UpscaleStatus.none;
          }),
      onFailed: (job, error) =>
          _updateEpisode(job.recordKey, job.episodeNumber, (e) {
            e.upscaleStatus = UpscaleStatus.failed;
            e.errorMessage = error;
          }),
      onPhase: (job, phase) => runInAction(() {
        final key = progressKey(job.recordKey, job.episodeNumber);
        if (phase == null) {
          cloudPhases.remove(key);
        } else {
          cloudPhases[key] = phase;
        }
      }),
      onChanged: (view) => runInAction(() => cloudSession.value = view),
    );
    _cloud = session;
    await _takeFromLocalQueue(jobs);
    KeepAwake.instance.acquire();
    unawaited(() async {
      try {
        await session.run();
      } catch (e) {
        KazumiLogger().e('UpscaleController: cloud bake failed', error: e);
      } finally {
        KeepAwake.instance.release();
        _cloud = null;
        KazumiLogger().i(
          'UpscaleController: ${session.view.summary(DateTime.now())}',
        );
        runInAction(() {
          cloudSession.value = null;
          cloudPhases.clear();
        });
        // run() only returns once every baked episode has been downloaded
        // and adopted, and the pod is deleted, so this never shows early.
        final report = session.report;
        if (report.stopped || report.episodes.isEmpty) {
          KazumiDialog.showToast(
            message: session.view.summary(DateTime.now()),
            duration: const Duration(seconds: 6),
          );
        } else {
          unawaited(showCloudBakeReport(report, titleOf: _cloudTitle));
        }
      }
    }());
  }

  Future<void> stopCloudBake() async => _cloud?.stop();

  (String, String) _cloudTitle(CloudJob job) {
    final record = _repository.getRecord(job.recordKey);
    final name = record?.episodes[job.episodeNumber]?.episodeName ?? '';
    return (
      record?.bangumiName ?? '',
      name.isNotEmpty ? name : '第 ${job.episodeNumber} 集',
    );
  }

  /// The pod needs one file; HLS downloads (playlist plus segments) are
  /// remuxed into one without re-encoding.
  Future<(File, bool)> _cloudInput(FfmpegInfo ffmpeg, CloudJob job) async {
    final episode = _repository
        .getRecord(job.recordKey)
        ?.episodes[job.episodeNumber];
    if (episode == null) throw const CloudBakeException('剧集已被删除');
    final input = episode.localM3u8Path;
    if (!input.toLowerCase().endsWith('.m3u8')) return (File(input), false);
    final output = path.join(
      episode.downloadDirectory,
      'upscaled',
      'cloud_input.mkv',
    );
    await Directory(path.dirname(output)).create(recursive: true);
    final result = await Process.run(
      ffmpeg.executable,
      cloudRemuxArgs(input, output),
    );
    if (result.exitCode != 0) {
      final lines = (result.stderr as String).trim().split('\n');
      throw CloudBakeException('整理视频失败: ${lines.last}');
    }
    return (File(output), true);
  }

  @visibleForTesting
  static List<String> cloudRemuxArgs(String input, String output) => [
    '-hide_banner',
    '-y',
    '-loglevel',
    'error',
    '-allowed_extensions',
    'ALL',
    '-protocol_whitelist',
    'file,crypto,data',
    '-i',
    input,
    '-map',
    '0:v:0',
    '-map',
    '0:a:0?',
    '-c',
    'copy',
    output,
  ];

  Future<void> _adoptCloudOutput(CloudJob job, int height) async {
    // The marker lets init() adopt the file if the app dies before the
    // record is updated.
    await File(
      path.join(path.dirname(job.outputPath), cloudBakeMarkerFileName),
    ).writeAsString(jsonEncode({'height': height, 'source': 'runpod-l40s'}));
    await _finishBake(job.recordKey, job.episodeNumber, job.outputPath, height);
  }

  /// Cloud bake pods still running with no session in this app, e.g. after
  /// the app was killed mid-run.
  Future<List<CloudPodInfo>> leftoverCloudPods() async {
    if (!canBake || !hasRunpodKey || _cloud != null) return const [];
    return leftoverPods(await _runpod().listPods());
  }

  @visibleForTesting
  static List<CloudPodInfo> leftoverPods(List<CloudPodInfo> pods) => [
    for (final pod in pods)
      if (pod.name.startsWith(cloudPodNamePrefix) && !pod.gone) pod,
  ];

  Future<void> deleteCloudPod(String id) => _runpod().deletePod(id);

  Future<void> _pumpBakeQueue() async {
    if (_baking) return;
    _baking = true;
    KeepAwake.instance.acquire();
    try {
      await drainOnGpu(
        _bakeQueue,
        _onGpu,
        (item) => _bakeOne(item.$1, item.$2),
      );
    } finally {
      _baking = false;
      KeepAwake.instance.release();
    }
  }

  @visibleForTesting
  static Future<void> drainOnGpu<T>(
    List<T> queue,
    Future<void> Function(Future<void> Function() bake) onGpu,
    Future<void> Function(T item) bake,
  ) async {
    // Dequeue only once the GPU is free: while waiting, the episode must
    // still look queued so it can be cancelled and isn't queued twice.
    while (queue.isNotEmpty) {
      await onGpu(() async {
        if (queue.isEmpty) return;
        await bake(queue.removeAt(0));
      });
    }
  }

  Future<T> _onGpu<T>(Future<T> Function() bake) {
    final run = _gpu.then((_) => bake());
    _gpu = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<LocalBakeOutcome> _bakeOne(String recordKey, int episodeNumber) async {
    final record = _repository.getRecord(recordKey);
    final episode = record?.episodes[episodeNumber];
    final ffmpeg = _ffmpeg;
    if (record == null || episode == null || ffmpeg == null) {
      return LocalBakeOutcome.failed;
    }

    final key = progressKey(recordKey, episodeNumber);
    final baker = UpscaleBaker();
    _activeKey = key;
    _activeItem = (recordKey, episodeNumber);
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
      await _finishBake(recordKey, episodeNumber, output, targetHeight);
      return LocalBakeOutcome.done;
    } on UpscaleBakeCancelled {
      await _updateEpisode(recordKey, episodeNumber, (e) {
        e.upscaleStatus = UpscaleStatus.none;
      });
      return LocalBakeOutcome.cancelled;
    } catch (e) {
      KazumiLogger().e('UpscaleController: bake failed for $key', error: e);
      await _updateEpisode(recordKey, episodeNumber, (ep) {
        ep.upscaleStatus = UpscaleStatus.failed;
        ep.errorMessage = '超分失败: $e';
      });
      return LocalBakeOutcome.failed;
    } finally {
      runInAction(() => bakeProgress.remove(key));
      _activeKey = null;
      _activeItem = null;
      _activeBaker = null;
    }
  }

  Future<void> _finishBake(
    String recordKey,
    int episodeNumber,
    String output,
    int height,
  ) async {
    await _updateEpisode(recordKey, episodeNumber, (e) {
      e.upscaleStatus = UpscaleStatus.done;
      e.upscaledVideoPath = output;
      e.upscaledHeight = height;
    });
    try {
      await analyzeSkips(recordKey);
    } catch (e) {
      KazumiLogger().w('UpscaleController: skip analysis failed', error: e);
    }
    if (GStorage.getSetting(SettingsKeys.libraryAutoUpload) &&
        canUploadToLibrary) {
      enqueueUpload(recordKey, episodeNumber);
    }
    if (GStorage.getSetting(SettingsKeys.upscaleAutoExport) &&
        GStorage.getSetting(SettingsKeys.upscaleExportDirectory).isNotEmpty) {
      final error = await export(recordKey, episodeNumber);
      if (error != null) {
        KazumiLogger().w('UpscaleController: auto export failed: $error');
      }
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

  /// Fingerprints the record's episodes that don't have one yet, then
  /// re-detects openings and endings across all of them, since a new episode
  /// gives the earlier ones something to match against. Returns how many
  /// episodes changed, or null when ffmpeg can't fingerprint.
  Future<int?> analyzeSkips(String recordKey) {
    final run = _skipAnalysis.then((_) => _analyzeSkips(recordKey));
    _skipAnalysis = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<int?> _analyzeSkips(String recordKey) async {
    var ffmpeg = _ffmpeg;
    if (ffmpeg == null) {
      (ffmpeg, _) = await detectFfmpeg();
    }
    if (ffmpeg == null || !ffmpeg.chromaprint) {
      KazumiLogger().w(
        'UpscaleController: ffmpeg lacks chromaprint, skip detection off',
      );
      return null;
    }
    final record = _repository.getRecord(recordKey);
    if (record == null) return 0;

    runInAction(() => analyzingSkips.add(recordKey));
    try {
      final prints = <int, EpisodeFingerprint>{};
      for (final episode in record.episodes.values) {
        final source = _fingerprintSource(episode);
        if (source == null) continue;
        var fingerprint = await EpisodeFingerprint.load(
          episode.downloadDirectory,
        );
        if (fingerprint == null) {
          try {
            fingerprint = await EpisodeFingerprint.compute(ffmpeg, source);
            await fingerprint.save(episode.downloadDirectory);
          } catch (e) {
            KazumiLogger().w(
              'UpscaleController: fingerprint failed for '
              '$recordKey ep${episode.episodeNumber}',
              error: e,
            );
            continue;
          }
        }
        prints[episode.episodeNumber] = fingerprint;
      }

      final detected = await detectSkipSegmentsInBackground(prints);
      final useAniSkip = GStorage.getSetting(SettingsKeys.aniSkipLookup);
      var changed = 0;
      for (final episodeNumber in prints.keys) {
        var segments = detected[episodeNumber] ?? SkipSegments.empty;
        if (useAniSkip &&
            (segments.opening == null || segments.ending == null)) {
          final fallback = await AniSkipClient.instance.lookup(
            record.bangumiId,
            episodeNumber,
            prints[episodeNumber]!.duration,
          );
          segments = SkipSegments(
            opening: segments.opening ?? fallback.opening,
            ending: segments.ending ?? fallback.ending,
          );
        }
        KazumiLogger().i(
          'UpscaleController: $recordKey ep$episodeNumber $segments',
        );
        final encoded = segments.encode();
        final current = _repository.getRecord(recordKey);
        if (current?.episodes[episodeNumber]?.skipSegments == encoded) {
          continue;
        }
        await _updateEpisode(recordKey, episodeNumber, (e) {
          e.skipSegments = encoded;
        });
        await _refreshExportedManifest(recordKey, episodeNumber);
        changed++;
      }
      return changed;
    } finally {
      runInAction(() => analyzingSkips.remove(recordKey));
    }
  }

  String? _fingerprintSource(DownloadEpisode episode) {
    if (episode.upscaleStatus == UpscaleStatus.done &&
        File(episode.upscaledVideoPath).existsSync()) {
      return episode.upscaledVideoPath;
    }
    if (episode.status == DownloadStatus.completed &&
        episode.localM3u8Path.isNotEmpty &&
        File(episode.localM3u8Path).existsSync()) {
      return episode.localM3u8Path;
    }
    return null;
  }

  /// An already exported episode only needs its manifest rewritten for the
  /// importing device to pick up new skip times; the video stays put.
  Future<void> _refreshExportedManifest(
    String recordKey,
    int episodeNumber,
  ) async {
    final exportRoot = GStorage.getSetting(SettingsKeys.upscaleExportDirectory);
    final record = _repository.getRecord(recordKey);
    final episode = record?.episodes[episodeNumber];
    if (exportRoot.isEmpty || record == null || episode == null) return;
    final probe = UpscaledEpisodeManifest.fromEpisode(
      record,
      episode,
      width: 0,
      height: 0,
      sizeBytes: 0,
      hasDanmaku: false,
    );
    final file = File(
      path.join(
        exportRoot,
        upscaledExportFolderName,
        upscaledExportDirName(probe),
        upscaledManifestFileName,
      ),
    );
    if (!await file.exists()) return;
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (probe.skipSegments.isEmpty) {
        json.remove('skip');
      } else {
        json['skip'] = probe.skipSegments.toJson();
      }
      final partial = File('${file.path}.part');
      await partial.writeAsString(
        const JsonEncoder.withIndent('  ').convert(json),
        flush: true,
      );
      await partial.rename(file.path);
    } catch (e) {
      KazumiLogger().w(
        'UpscaleController: manifest refresh failed for $recordKey '
        'ep$episodeNumber',
        error: e,
      );
    }
  }

  /// The device already has this exact video; only the skip times differ.
  bool onlySkipTimesChanged(UpscaledEpisodeManifest manifest) =>
      _sameVideoAlreadyImported(manifest) &&
      _importedSkipSegments(manifest) != manifest.skipSegments.encode();

  bool isUpToDate(UpscaledEpisodeManifest manifest) =>
      _sameVideoAlreadyImported(manifest) &&
      _importedSkipSegments(manifest) == manifest.skipSegments.encode();

  bool _sameVideoAlreadyImported(UpscaledEpisodeManifest manifest) {
    final episode = _repository
        .getRecord(manifest.recordKey)
        ?.episodes[manifest.episodeNumber];
    if (episode == null ||
        !episode.preUpscaled ||
        episode.status != DownloadStatus.completed) {
      return false;
    }
    final localPath = _downloadController.getLocalVideoPath(
      manifest.bangumiId,
      manifest.pluginName,
      manifest.episodeNumber,
    );
    if (localPath == null) return false;
    final file = File(localPath);
    return file.existsSync() && file.lengthSync() == manifest.sizeBytes;
  }

  String? _importedSkipSegments(UpscaledEpisodeManifest manifest) => _repository
      .getRecord(manifest.recordKey)
      ?.episodes[manifest.episodeNumber]
      ?.skipSegments;

  Future<void> _updateSkipTimes(UpscaledEpisodeManifest manifest) =>
      _updateEpisode(manifest.recordKey, manifest.episodeNumber, (e) {
        e.skipSegments = manifest.skipSegments.encode();
      });

  bool get canUploadToLibrary =>
      GStorage.getSetting(SettingsKeys.libraryServer).isNotEmpty &&
      GStorage.getSetting(SettingsKeys.libraryAdminKey).isNotEmpty;

  /// Returns an error message, or null once the episode is queued.
  String? enqueueUpload(String recordKey, int episodeNumber) {
    if (!canUploadToLibrary) return '请先在下载设置中填写片库服务器和上传密钥';
    final episode = _repository.getRecord(recordKey)?.episodes[episodeNumber];
    if (episode == null || episode.upscaleStatus != UpscaleStatus.done) {
      return '该集尚未完成超分';
    }
    final key = progressKey(recordKey, episodeNumber);
    if (uploadProgress.containsKey(key)) return null;
    _uploadQueue.add((recordKey, episodeNumber));
    runInAction(() => uploadProgress[key] = 0);
    unawaited(_pumpUploadQueue());
    return null;
  }

  void cancelUpload(String recordKey, int episodeNumber) {
    final key = progressKey(recordKey, episodeNumber);
    if (activeUpload.value == key) {
      final cancel = _uploadCancel;
      if (cancel != null && !cancel.isCompleted) cancel.complete();
      return;
    }
    _uploadQueue.remove((recordKey, episodeNumber));
    runInAction(() => uploadProgress.remove(key));
  }

  bool isInLibrary(String recordKey, int episodeNumber) => libraryIds.contains(
    UpscaledEpisodeManifest.shareIdFor(recordKey, episodeNumber),
  );

  /// Reloads [libraryIds]. A failed refresh keeps the last known list.
  Future<void> refreshLibrary() {
    if (!canUploadToLibrary) return Future.value();
    return _libraryRefresh ??= () async {
      try {
        final api = LibraryApi(
          GStorage.getSetting(SettingsKeys.libraryServer),
          GStorage.getSetting(SettingsKeys.libraryAdminKey),
        );
        final ids = [for (final e in await api.episodes()) e.id];
        runInAction(() {
          libraryIds
            ..clear()
            ..addAll(ids);
        });
      } catch (e) {
        KazumiLogger().w('UpscaleController: library refresh failed', error: e);
      } finally {
        _libraryRefresh = null;
      }
    }();
  }

  Future<void> _pumpUploadQueue() async {
    if (_uploading) return;
    _uploading = true;
    KeepAwake.instance.acquire();
    try {
      while (_uploadQueue.isNotEmpty) {
        final (recordKey, episodeNumber) = _uploadQueue.removeAt(0);
        final key = progressKey(recordKey, episodeNumber);
        final cancel = Completer<void>();
        _uploadCancel = cancel;
        runInAction(() => activeUpload.value = key);
        try {
          await _uploadOne(recordKey, episodeNumber, key, cancel);
          KazumiDialog.showToast(message: '已上传到片库');
          unawaited(refreshLibrary());
        } on UploadCancelled {
          KazumiDialog.showToast(message: '已取消上传');
        } catch (e) {
          KazumiLogger().e(
            'UpscaleController: upload failed for $key',
            error: e,
          );
          KazumiDialog.showToast(message: '上传到片库失败: $e');
        } finally {
          _uploadCancel = null;
          runInAction(() {
            activeUpload.value = null;
            uploadProgress.remove(key);
          });
        }
      }
    } finally {
      _uploading = false;
      KeepAwake.instance.release();
    }
  }

  Future<void> _uploadOne(
    String recordKey,
    int episodeNumber,
    String key,
    Completer<void> cancel,
  ) async {
    final record = _repository.getRecord(recordKey);
    final episode = record?.episodes[episodeNumber];
    if (record == null || episode == null) return;
    final api = LibraryApi(
      GStorage.getSetting(SettingsKeys.libraryServer),
      GStorage.getSetting(SettingsKeys.libraryAdminKey),
    );
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
    final id = manifest.shareId;

    await uploadInParts(
      api,
      id,
      upscaledVideoFileName,
      video,
      cancel: cancel,
      onProgress: (sent) =>
          runInAction(() => uploadProgress[key] = sent / size),
    );
    if (hasDanmaku) {
      await _uploadResumable(
        api,
        id,
        upscaledDanmakuFileName,
        danmaku,
        cancel: cancel,
      );
    }
    if (cancel.isCompleted) throw const UploadCancelled();
    await api.commit(id, manifest);
  }

  /// Sends the video as parts over several connections (see
  /// parted_transfer); parts already on the server are skipped.
  @visibleForTesting
  static Future<void> uploadInParts(
    LibraryApi api,
    String id,
    String file,
    File source, {
    void Function(int sent)? onProgress,
    Completer<void>? cancel,
    int partSize = transferPartSize,
  }) async {
    final done = await api.uploadedParts(id, file);
    if (done == null) {
      return _uploadResumable(
        api,
        id,
        file,
        source,
        onProgress: onProgress,
        cancel: cancel,
      );
    }
    final size = await source.length();
    int lengthOf(int i) => partLength(i, size, partSize);

    final pending = <int>[];
    var sent = 0;
    for (var i = 0; i < partCount(size, partSize); i++) {
      if (done[i] == lengthOf(i)) {
        sent += lengthOf(i);
      } else {
        pending.add(i);
      }
    }
    final inFlight = <int, int>{};
    void report() => onProgress?.call(
      sent + inFlight.values.fold<int>(0, (sum, n) => sum + n),
    );
    report();

    await runParts(
      pending: pending,
      attempts: 8,
      stopped: () => cancel?.isCompleted ?? false,
      onRetry: (index, e) =>
          KazumiLogger().w('UpscaleController: part $index retry: $e'),
      transfer: (index) async {
        try {
          await api.uploadPart(
            id,
            file,
            source,
            index: index,
            start: index * partSize,
            end: index * partSize + lengthOf(index),
            cancelled: cancel?.future,
            onProgress: (n) {
              inFlight[index] = n;
              report();
            },
          );
        } finally {
          inFlight.remove(index);
        }
        sent += lengthOf(index);
        report();
      },
    );
    if (cancel?.isCompleted ?? false) throw const UploadCancelled();
  }

  /// Home upload links drop long transfers, so each attempt resumes from
  /// whatever the server already holds.
  static Future<void> _uploadResumable(
    LibraryApi api,
    String id,
    String file,
    File source, {
    void Function(int sent)? onProgress,
    Completer<void>? cancel,
  }) async {
    final size = await source.length();
    var attempt = 0;
    while (true) {
      if (cancel?.isCompleted ?? false) throw const UploadCancelled();
      final offset = await api.uploadedSize(id, file);
      if (offset == size) return;
      if (offset > size) {
        throw LibraryException('服务器上的 $file 比本地大，请在服务器上删除后重试');
      }
      try {
        await api.upload(
          id,
          file,
          source,
          offset: offset,
          onProgress: onProgress,
          cancelled: cancel?.future,
        );
        return;
      } on LibraryException catch (e) {
        if (cancel?.isCompleted ?? false) throw const UploadCancelled();
        if (++attempt >= 8) rethrow;
        KazumiLogger().w('UpscaleController: upload retry $attempt: $e');
        await Future.delayed(Duration(seconds: 2 * attempt));
      }
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
    if (onlySkipTimesChanged(manifest)) {
      await _updateSkipTimes(manifest);
      onProgress?.call(1);
      return;
    }
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
    if (onlySkipTimesChanged(manifest)) {
      await _updateSkipTimes(manifest);
      return;
    }
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

class UploadCancelled implements Exception {
  const UploadCancelled();
}
