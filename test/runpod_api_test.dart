import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/upscale/cloud/runpod_api.dart';

class _Call {
  _Call(this.method, this.uri, this.auth, this.body);
  final String method;
  final Uri uri;
  final String? auth;
  final String body;
}

void main() {
  late HttpServer server;
  late List<_Call> calls;
  late (int, String) Function(_Call) respond;
  late RunpodApi api;

  setUp(() async {
    calls = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final call = _Call(
        request.method,
        request.uri,
        request.headers.value(HttpHeaders.authorizationHeader),
        await utf8.decodeStream(request),
      );
      calls.add(call);
      final (status, body) = respond(call);
      request.response.statusCode = status;
      request.response.write(body);
      await request.response.close();
    });
    api = RunpodApi(
      'rk_test',
      base: Uri.parse('http://127.0.0.1:${server.port}'),
    );
  });

  tearDown(() => server.close(force: true));

  test('reads Sydney stock and the secure price', () async {
    respond = (_) => (
      200,
      jsonEncode({
        'id': 'NVIDIA L40S',
        'price': {'secure': 1.09, 'community': 0.79},
        'dataCenters': [
          {'id': 'US-TX-3', 'availability': 'HIGH'},
          {'id': 'OC-AU-1', 'availability': 'LOW'},
        ],
      }),
    );
    final offer = await api.sydneyOffer();
    expect((offer.available, offer.pricePerHour), (true, 1.09));
    expect(calls.single.auth, 'Bearer rk_test');
    expect(calls.single.uri.path, '/v2/catalog/gpus/NVIDIA%20L40S');
    expect(calls.single.uri.queryParameters, {
      'include': 'AVAILABILITY',
      'product': 'POD',
      'cloud': 'SECURE',
    });
  });

  test('no Sydney entry means no stock', () async {
    respond = (_) => (
      200,
      jsonEncode({
        'price': {'secure': 1.09},
        'dataCenters': [
          {'id': 'US-TX-3', 'availability': 'HIGH'},
        ],
      }),
    );
    expect((await api.sydneyOffer()).available, false);
  });

  test('creates the pod with the verified shape', () async {
    respond = (_) => (
      201,
      jsonEncode({
        'id': 'pod1',
        'name': 'kazumi-bake-abc123',
        'status': 'PROVISIONING',
        'cost': 1.09,
      }),
    );
    final pod = await api.createPod(
      name: 'kazumi-bake-abc123',
      env: {'KAZUMI_TOKEN': 't'},
      diskGb: 50,
    );
    expect((pod.id, pod.costPerHour, pod.workerUri), ('pod1', 1.09, null));
    final body = jsonDecode(calls.single.body) as Map<String, dynamic>;
    expect(calls.single.method, 'POST');
    expect(calls.single.uri.path, '/v2/pods');
    expect(body['image'], 'runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404');
    expect(body['cloud'], 'SECURE');
    expect(body['dataCenterIds'], ['OC-AU-1']);
    expect(body['gpu'], {'id': 'NVIDIA L40S', 'count': 1});
    expect(body['disk'], 50);
    expect(body['ports'], ['8080/tcp']);
    expect(body['env'], {
      'NVIDIA_DRIVER_CAPABILITIES': 'all',
      'KAZUMI_TOKEN': 't',
    });
    expect(body['entrypoint'], ['/bin/bash', '-c']);
    expect((body['cmd'] as List).single, contains('KAZUMI_WORKER'));
  });

  test('finds the worker port in the pod runtime', () async {
    respond = (_) => (
      200,
      jsonEncode({
        'id': 'pod1',
        'name': 'kazumi-bake-abc123',
        'status': 'RUNNING',
        'cost': 1.09,
        'createdAt': '2026-10-06T05:24:17.081Z',
        'runtime': {
          'ports': [
            {
              'ip': '100.65.24.109',
              'private': 19123,
              'public': 60215,
              'type': 'http',
            },
            {
              'ip': '160.250.71.215',
              'private': 8080,
              'public': 42651,
              'type': 'tcp',
            },
          ],
        },
      }),
    );
    final pod = await api.getPod('pod1');
    expect(pod!.workerUri, Uri.parse('http://160.250.71.215:42651'));
    expect(pod.createdAt, DateTime.utc(2026, 10, 6, 5, 24, 17, 81));
  });

  test('a missing pod reads as null and deletes quietly', () async {
    respond = (_) => (
      404,
      jsonEncode({
        'title': 'Not Found',
        'status': 404,
        'detail': 'pod not found',
      }),
    );
    expect(await api.getPod('gone'), isNull);
    await api.deletePod('gone');
    expect(calls.map((c) => c.method), ['GET', 'DELETE']);
  });

  test('lists pods', () async {
    respond = (_) => (
      200,
      jsonEncode({
        'pods': [
          {
            'id': 'a',
            'name': 'kazumi-bake-x',
            'status': 'RUNNING',
            'cost': 1.09,
          },
        ],
      }),
    );
    final pods = await api.listPods();
    expect(pods.single.name, 'kazumi-bake-x');
  });

  group('error mapping', () {
    String problem(String detail) =>
        jsonEncode({'title': 'x', 'status': 400, 'detail': detail});

    test('401 is a bad key', () {
      expect(
        runpodError(401, problem('unauthorized')).message,
        'Runpod API Key 无效',
      );
    });
    test('balance problems say so', () {
      expect(
        runpodError(402, problem('Insufficient balance to deploy')).message,
        'Runpod 余额不足',
      );
    });
    test('capacity problems are flagged as no stock', () {
      final e = runpodError(
        409,
        problem('There are no instances currently available'),
      );
      expect((e.noCapacity, e.message), (true, '悉尼暂无可用 GPU'));
    });
    test('anything else keeps the detail', () {
      expect(
        runpodError(500, problem('boom')).message,
        'Runpod 返回错误 500: boom',
      );
    });
  });

  test('errors from the server surface as RunpodException', () async {
    respond = (_) => (401, problem401);
    expect(api.sydneyOffer(), throwsA(isA<RunpodException>()));
  });
}

final problem401 = jsonEncode({
  'title': 'Unauthorized',
  'status': 401,
  'detail': 'bad key',
});
