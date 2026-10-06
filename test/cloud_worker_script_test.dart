import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/upscale/cloud/cloud_worker_script.dart';

void main() {
  final source = File(cloudWorkerAsset).readAsStringSync();

  test('the packed worker fits in a pod env value', () {
    expect(
      packWorkerScript(source).length,
      lessThanOrEqualTo(maxPackedWorkerLength),
    );
  });

  test('packing round-trips through base64 and gzip', () {
    final packed = packWorkerScript(source);
    expect(utf8.decode(gzip.decode(base64.decode(packed))), source);
  });

  test('the start command unpacks the env value and runs it', () {
    expect(
      cloudWorkerStartCommand,
      contains(r'"$KAZUMI_WORKER" | base64 -d | gunzip'),
    );
    expect(cloudWorkerStartCommand, contains('exec python3 -u'));
  });
}
