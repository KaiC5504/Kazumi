import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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

  @override
  Future<CloudOffer> sydneyOffer() async =>
      const CloudOffer(available: true, pricePerHour: 1.09);

  @override
  Future<CloudPodInfo> createPod({
    required String name,
    required Map<String, String> env,
    required int diskGb,
  }) async {
    if (createError != null) throw createError!;
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
  final shaders = <String>[];
  final drops = <String>[];
  var bakeForever = false;
  var goDarkAfterStatus = 1 << 30;
  var statusCalls = 0;
  var shutdowns = 0;

  @override
  Future<WorkerStatus> status() async {
    if (++statusCalls > goDarkAfterStatus) {
      throw const CloudWorkerException('down');
    }
    return WorkerStatus(state: 'ready', episodes: Map.of(episodes));
  }

  @override
  Future<void> putShader(String glsl) async => shaders.add(glsl);

  @override
  Future<void> upload(
    String id,
    File source, {
    void Function(int sent)? onProgress,
    bool Function()? stopped,
  }) async {
    if (uploadFailIds.contains(id)) {
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
}

void main() {
  late Directory dir;
  late List<int> cloudBaked, localBaked, returned, failed;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cloud_session_');
    cloudBaked = [];
    localBaked = [];
    returned = [];
    failed = [];
  });
  tearDown(() => dir.deleteSync(recursive: true));

  CloudBakeSession make(
    FakePodApi api,
    FakeWorker worker, {
    required bool includeLocal,
    int count = 4,
    Duration localTime = Duration.zero,
    Duration readyTimeout = const Duration(seconds: 2),
  }) {
    return CloudBakeSession(
      api: api,
      connect: (uri, token) => worker,
      recordKey: 'r',
      jobs: [
        for (var i = 1; i <= count; i++)
          CloudJob(
            recordKey: 'r',
            episodeNumber: i,
            durationSec: 1440,
            outputPath: path.join(dir.path, '$i', 'upscaled', 'video.mp4'),
          ),
      ],
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
      onFailed: (job, error) async => failed.add(job.episodeNumber),
      pollInterval: const Duration(milliseconds: 1),
      readyTimeout: readyTimeout,
      lostAfter: const Duration(milliseconds: 30),
      deleteTimeout: const Duration(milliseconds: 50),
    );
  }

  Future<void> runIt(CloudBakeSession s) =>
      s.run().timeout(const Duration(seconds: 10));

  test(
    'cloud only: every episode goes to the pod, which is deleted after',
    () async {
      final api = FakePodApi();
      final worker = FakeWorker();
      final s = make(api, worker, includeLocal: false);
      expect(s.holds(1), isTrue);
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
      expect(api.created.single['KAZUMI_CAP_SEC'], '1800');
      expect(api.created.single['KAZUMI_WORKER'], 'packed');
      expect(s.view.phase, CloudBakePhase.done);
      expect(s.holds(1), isFalse);
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
    final worker = FakeWorker()..failIds.add('ep2');
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
      final worker = FakeWorker()..failIds.add('ep2');
      await runIt(make(FakePodApi(), worker, includeLocal: false));
      expect(failed, [2]);
      expect(cloudBaked..sort(), [1, 3, 4]);
      expect(localBaked, isEmpty);
    },
  );

  test('a failed upload goes to the laptop even when it is off', () async {
    final worker = FakeWorker()..uploadFailIds.add('ep1');
    await runIt(make(FakePodApi(), worker, includeLocal: false));
    expect(localBaked, [1]);
    expect(cloudBaked..sort(), [2, 3, 4]);
  });

  test(
    'a pod that never gets ready is deleted and the laptop bakes all',
    () async {
      final api = FakePodApi(readyAfterPolls: 1 << 30);
      final s = make(
        api,
        FakeWorker(),
        includeLocal: false,
        readyTimeout: const Duration(milliseconds: 20),
      );
      await runIt(s);
      expect(localBaked..sort(), [1, 2, 3, 4]);
      expect(api.deleted, ['pod1']);
      expect(s.view.message, contains('启动超时'));
    },
  );

  test(
    'no stock at creation means the laptop bakes all and nothing is deleted',
    () async {
      final api = FakePodApi(
        createError: const RunpodException('悉尼暂无可用 GPU', noCapacity: true),
      );
      final s = make(api, FakeWorker(), includeLocal: false);
      await runIt(s);
      expect(localBaked..sort(), [1, 2, 3, 4]);
      expect(api.deleted, isEmpty);
      expect(s.view.message, '悉尼暂无可用 GPU');
    },
  );

  test('losing the pod hands its episodes to the laptop', () async {
    final api = FakePodApi();
    final worker = FakeWorker()
      ..bakeForever = true
      ..goDarkAfterStatus = 2;
    final s = make(api, worker, includeLocal: false);
    await runIt(s);
    expect(localBaked..sort(), [1, 2, 3, 4]);
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

  test('a partial download left by an earlier run is discarded', () async {
    final stale = File(path.join(dir.path, '1', 'upscaled', 'video.mp4.part'))
      ..createSync(recursive: true)
      ..writeAsStringSync('old');
    File('${path.withoutExtension(stale.path)}.parts').writeAsStringSync('0\n');
    await runIt(
      make(FakePodApi(), FakeWorker(), includeLocal: false, count: 1),
    );
    expect(stale.existsSync(), isFalse);
    expect(
      File(path.join(dir.path, '1', 'upscaled', 'video.mp4')).readAsBytesSync(),
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
