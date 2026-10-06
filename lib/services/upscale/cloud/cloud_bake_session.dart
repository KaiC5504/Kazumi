import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/upscale/cloud/cloud_bake_estimate.dart';
import 'package:kazumi/services/upscale/cloud/cloud_bake_worker_client.dart';
import 'package:kazumi/services/upscale/cloud/runpod_api.dart';

enum CloudBakePhase { starting, running, finishing, done, stopped }

enum CloudEpisodeStage { uploading, waiting, baking, downloading }

class CloudEpisodePhase {
  const CloudEpisodePhase(this.stage, [this.progress = 0]);

  final CloudEpisodeStage stage;
  final double progress;
}

enum LocalBakeOutcome { done, failed, cancelled }

class CloudBakeException implements Exception {
  const CloudBakeException(this.message);

  final String message;

  @override
  String toString() => message;
}

class CloudJob {
  const CloudJob({
    required this.recordKey,
    required this.episodeNumber,
    required this.durationSec,
    required this.outputPath,
  });

  final String recordKey;
  final int episodeNumber;
  final int durationSec;

  /// Where the baked video ends up: `<episode>/upscaled/video.mp4`.
  final String outputPath;

  /// A session covers one show, so the episode number is unique on the pod.
  String get id => 'ep$episodeNumber';
}

class CloudBakeQuote {
  const CloudBakeQuote({
    required this.recordKey,
    required this.jobs,
    required this.offer,
    required this.estimate,
    required this.includeLocal,
    required this.height,
  });

  final String recordKey;
  final List<CloudJob> jobs;
  final CloudOffer offer;
  final CloudBakeEstimate estimate;
  final bool includeLocal;
  final int height;
}

class CloudBakeSessionView {
  const CloudBakeSessionView({
    required this.phase,
    required this.cloudDone,
    required this.localDone,
    required this.failed,
    required this.total,
    required this.startedAt,
    required this.pricePerHour,
    this.podStartedAt,
    this.podEndedAt,
    this.message,
  });

  final CloudBakePhase phase;
  final int cloudDone;
  final int localDone;
  final int failed;
  final int total;
  final DateTime startedAt;
  final DateTime? podStartedAt;
  final DateTime? podEndedAt;
  final double pricePerHour;
  final String? message;

  double costAt(DateTime now) {
    final start = podStartedAt;
    if (start == null) return 0;
    final end = podEndedAt ?? now;
    return end.difference(start).inSeconds / 3600 * pricePerHour;
  }

  String summary(DateTime now) {
    final minutes = now.difference(startedAt).inMinutes;
    final cost = '\$${costAt(now).toStringAsFixed(2)}';
    if (phase == CloudBakePhase.stopped) return '已停止云端烘焙 · 费用 $cost';
    final failedText = failed > 0 ? ' · $failed 集失败' : '';
    final note = message == null ? '' : ' · $message';
    return '云端烘焙完成 · ${cloudDone + localDone} 集 · $minutes 分钟 · '
        '$cost$failedText$note';
  }
}

String newCloudToken() {
  final random = Random.secure();
  return base64Url
      .encode([for (var i = 0; i < 32; i++) random.nextInt(256)])
      .replaceAll('=', '');
}

String _podName() {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final random = Random.secure();
  return cloudPodNamePrefix +
      String.fromCharCodes([
        for (var i = 0; i < 6; i++)
          chars.codeUnitAt(random.nextInt(chars.length)),
      ]);
}

/// One cloud bake of one show. The pod takes episodes from the front of the
/// list and the laptop from the back until nothing is left. Anything the pod
/// can't finish falls back to the laptop, and the pod is deleted as soon as
/// it has nothing left to do.
class CloudBakeSession {
  CloudBakeSession({
    required this.api,
    required this.connect,
    required this.recordKey,
    required List<CloudJob> jobs,
    required this.includeLocal,
    required this.workerScript,
    required this.capSec,
    required this.pricePerHour,
    required this.shader,
    required this.targetHeight,
    required this.prepareInput,
    required this.bakeLocally,
    required this.onCloudBaked,
    required this.onReturned,
    required this.onFailed,
    this.onPhase,
    this.onChanged,
    this.pollInterval = const Duration(seconds: 5),
    this.readyTimeout = const Duration(minutes: 5),
    this.lostAfter = const Duration(minutes: 10),
    this.deleteTimeout = const Duration(minutes: 2),
    this.stallAfter = const Duration(minutes: 10),
  }) : _pending = List.of(jobs),
       total = jobs.length,
       token = newCloudToken(),
       _startedAt = DateTime.now();

  static const maxHanded = 4;
  static const maxDownloads = 2;

  final CloudPodApi api;
  final CloudWorker Function(Uri base, String token) connect;
  final String recordKey;
  final bool includeLocal;
  final String workerScript;
  final int capSec;
  final double pricePerHour;
  final String shader;
  final int targetHeight;

  /// The file to upload, and whether it is a temporary to delete afterwards.
  final Future<(File, bool)> Function(CloudJob job) prepareInput;
  final Future<LocalBakeOutcome> Function(CloudJob job) bakeLocally;
  final Future<void> Function(CloudJob job) onCloudBaked;

  /// A stopped run gives these back unbaked.
  final Future<void> Function(CloudJob job) onReturned;
  final Future<void> Function(CloudJob job, String error) onFailed;
  final void Function(CloudJob job, CloudEpisodePhase? phase)? onPhase;
  final void Function(CloudBakeSessionView view)? onChanged;
  final Duration pollInterval;
  final Duration readyTimeout;
  final Duration lostAfter;
  final Duration deleteTimeout;

  /// A bake whose progress hasn't moved for this long is given up on.
  final Duration stallAfter;
  final int total;
  final String token;

  final List<CloudJob> _pending;
  final List<CloudJob> _fallback = [];
  final Map<String, CloudJob> _held = {};
  final Set<String> _downloading = {};
  final Set<String> _freshDownloads = {};
  final Set<String> _committed = {};
  final Map<String, (double, DateTime)> _lastProgress = {};
  CloudJob? _local;
  CloudWorker? _worker;
  String? _podId;
  Future<void>? _release;
  Completer<void> _signal = Completer<void>();
  final DateTime _startedAt;
  DateTime? _podStartedAt;
  DateTime? _podEndedAt;
  double? _podPrice;
  bool _stopped = false;
  bool _lost = false;
  bool _cloudOver = false;
  bool _uploadsOver = false;
  int _cloudDone = 0;
  int _localDone = 0;
  int _failed = 0;
  CloudBakePhase _phase = CloudBakePhase.starting;
  String? _message;

  CloudBakeSessionView get view => CloudBakeSessionView(
    phase: _phase,
    cloudDone: _cloudDone,
    localDone: _localDone,
    failed: _failed,
    total: total,
    startedAt: _startedAt,
    podStartedAt: _podStartedAt,
    podEndedAt: _podEndedAt,
    pricePerHour: _podPrice ?? pricePerHour,
    message: _message,
  );

  /// True while the session still owes this episode a bake.
  bool holds(int episodeNumber) =>
      _pending.any((j) => j.episodeNumber == episodeNumber) ||
      _fallback.any((j) => j.episodeNumber == episodeNumber) ||
      _held.values.any((j) => j.episodeNumber == episodeNumber) ||
      _local?.episodeNumber == episodeNumber;

  Future<void> run() async {
    _notify();
    final local = _localLane();
    await _cloudLane();
    _cloudOver = true;
    _wake();
    await local;
    _phase = _stopped ? CloudBakePhase.stopped : CloudBakePhase.done;
    _notify();
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _phase = CloudBakePhase.finishing;
    final unstarted = [..._pending, ..._fallback];
    _pending.clear();
    _fallback.clear();
    for (final job in unstarted) {
      await onReturned(job);
    }
    _wake();
    _notify();
    await _releasePod();
  }

  Future<void> _localLane() async {
    while (!_stopped) {
      final job = _nextLocal();
      if (job == null) {
        if (_cloudOver && _pending.isEmpty && _fallback.isEmpty) return;
        await _waitWake();
        continue;
      }
      _local = job;
      _notify();
      final outcome = await bakeLocally(job);
      _local = null;
      if (outcome == LocalBakeOutcome.done) _localDone++;
      if (outcome == LocalBakeOutcome.failed) _failed++;
      _notify();
      _wake();
    }
  }

  CloudJob? _nextLocal() {
    if (_fallback.isNotEmpty) return _fallback.removeAt(0);
    if ((includeLocal || _cloudOver) && _pending.isNotEmpty) {
      return _pending.removeLast();
    }
    return null;
  }

  Future<void> _cloudLane() async {
    try {
      final pod = await api.createPod(
        name: _podName(),
        diskGb: 50,
        env: {
          'KAZUMI_TOKEN': token,
          'KAZUMI_CAP_SEC': '$capSec',
          'KAZUMI_WORKER': workerScript,
        },
      );
      _podId = pod.id;
      _podStartedAt = DateTime.now();
      if (pod.costPerHour > 0) _podPrice = pod.costPerHour;
      _notify();
      if (_stopped) return;
      final worker = await _waitReady(pod.id);
      _worker = worker;
      for (var attempt = 1; ; attempt++) {
        try {
          await worker.putShader(shader);
          break;
        } on CloudWorkerException {
          if (attempt >= 3) rethrow;
          await Future.delayed(pollInterval);
        }
      }
      if (_stopped) return;
      _phase = CloudBakePhase.running;
      _notify();
      await Future.wait([_uploadLoop(worker), _pollLoop(worker)]);
    } catch (e) {
      if (!_stopped) {
        _message = e is RunpodException || e is CloudBakeException
            ? '$e'
            : '云端烘焙出错: $e';
        KazumiLogger().w('CloudBakeSession: cloud lane ended', error: e);
      }
    } finally {
      for (final job in _held.values.toList()) {
        _held.remove(job.id);
        onPhase?.call(job, null);
        if (_stopped) {
          await onReturned(job);
        } else {
          _fallback.add(job);
        }
      }
      if (!_stopped) _phase = CloudBakePhase.finishing;
      _wake();
      _notify();
      await _releasePod();
    }
  }

  Future<CloudWorker> _waitReady(String podId) async {
    final deadline = DateTime.now().add(readyTimeout);
    while (!_stopped) {
      CloudPodInfo? pod;
      try {
        pod = await api.getPod(podId);
      } on RunpodException catch (e) {
        KazumiLogger().w('CloudBakeSession: pod poll failed: $e');
      }
      final uri = pod?.workerUri;
      if (uri != null) {
        final worker = connect(uri, token);
        WorkerStatus? status;
        try {
          status = await worker.status();
        } on CloudWorkerException {
          // Still booting: the port is mapped before the worker listens.
        }
        if (status?.state == 'ready') return worker;
        if (status?.state == 'broken') {
          throw CloudBakeException('云端 GPU 环境异常: ${status!.error}');
        }
      }
      if (DateTime.now().isAfter(deadline)) {
        throw const CloudBakeException('云端 GPU 启动超时，改用本机烘焙');
      }
      await Future.delayed(pollInterval);
    }
    throw const CloudBakeException('已停止');
  }

  Future<void> _uploadLoop(CloudWorker worker) async {
    try {
      while (!_stopped && !_lost && _pending.isNotEmpty) {
        if (_held.length >= maxHanded) {
          await _waitWake();
          continue;
        }
        final job = _pending.removeAt(0);
        _held[job.id] = job;
        _setPhase(job, const CloudEpisodePhase(CloudEpisodeStage.uploading));
        (File, bool)? input;
        try {
          input = await prepareInput(job);
          final file = input.$1;
          final size = await file.length();
          await worker.upload(
            job.id,
            file,
            stopped: () => _stopped || _lost,
            onProgress: (sent) => _setPhase(
              job,
              CloudEpisodePhase(
                CloudEpisodeStage.uploading,
                size == 0 ? 0 : sent / size,
              ),
            ),
          );
          await worker.commit(
            job.id,
            size: size,
            durationSec: job.durationSec.toDouble(),
            height: targetHeight,
          );
          _committed.add(job.id);
          _setPhase(job, const CloudEpisodePhase(CloudEpisodeStage.waiting));
        } catch (e) {
          if (_stopped) return;
          KazumiLogger().w(
            'CloudBakeSession: upload of ${job.id} failed, laptop takes it',
            error: e,
          );
          _held.remove(job.id);
          _setPhase(job, null);
          _fallback.add(job);
        } finally {
          if (input != null && input.$2) {
            try {
              await input.$1.delete();
            } on FileSystemException {
              // Already gone.
            }
          }
          _wake();
        }
      }
    } finally {
      _uploadsOver = true;
      _wake();
    }
  }

  Future<void> _pollLoop(CloudWorker worker) async {
    var lastOk = DateTime.now();
    final downloads = <Future<void>>[];
    while (!_stopped) {
      if (_uploadsOver && _held.isEmpty) break;
      WorkerStatus? status;
      try {
        status = await worker.status();
        lastOk = DateTime.now();
      } catch (e) {
        // Anything short of the pod staying silent for [lostAfter] is retried.
        if (DateTime.now().difference(lastOk) > lostAfter) {
          KazumiLogger().w('CloudBakeSession: pod unreachable: $e');
          _lost = true;
          _message = '与云端 GPU 失去联系，剩余剧集改用本机烘焙';
          _wake();
          break;
        }
      }
      if (status != null) {
        for (final job in _held.values.toList()) {
          final episode = status.episodes[job.id];
          if (_downloading.contains(job.id)) continue;
          if (episode == null) {
            // Committed but unknown: the worker restarted or lost it.
            if (_committed.contains(job.id)) _toLaptop(job);
            continue;
          }
          if (episode.state == 'baking' && _stalled(job.id, episode.progress)) {
            KazumiLogger().w('CloudBakeSession: ${job.id} stalled on the pod');
            unawaited(worker.drop(job.id).then((_) {}, onError: (_) {}));
            _toLaptop(job);
            continue;
          }
          switch (episode.state) {
            case 'queued':
              _setPhase(
                job,
                const CloudEpisodePhase(CloudEpisodeStage.waiting),
              );
            case 'baking':
              _setPhase(
                job,
                CloudEpisodePhase(CloudEpisodeStage.baking, episode.progress),
              );
            case 'done':
              if (_downloading.length < maxDownloads) {
                downloads.add(_download(worker, job, episode.outBytes));
              }
            case 'failed':
              _held.remove(job.id);
              _setPhase(job, null);
              unawaited(worker.drop(job.id).then((_) {}, onError: (_) {}));
              if (includeLocal) {
                _fallback.add(job);
              } else {
                _failed++;
                await onFailed(job, '云端烘焙失败: ${episode.error}');
              }
              _wake();
          }
        }
      }
      await _waitWake();
    }
    await Future.wait(downloads);
  }

  void _toLaptop(CloudJob job) {
    _held.remove(job.id);
    _committed.remove(job.id);
    _lastProgress.remove(job.id);
    _setPhase(job, null);
    _fallback.add(job);
    _wake();
  }

  bool _stalled(String id, double progress) {
    final now = DateTime.now();
    final last = _lastProgress[id];
    if (last == null || last.$1 != progress) {
      _lastProgress[id] = (progress, now);
      return false;
    }
    return now.difference(last.$2) > stallAfter;
  }

  Future<void> _download(CloudWorker worker, CloudJob job, int bytes) async {
    _downloading.add(job.id);
    try {
      // A .part from an earlier run holds another encode's bytes; only
      // resume within this session.
      if (_freshDownloads.add(job.id)) {
        for (final suffix in const ['.part', '.parts']) {
          final stale = File('${job.outputPath}$suffix');
          if (await stale.exists()) await stale.delete();
        }
      }
      await worker.download(
        job.id,
        File(job.outputPath),
        expectedBytes: bytes,
        stopped: () => _stopped,
        onProgress: (n) => _setPhase(
          job,
          CloudEpisodePhase(
            CloudEpisodeStage.downloading,
            bytes == 0 ? 0 : n / bytes,
          ),
        ),
      );
    } catch (e) {
      if (!_stopped) {
        KazumiLogger().w(
          'CloudBakeSession: download of ${job.id} failed, will retry',
          error: e,
        );
      }
      _downloading.remove(job.id);
      return;
    }
    _held.remove(job.id);
    _downloading.remove(job.id);
    _setPhase(job, null);
    _cloudDone++;
    try {
      await worker.drop(job.id);
    } catch (e) {
      KazumiLogger().w('CloudBakeSession: drop of ${job.id} failed', error: e);
    }
    try {
      await onCloudBaked(job);
    } catch (e) {
      KazumiLogger().e(
        'CloudBakeSession: finishing ${job.id} failed',
        error: e,
      );
    }
    _notify();
    _wake();
  }

  Future<void> _releasePod() {
    final id = _podId;
    if (id == null) return Future.value();
    return _release ??= _deletePod(id);
  }

  Future<void> _deletePod(String id) async {
    final worker = _worker;
    if (worker != null && !_lost) {
      try {
        // The worker also deletes its own pod; belt and braces.
        await worker.shutdown().timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    final deadline = DateTime.now().add(deleteTimeout);
    while (true) {
      try {
        await api.deletePod(id);
        final pod = await api.getPod(id);
        if (pod == null || pod.gone) break;
      } catch (e) {
        KazumiLogger().w('CloudBakeSession: deleting pod $id failed', error: e);
      }
      if (DateTime.now().isAfter(deadline)) {
        _message = '无法确认云端 GPU 已删除，请到 Runpod 控制台检查';
        break;
      }
      await Future.delayed(pollInterval);
    }
    _podEndedAt = DateTime.now();
    _notify();
  }

  void _setPhase(CloudJob job, CloudEpisodePhase? phase) =>
      onPhase?.call(job, phase);

  void _notify() => onChanged?.call(view);

  void _wake() {
    final signal = _signal;
    _signal = Completer<void>();
    signal.complete();
  }

  Future<void> _waitWake() =>
      Future.any([_signal.future, Future.delayed(pollInterval)]);
}
