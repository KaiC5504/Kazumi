import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/upscale/cloud/cloud_bake_worker_client.dart';
import 'package:path/path.dart' as path;

const _token = 'tok_tok_tok_tok_tok_tok_tok_tok_tok_tok';

/// A worker that keeps parts in memory and serves [output] for episode e1.
class _FakeWorker {
  final parts = <int, List<int>>{};
  final putIndices = <int>[];
  final ranges = <String>[];
  List<int> output = [];
  late HttpServer server;

  Future<Uri> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handle);
    return Uri.parse('http://127.0.0.1:${server.port}');
  }

  Future<void> _handle(HttpRequest request) async {
    final res = request.response;
    final body = await request.fold<List<int>>([], (a, b) => a..addAll(b));
    if (request.headers.value('X-Kazumi-Token') != _token) {
      res.statusCode = 403;
      return res.close();
    }
    final p = request.uri.pathSegments;
    if (p.join('/') == 'status') {
      res.write(
        jsonEncode({
          'state': 'ready',
          'encoder': 'hevc_nvenc',
          'episodes': {
            'e1': {
              'state': 'baking',
              'progress': 0.25,
              'outBytes': 0,
              'error': null,
            },
          },
        }),
      );
    } else if (p.length == 3 && p[2] == 'parts' && request.method == 'GET') {
      res.write(
        jsonEncode({
          'parts': {for (final e in parts.entries) '${e.key}': e.value.length},
        }),
      );
    } else if (p.length == 4 && request.method == 'PUT') {
      final index = int.parse(p[3]);
      putIndices.add(index);
      parts[index] = body;
      res.write('{}');
    } else if (p.first == 'out' && request.method == 'HEAD') {
      res.contentLength = output.length;
    } else if (p.first == 'out' && request.method == 'GET') {
      final range = request.headers.value(HttpHeaders.rangeHeader)!;
      ranges.add(range);
      final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range)!;
      final start = int.parse(m[1]!);
      final end = int.parse(m[2]!) + 1;
      res.statusCode = HttpStatus.partialContent;
      res.add(output.sublist(start, end));
    } else {
      res.statusCode = 404;
    }
    await res.close();
  }
}

void main() {
  late _FakeWorker fake;
  late CloudBakeWorkerClient client;
  late Directory dir;

  setUp(() async {
    fake = _FakeWorker();
    final base = await fake.start();
    client = CloudBakeWorkerClient(base, _token, partSize: 4);
    dir = Directory.systemTemp.createTempSync('cloud_client_');
  });

  tearDown(() async {
    await fake.server.close(force: true);
    dir.deleteSync(recursive: true);
  });

  test('reads status', () async {
    final status = await client.status();
    expect(status.state, 'ready');
    expect(status.episodes['e1']!.progress, 0.25);
  });

  test('a wrong token is reported with its status code', () async {
    final bad = CloudBakeWorkerClient(
      Uri.parse('http://127.0.0.1:${fake.server.port}'),
      'nope',
    );
    expect(
      bad.status(),
      throwsA(
        isA<CloudWorkerException>().having((e) => e.statusCode, 'status', 403),
      ),
    );
  });

  test('upload skips parts the worker already has', () async {
    final source = File(path.join(dir.path, 'in.mkv'))
      ..writeAsBytesSync(utf8.encode('0123456789'));
    fake.parts[0] = utf8.encode('0123');
    var last = 0;
    await client.upload('e1', source, onProgress: (n) => last = n);
    expect(fake.putIndices..sort(), [1, 2]);
    expect(
      utf8.decode([...fake.parts[0]!, ...fake.parts[1]!, ...fake.parts[2]!]),
      '0123456789',
    );
    expect(last, 10);
  });

  test('download resumes from the parts log', () async {
    fake.output = utf8.encode('abcdefghij');
    final target = File(path.join(dir.path, 'video.mp4'));
    File('${target.path}.part').writeAsBytesSync(utf8.encode('abcd'));
    File('${target.path}.parts').writeAsStringSync('0\n');
    await client.download('e1', target, expectedBytes: 10);
    expect(target.readAsStringSync(), 'abcdefghij');
    expect(fake.ranges.any((r) => r.startsWith('bytes=0-')), isFalse);
    expect(File('${target.path}.part').existsSync(), isFalse);
  });

  test('download refuses a size that disagrees with the status', () async {
    fake.output = Uint8List(10);
    final target = File(path.join(dir.path, 'video.mp4'));
    expect(
      client.download('e1', target, expectedBytes: 99),
      throwsA(isA<CloudWorkerException>()),
    );
    expect(target.existsSync(), isFalse);
  });
}
