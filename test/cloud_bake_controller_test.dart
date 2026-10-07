import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/upscale/cloud/runpod_api.dart';
import 'package:kazumi/services/upscale/upscale_controller.dart';

void main() {
  test('HLS downloads are remuxed into one file without re-encoding', () {
    final args = UpscaleController.cloudRemuxArgs(
      '/d/ep3/index.m3u8',
      '/d/ep3/upscaled/cloud_input.mkv',
    );
    expect(
      args.join(' '),
      contains(
        '-allowed_extensions ALL -protocol_whitelist file,crypto,data -i /d/ep3/index.m3u8',
      ),
    );
    expect(args.join(' '), contains('-c copy'));
    expect(args.last, '/d/ep3/upscaled/cloud_input.mkv');
  });

  test('only live kazumi pods count as leftovers', () {
    CloudPodInfo pod(String name, String status) =>
        CloudPodInfo(id: name, name: name, status: status, costPerHour: 1.09);
    final leftovers = UpscaleController.leftoverPods([
      pod('kazumi-bake-abc123', 'RUNNING'),
      pod('kazumi-bake-def456', 'TERMINATED'),
      pod('comfyui', 'RUNNING'),
      pod('kazumi-bake-ghi789', 'EXITED'),
    ]);
    expect(leftovers.map((p) => p.name), [
      'kazumi-bake-abc123',
      'kazumi-bake-ghi789',
    ]);
  });

  test(
    'a queued episode stays cancellable while it waits for the GPU',
    () async {
      final queue = [1, 2];
      final gate = Completer<void>();
      final baked = <int>[];
      final drained = UpscaleController.drainOnGpu<int>(queue, (bake) async {
        await gate.future;
        await bake();
      }, (item) async => baked.add(item));
      await Future<void>.delayed(Duration.zero);
      expect(queue, [1, 2]);
      queue.remove(2);
      gate.complete();
      await drained;
      expect(baked, [1]);
    },
  );
}
