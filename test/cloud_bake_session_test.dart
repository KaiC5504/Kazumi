import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/upscale/cloud/cloud_bake_estimate.dart';
import 'package:kazumi/services/upscale/cloud/cloud_bake_session.dart';
import 'package:kazumi/services/upscale/cloud/cloud_bake_worker_client.dart';
import 'package:kazumi/services/upscale/cloud/runpod_api.dart';
import 'package:path/path.dart' as path;

class FakePodApi implements CloudPodApi {
  FakePodApi({this.readyAfterPolls = 0, this.createError});

  final int readyAfterPolls;
  final Object? createError;
  final created = <Map<String, String>>[];
  final names = <String>[];
  final deleted = <String>[];
  var exists = false;
  var polls = 0;
  var inStock = true;
  var offerChecks = 0;
  void Function()? onOffer;

  @override
  Future<CloudOffer> sydneyOffer() async {
    offerChecks++;
    onOffer?.call();
    return CloudOffer(available: inStock, pricePerHour: 1.09);
  }

  @override
  Future<CloudPodInfo> createPod({
    required String name,
    required Map<String, String> env,
    required int diskGb,
  }) async {
    if (createError != null) throw createError!;
    if (!inStock) {
      throw const RunpodException('悉尼暂无可用 GPU', noCapacity: true);
    }
    exists = true;
    created.add(env);
    names.add(name);
    return CloudPodInfo(
      id: 'pod1',
      name: name,
      status: 'PROVISIONING',
      costPerHour: 1.09,
    );
  }

  @override
  Future<CloudPodInfo?> getPod(String id) async {
    if (!exists) return null;
    polls++;
    return CloudPodInfo(
      id: id,
      name: 'kazumi-bake-x',
      status: 'RUNNING',
      costPerHour: 1.09,
      workerUri: polls > readyAfterPolls ? Uri.parse('http://pod:1') : null,
    );
  }

  @override
  Future<void> deletePod(String id) async {
    deleted.add(id);
    exists = false;
  }

  @override
  Future<List<CloudPodInfo>> listPods() async => [];
}

class FakeWorker implements CloudWorker {
  final episodes = <String, WorkerEpisode>{};
  final failIds = <String>{};
  final uploadFailIds = <String>{};
  final uploadFailOnce = <String>{};
  final vanishIds = <String>{};
  var shaderFailures = 0;
  var garbledStatusCall = -1;
  final shaders = <String>[];
  final drops = <String>[];
  var bakeForever = false;
  var goDarkAfterStatus = 1 << 30;
  var statusCalls = 0;
  var shutdowns = 0;
  int? uptimeSec;
  int? podCapSec;

  @override
  Future<WorkerStatus> status() async {
    if (++statusCalls > goDarkAfterStatus) {
      throw const CloudWorkerException('down');
    }
    if (statusCalls == garbledStatusCall) {
      throw const FormatException('Unexpected end of input');
    }
    return WorkerStatus(
      state: 'ready',
      episodes: Map.of(episodes),
      uptimeSec: uptimeSec,
      capSec: podCapSec,
    );
  }

  @override
  Future<void> putShader(String glsl) async {
    if (shaderFailures-- > 0) throw const CloudWorkerException('blip');
    shaders.add(glsl);
  }

  @override
  Future<void> upload(
    String id,
    File source, {
    void Function(int sent)? onProgress,
    bool Function()? stopped,
  }) async {
    if (uploadFailIds.contains(id) || uploadFailOnce.remove(id)) {
      throw const CloudWorkerException('upload broke');
    }
    onProgress?.call(await source.length());
  }

  @override
  Future<void> commit(
    String id, {
    required int size,
    required double durationSec,
    required int height,
  }) async {
    if (vanishIds.contains(id)) return;
    episodes[id] = failIds.contains(id)
        ? const WorkerEpisode(
            state: 'failed',
            progress: 0,
            outBytes: 0,
            error: 'boom',
          )
        : bakeForever
        ? const WorkerEpisode(state: 'baking', progress: 0.5, outBytes: 0)
        : const WorkerEpisode(state: 'done', progress: 1, outBytes: 3);
  }

  @override
  Future<void> download(
    String id,
    File target, {
    required int expectedBytes,
    void Function(int received)? onProgress,
    bool Function()? stopped,
  }) async {
    await target.parent.create(recursive: true);
    await target.writeAsBytes([1, 2, 3]);
  }

  @override
  Future<void> drop(String id) async {
    drops.add(id);
    episodes.remove(id);
  }

  @override
  Future<void> shutdown() async => shutdowns++;

  final caps = <int>[];

  @override
  Future<void> extendCap(int capSec) async => caps.add(capSec);
}

void main() {
  late Directory dir;
  late List<int> cloudBaked, localBaked, returned, failed;
  late Map<int, CloudEpisodeStage?> stages;
  late List<String> errors;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cloud_session_');
    cloudBaked = [];
    localBaked = [];
    returned = [];
    failed = [];
    stages = {};
    errors = [];
  });
  tearDown(() => dir.deleteSync(recursive: true));

  CloudJob job(
    int n, {
    bool cloudOnly = false,
    String recordKey = 'r',
    int durationSec = 1440,
  }) => CloudJob(
    recordKey: recordKey,
    episodeNumber: n,
    durationSec: durationSec,
    outputPath: path.join(dir.path, '$recordKey$n', 'upscaled', 'video.mp4'),
    cloudOnly: cloudOnly,
  );

  CloudBakeSession make(
    FakePodApi api,
    FakeWorker worker, {
    required bool includeLocal,
    int count = 4,
    Duration localTime = Duration.zero,
    Duration readyTimeout = const Duration(seconds: 2),
    Duration stallAfter = const Duration(minutes: 10),
    bool cloudOnly = false,
  }) {
    return CloudBakeSession(
      api: api,
      connect: (uri, token) => worker,
      jobs: [for (var i = 1; i <= count; i++) job(i, cloudOnly: cloudOnly)],
      includeLocal: includeLocal,
      workerScript: 'packed',
      capSec: 1800,
      pricePerHour: 1.09,
      shader: '//!HOOK MAIN',
      targetHeight: 1440,
      prepareInput: (job) async {
        final f = File(path.join(dir.path, 'in_${job.episodeNumber}'));
        await f.writeAsBytes([0]);
        return (f, true);
      },
      bakeLocally: (job) async {
        await Future.delayed(localTime);
        localBaked.add(job.episodeNumber);
        return LocalBakeOutcome.done;
      },
      onCloudBaked: (job) async => cloudBaked.add(job.episodeNumber),
      onReturned: (job) async => returned.add(job.episodeNumber),
      onFailed: (job, error) async {
        failed.add(job.episodeNumber);
        errors.add(error);
      },
      onPhase: (job, phase) => stages[job.episodeNumber] = phase?.stage,
      pollInterval: const Duration(milliseconds: 1),
      offerInterval: const Duration(milliseconds: 2),
      readyTimeout: readyTimeout,
      lostAfter: const Duration(milliseconds: 30),
      deleteTimeout: const Duration(milliseconds: 50),
      stallAfter: stallAfter,
    );
  }

  String id(int n) => CloudJob.idFor('r', n);

  Future<void> until(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) throw StateError('timed out');
      await Future.delayed(const Duration(milliseconds: 1));
    }
  }

  Future<void> runIt(CloudBakeSession s) =>
      s.run().timeout(const Duration(seconds: 10));

  test(
    'cloud only: every episode goes to the pod, which is deleted after',
    () async {
      final api = FakePodApi();
      final worker = FakeWorker();
      final s = make(api, worker, includeLocal: false);
      expect(s.holds('r', 1), isTrue);
      await runIt(s);
      expect(cloudBaked..sort(), [1, 2, 3, 4]);
      expect(localBaked, isEmpty);
      expect(api.deleted, ['pod1']);
      expect(worker.shutdowns, 1);
      expect(worker.shaders, ['//!HOOK MAIN']);
      expect(api.names.single, startsWith('kazumi-bake-'));
      expect(
        api.created.single['KAZUMI_TOKEN']!.length,
        greaterThanOrEqualTo(32),
      );
      expect(
        int.parse(api.created.single['KAZUMI_CAP_SEC']!),
        greaterThanOrEqualTo(1800),
      );
      expect(api.created.single['KAZUMI_WORKER'], 'packed');
      expect(s.view.phase, CloudBakePhase.done);
      expect(s.holds('r', 1), isFalse);
    },
  );

  test('the laptop takes from the back', () async {
    final s = make(
      FakePodApi(),
      FakeWorker(),
      includeLocal: true,
      localTime: const Duration(milliseconds: 40),
    );
    await runIt(s);
    expect(localBaked.first, 4);
    expect(cloudBaked, contains(1));
    expect({...localBaked, ...cloudBaked}, {1, 2, 3, 4});
    expect(localBaked.length + cloudBaked.length, 4);
  });

  test('a pod-side failure goes to the laptop when it is on', () async {
    final worker = FakeWorker()..failIds.add(id(2));
    final s = make(
      FakePodApi(),
      worker,
      includeLocal: true,
      localTime: const Duration(milliseconds: 40),
    );
    await runIt(s);
    expect(localBaked, contains(2));
    expect(cloudBaked, isNot(contains(2)));
    expect(failed, isEmpty);
  });

  test(
    'without the laptop a pod-side failure marks the episode failed',
    () async {
      final worker = FakeWorker()..failIds.add(id(2));
      await runIt(make(FakePodApi(), worker, includeLocal: false));
      expect(failed, [2]);
      expect(cloudBaked..sort(), [1, 3, 4]);
      expect(localBaked, isEmpty);
    },
  );

  test('a failed upload is retried, then marked failed, never local', () async {
    final worker = FakeWorker()..uploadFailIds.add(id(1));
    await runIt(make(FakePodApi(), worker, includeLocal: false));
    expect(localBaked, isEmpty);
    expect(failed, [1]);
    expect(cloudBaked..sort(), [2, 3, 4]);
  });

  test('a failed upload that works the second time stays on the pod', () async {
    final worker = FakeWorker()..uploadFailOnce.add(id(1));
    await runIt(make(FakePodApi(), worker, includeLocal: false));
    expect(cloudBaked..sort(), [1, 2, 3, 4]);
    expect(localBaked, isEmpty);
    expect(failed, isEmpty);
  });

  test(
    'a pod that never gets ready is deleted and the episodes marked failed',
    () async {
      final api = FakePodApi(readyAfterPolls: 1 << 30);
      final s = make(
        api,
        FakeWorker(),
        includeLocal: false,
        readyTimeout: const Duration(milliseconds: 20),
      );
      await runIt(s);
      expect(localBaked, isEmpty);
      expect(failed..sort(), [1, 2, 3, 4]);
      expect(errors.first, contains('启动超时'));
      expect(api.deleted, ['pod1']);
      expect(s.view.message, contains('启动超时'));
    },
  );

  test('with no stock it waits, then starts once a GPU frees up', () async {
    final api = FakePodApi()..inStock = false;
    final s = make(api, FakeWorker(), includeLocal: false);
    final running = runIt(s);
    await until(() => s.view.phase == CloudBakePhase.waiting);
    await until(() => api.offerChecks >= 3);
    expect(api.created, isEmpty);
    expect(localBaked, isEmpty);
    expect(stages[1], CloudEpisodeStage.queued);
    api.inStock = true;
    await running;
    expect(cloudBaked..sort(), [1, 2, 3, 4]);
    expect(api.created, hasLength(1));
    expect(api.deleted, ['pod1']);
  });

  test('stopping while waiting returns everything and rents nothing', () async {
    final api = FakePodApi()..inStock = false;
    final s = make(api, FakeWorker(), includeLocal: false);
    final running = runIt(s);
    await until(() => s.view.phase == CloudBakePhase.waiting);
    await s.stop();
    await running;
    expect(returned..sort(), [1, 2, 3, 4]);
    expect(api.created, isEmpty);
    expect(api.deleted, isEmpty);
    expect(s.view.phase, CloudBakePhase.stopped);
    expect(stages.values.whereType<CloudEpisodeStage>(), isEmpty);
  });

  test('stopping during a stock check rents nothing', () async {
    final api = FakePodApi()..inStock = false;
    final s = make(api, FakeWorker(), includeLocal: false);
    api.onOffer = () {
      // Stock turns up in the same reply that Stop raced.
      api.inStock = true;
      unawaited(s.stop());
    };
    await runIt(s);
    expect(api.created, isEmpty);
    expect(s.view.phase, CloudBakePhase.stopped);
  });

  test('while waiting the laptop can drain the queue and end it', () async {
    final api = FakePodApi()..inStock = false;
    final s = make(api, FakeWorker(), includeLocal: true, count: 2);
    await runIt(s);
    expect(localBaked..sort(), [1, 2]);
    expect(api.created, isEmpty);
    expect(s.add([job(3)]), isFalse);
  });

  test('a hard error at creation marks cloud episodes failed', () async {
    final api = FakePodApi(createError: const RunpodException('Runpod 余额不足'));
    final s = make(api, FakeWorker(), includeLocal: false);
    await runIt(s);
    expect(localBaked, isEmpty);
    expect(failed..sort(), [1, 2, 3, 4]);
    expect(errors.first, '云端烘焙未完成: Runpod 余额不足');
    expect(api.deleted, isEmpty);
    expect(s.view.message, 'Runpod 余额不足');
  });

  test('with the laptop on, only episodes picked for the cloud fail', () async {
    final api = FakePodApi(createError: const RunpodException('Runpod 余额不足'));
    final s = CloudBakeSession(
      api: api,
      connect: (uri, token) => FakeWorker(),
      jobs: [job(1), job(2, cloudOnly: true)],
      includeLocal: true,
      workerScript: 'packed',
      capSec: 1800,
      pricePerHour: 1.09,
      shader: '',
      targetHeight: 1440,
      prepareInput: (job) async => (File(path.join(dir.path, 'x')), false),
      bakeLocally: (job) async {
        localBaked.add(job.episodeNumber);
        return LocalBakeOutcome.done;
      },
      onCloudBaked: (job) async {},
      onReturned: (job) async {},
      onFailed: (job, error) async => failed.add(job.episodeNumber),
      pollInterval: const Duration(milliseconds: 1),
    );
    await runIt(s);
    expect(localBaked, [1]);
    expect(failed, [2]);
  });

  test(
    'episodes added while running go to the pod and raise the cap',
    () async {
      final api = FakePodApi();
      final worker = FakeWorker()..bakeForever = true;
      final s = make(api, worker, includeLocal: false, count: 1);
      final running = runIt(s);
      await until(() => worker.episodes.isNotEmpty);
      expect(
        s.add([job(7, recordKey: 'other', cloudOnly: true, durationSec: 7200)]),
        isTrue,
      );
      expect(s.holds('other', 7), isTrue);
      expect(s.view.total, 2);
      expect(s.capSec, greaterThan(3000));
      await until(() => worker.caps.isNotEmpty);
      expect(worker.caps.last, s.capSec);
      await until(() => worker.episodes.length == 2);
      worker.bakeForever = false;
      for (final key in worker.episodes.keys.toList()) {
        worker.episodes[key] = const WorkerEpisode(
          state: 'done',
          progress: 1,
          outBytes: 3,
        );
      }
      await running;
      expect(cloudBaked..sort(), [1, 7]);
      expect(api.created, hasLength(1));
      expect(s.add([job(8)]), isFalse);
    },
  );

  test(
    'episodes added while the pod boots raise its cap once it is up',
    () async {
      final api = FakePodApi(readyAfterPolls: 5);
      final worker = FakeWorker();
      final s = make(api, worker, includeLocal: false, count: 1);
      final running = runIt(s);
      await until(() => api.created.isNotEmpty);
      expect(api.created.single['KAZUMI_CAP_SEC'], '1800');
      expect(s.add([job(2, durationSec: 7200)]), isTrue);
      await running;
      expect(worker.caps.first, greaterThan(3000));
      expect(cloudBaked..sort(), [1, 2]);
    },
  );

  test('the app tops up a pod whose cap would run out first', () async {
    final worker = FakeWorker()
      ..bakeForever = true
      ..uptimeSec = 1700
      ..podCapSec = 1800;
    final s = make(FakePodApi(), worker, includeLocal: false, count: 1);
    final running = runIt(s);
    await until(() => worker.caps.isNotEmpty);
    // 1700 s used and a half-baked episode left: the pod gets well past 1800.
    expect(worker.caps.last, greaterThan(1700 + 300));
    await s.stop();
    await running;
  });

  test('a pod at the 12 h ceiling is not asked for more every poll', () async {
    final worker = FakeWorker()
      ..bakeForever = true
      ..uptimeSec = CloudBakeRates.maxCapSec - 100
      ..podCapSec = CloudBakeRates.maxCapSec;
    final s = make(FakePodApi(), worker, includeLocal: false, count: 1);
    final running = runIt(s);
    await until(() => worker.statusCalls >= 20);
    expect(worker.caps, isEmpty);
    await s.stop();
    await running;
  });

  test('adding an episode the session already holds is a no-op', () async {
    final s = make(
      FakePodApi()..inStock = false,
      FakeWorker(),
      includeLocal: false,
      count: 1,
    );
    final running = runIt(s);
    await until(() => s.view.phase == CloudBakePhase.waiting);
    expect(s.add([job(1)]), isTrue);
    expect((s.view.total, s.capSec), (1, 1800));
    await s.stop();
    await running;
  });

  test('the laptop leaves episodes picked for the cloud alone', () async {
    final api = FakePodApi(readyAfterPolls: 3);
    final s = make(
      api,
      FakeWorker(),
      includeLocal: true,
      cloudOnly: true,
      localTime: const Duration(milliseconds: 5),
    );
    await runIt(s);
    expect(cloudBaked..sort(), [1, 2, 3, 4]);
    expect(localBaked, isEmpty);
  });

  test('a queued episode can be taken back before it is uploaded', () async {
    final api = FakePodApi()..inStock = false;
    final s = make(api, FakeWorker(), includeLocal: false, count: 2);
    final running = runIt(s);
    await until(() => s.view.phase == CloudBakePhase.waiting);
    expect(s.queued('r', 2), isTrue);
    expect(await s.remove('r', 2), isTrue);
    expect(await s.remove('r', 2), isFalse);
    expect(returned, [2]);
    expect((s.view.total, s.holds('r', 2)), (1, false));
    expect(stages[2], isNull);
    api.inStock = true;
    await running;
    expect(cloudBaked, [1]);
  });

  test('the report lists every episode once it is home', () async {
    final api = FakePodApi();
    final worker = FakeWorker()..failIds.add(id(3));
    final s = make(api, worker, includeLocal: false);
    await runIt(s);
    final report = s.report;
    expect(report.stopped, isFalse);
    expect(report.podEndedAt, isNotNull);
    final byEp = {for (final e in report.episodes) e.job.episodeNumber: e};
    expect(byEp.keys.toSet(), {1, 2, 3, 4});
    expect(byEp[1]!.outcome, CloudEpisodeOutcome.cloud);
    expect(byEp[1]!.outBytes, 3);
    expect(byEp[1]!.uploadSec, isNotNull);
    expect(byEp[3]!.outcome, CloudEpisodeOutcome.failed);
    expect(byEp[3]!.error, contains('boom'));
    for (final n in [1, 2, 4]) {
      expect(
        File(path.join(dir.path, 'r$n', 'upscaled', 'video.mp4')).existsSync(),
        isTrue,
      );
    }
    expect(report.cloudMediaSec, 3 * 1440);
    expect(report.laptopSec, (3 * 1440 / 2.7).ceil());
  });

  test('a stopped run reports its episodes as returned', () async {
    final worker = FakeWorker()..bakeForever = true;
    final s = make(FakePodApi(), worker, includeLocal: false, count: 2);
    final running = runIt(s);
    await until(() => worker.episodes.isNotEmpty);
    await s.stop();
    await running;
    expect(s.report.stopped, isTrue);
    expect(s.report.episodes.map((e) => e.outcome).toSet(), {
      CloudEpisodeOutcome.returned,
    });
  });

  test('ids are unique across shows and safe for the worker', () {
    final a = CloudJob.idFor('109375_xfdmnext', 1);
    final b = CloudJob.idFor('175599_淘片动漫', 1);
    expect(a, isNot(b));
    expect(a, CloudJob.idFor('109375_xfdmnext', 1));
    for (final id in [a, b]) {
      expect(RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id), isTrue);
    }
  });

  test('losing the pod marks its episodes failed', () async {
    final api = FakePodApi();
    final worker = FakeWorker()
      ..bakeForever = true
      ..goDarkAfterStatus = 2;
    final s = make(api, worker, includeLocal: false);
    await runIt(s);
    expect(localBaked, isEmpty);
    expect(failed..sort(), [1, 2, 3, 4]);
    expect(api.deleted, ['pod1']);
    expect(s.view.message, contains('失去联系'));
  });

  test('stop deletes the pod and returns what is unfinished', () async {
    final api = FakePodApi();
    final worker = FakeWorker()..bakeForever = true;
    final s = make(api, worker, includeLocal: false);
    final running = runIt(s);
    while (worker.episodes.isEmpty) {
      await Future.delayed(const Duration(milliseconds: 1));
    }
    await s.stop();
    await running;
    expect(api.deleted, ['pod1']);
    expect(returned..sort(), [1, 2, 3, 4]);
    expect(localBaked, isEmpty);
    expect(s.view.phase, CloudBakePhase.stopped);
  });

  test('an episode that vanishes from the pod is marked failed', () async {
    final worker = FakeWorker()..vanishIds.add(id(2));
    await runIt(make(FakePodApi(), worker, includeLocal: false));
    expect(localBaked, isEmpty);
    expect(failed, [2]);
    expect(cloudBaked..sort(), [1, 3, 4]);
  });

  test('an episode stuck baking is marked failed', () async {
    final api = FakePodApi();
    final worker = FakeWorker()..bakeForever = true;
    await runIt(
      make(
        api,
        worker,
        includeLocal: false,
        count: 2,
        stallAfter: const Duration(milliseconds: 30),
      ),
    );
    expect(localBaked, isEmpty);
    expect(failed..sort(), [1, 2]);
    expect(api.deleted, ['pod1']);
  });

  test('a garbled status reply is retried, not fatal', () async {
    final worker = FakeWorker()..garbledStatusCall = 2;
    await runIt(make(FakePodApi(), worker, includeLocal: false));
    expect(cloudBaked..sort(), [1, 2, 3, 4]);
    expect(localBaked, isEmpty);
  });

  test('a failed shader upload is retried', () async {
    final worker = FakeWorker()..shaderFailures = 2;
    await runIt(make(FakePodApi(), worker, includeLocal: false));
    expect(cloudBaked..sort(), [1, 2, 3, 4]);
  });

  test('the summary carries what went wrong', () {
    final start = DateTime(2026, 10, 6, 12);
    final view = CloudBakeSessionView(
      phase: CloudBakePhase.done,
      cloudDone: 0,
      localDone: 4,
      failed: 0,
      total: 4,
      startedAt: start,
      pricePerHour: 1.09,
      message: '云端 GPU 启动超时，改用本机烘焙',
    );
    expect(
      view.summary(start.add(const Duration(minutes: 40))),
      '云端烘焙完成 · 4 集 · 40 分钟 · \$0.00 · 云端 GPU 启动超时，改用本机烘焙',
    );
  });

  test('a partial download left by an earlier run is discarded', () async {
    final stale = File(path.join(dir.path, 'r1', 'upscaled', 'video.mp4.part'))
      ..createSync(recursive: true)
      ..writeAsStringSync('old');
    File('${path.withoutExtension(stale.path)}.parts').writeAsStringSync('0\n');
    await runIt(
      make(FakePodApi(), FakeWorker(), includeLocal: false, count: 1),
    );
    expect(stale.existsSync(), isFalse);
    expect(
      File(
        path.join(dir.path, 'r1', 'upscaled', 'video.mp4'),
      ).readAsBytesSync(),
      [1, 2, 3],
    );
  });

  test('cost runs from pod creation to deletion', () {
    final start = DateTime(2026, 10, 6, 12);
    final view = CloudBakeSessionView(
      phase: CloudBakePhase.done,
      cloudDone: 2,
      localDone: 1,
      failed: 0,
      total: 3,
      startedAt: start,
      podStartedAt: start,
      podEndedAt: start.add(const Duration(hours: 1)),
      pricePerHour: 1.09,
    );
    expect(
      view.costAt(start.add(const Duration(hours: 5))),
      closeTo(1.09, 1e-9),
    );
    expect(
      view.summary(start.add(const Duration(minutes: 68))),
      '云端烘焙完成 · 3 集 · 68 分钟 · \$1.09',
    );
  });
}
