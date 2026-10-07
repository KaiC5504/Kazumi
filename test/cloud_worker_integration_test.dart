import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/upscale/cloud/cloud_bake_worker_client.dart';
import 'package:path/path.dart' as path;

const _token = 'integration_token_integration_token_0000';

/// The Dart client against the real Python worker, so the two sides can't
/// drift apart (each has its own unit tests against itself).
void main() {
  Process? server;
  late Directory dir;
  late CloudBakeWorkerClient client;

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('cloud_integration_');
    try {
      server = await Process.start(Platform.isWindows ? 'python' : 'python3', [
        'test/cloud_worker/serve_for_dart.py',
        path.join(dir.path, 'root'),
        _token,
      ]);
    } on ProcessException {
      return;
    }
    final port = await server!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first;
    client = CloudBakeWorkerClient(
      Uri.parse('http://127.0.0.1:${port.trim()}'),
      _token,
      partSize: 1000,
    );
  });

  tearDownAll(() {
    server?.kill();
    dir.deleteSync(recursive: true);
  });

  test('upload, commit, bake and download round-trip', () async {
    if (server == null) {
      markTestSkipped('python not available');
      return;
    }
    final bytes = List<int>.generate(4500, (i) => i % 251);
    final source = File(path.join(dir.path, 'in.mkv'))..writeAsBytesSync(bytes);
    await client.putShader('//!HOOK MAIN');
    await client.upload('ep1', source);
    await client.commit(
      'ep1',
      size: bytes.length,
      durationSec: 1,
      height: 1440,
    );

    WorkerEpisode? episode;
    for (var i = 0; i < 100; i++) {
      episode = (await client.status()).episodes['ep1'];
      if (episode?.state == 'done' || episode?.state == 'failed') break;
      await Future.delayed(const Duration(milliseconds: 50));
    }
    expect(episode?.state, 'done');
    expect(episode?.outBytes, bytes.length);

    final target = File(path.join(dir.path, 'out', 'video.mp4'))
      ..parent.createSync(recursive: true);
    await client.download('ep1', target, expectedBytes: bytes.length);
    expect(target.readAsBytesSync(), bytes);
    await client.drop('ep1');
    expect((await client.status()).episodes, isEmpty);
  });
}
