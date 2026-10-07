import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/upscale/cloud/cloud_worker_script.dart';

void main() {
  final source = File('server/cloud/kazumi_bake_worker.py')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  test('the packed worker fits in a pod env value', () {
    expect(packedCloudWorker.length, lessThanOrEqualTo(maxPackedWorkerLength));
  });

  test('the packed worker matches server/cloud/kazumi_bake_worker.py', () {
    expect(
      utf8.decode(gzip.decode(base64.decode(packedCloudWorker))),
      source,
      reason: 'run python scripts/pack_cloud_worker.py',
    );
  });

  test('the start command unpacks the env value and runs it', () {
    expect(
      cloudWorkerStartCommand,
      contains(r'"$KAZUMI_WORKER" | base64 -d | gunzip'),
    );
    expect(cloudWorkerStartCommand, contains('exec python3 -u'));
  });
}
