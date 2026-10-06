import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:kazumi/services/upscale/cloud/cloud_worker_script.dart';

const cloudWorkerPort = 8080;
const cloudPodNamePrefix = 'kazumi-bake-';

class RunpodException implements Exception {
  const RunpodException(
    this.message, {
    this.statusCode,
    this.noCapacity = false,
  });

  final String message;
  final int? statusCode;
  final bool noCapacity;

  @override
  String toString() => message;
}

class CloudOffer {
  const CloudOffer({required this.available, required this.pricePerHour});

  final bool available;
  final double pricePerHour;
}

class CloudPodInfo {
  const CloudPodInfo({
    required this.id,
    required this.name,
    required this.status,
    required this.costPerHour,
    this.workerUri,
    this.createdAt,
  });

  final String id;
  final String name;
  final String status;
  final double costPerHour;

  /// Where the worker listens, once Runpod has mapped its port.
  final Uri? workerUri;
  final DateTime? createdAt;

  bool get gone => status == 'TERMINATED';

  factory CloudPodInfo.fromJson(Map<String, dynamic> json) {
    Uri? worker;
    final runtime = json['runtime'] as Map<String, dynamic>?;
    for (final entry in runtime?['ports'] as List? ?? const []) {
      final port = entry as Map<String, dynamic>;
      if (port['private'] == cloudWorkerPort &&
          port['type'] == 'tcp' &&
          port['ip'] is String &&
          port['public'] is int) {
        worker = Uri(
          scheme: 'http',
          host: port['ip'] as String,
          port: port['public'] as int,
        );
      }
    }
    return CloudPodInfo(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      status: json['status'] as String? ?? '',
      costPerHour: (json['cost'] as num?)?.toDouble() ?? 0,
      workerUri: worker,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
    );
  }
}

/// What a cloud bake needs from Runpod; the session is tested against a fake.
abstract class CloudPodApi {
  Future<CloudOffer> sydneyOffer();

  Future<CloudPodInfo> createPod({
    required String name,
    required Map<String, String> env,
    required int diskGb,
  });

  /// Null once the pod no longer exists.
  Future<CloudPodInfo?> getPod(String id);

  Future<void> deletePod(String id);

  Future<List<CloudPodInfo>> listPods();
}

/// Runpod REST v2 (https://api.runpod.io/v2/openapi.json).
class RunpodApi implements CloudPodApi {
  RunpodApi(this.apiKey, {Uri? base})
    : base = base ?? Uri.parse('https://api.runpod.io');

  final String apiKey;
  final Uri base;

  static const gpuId = 'NVIDIA L40S';
  static const dataCenterId = 'OC-AU-1';

  /// The image the 2026-10-06 runs were verified on (driver 580, python3).
  static const image = 'runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404';

  @override
  Future<CloudOffer> sydneyOffer() async {
    final json = await _request(
      'GET',
      ['v2', 'catalog', 'gpus', gpuId],
      query: {'include': 'AVAILABILITY', 'product': 'POD', 'cloud': 'SECURE'},
    );
    final price = (json['price'] as Map<String, dynamic>?)?['secure'] as num?;
    String availability = 'NONE';
    for (final entry in json['dataCenters'] as List? ?? const []) {
      final center = entry as Map<String, dynamic>;
      if (center['id'] == dataCenterId) {
        availability = center['availability'] as String? ?? 'NONE';
      }
    }
    return CloudOffer(
      available: availability != 'NONE',
      pricePerHour: price?.toDouble() ?? 0,
    );
  }

  @override
  Future<CloudPodInfo> createPod({
    required String name,
    required Map<String, String> env,
    required int diskGb,
  }) async {
    final json = await _request(
      'POST',
      ['v2', 'pods'],
      body: {
        'name': name,
        'image': image,
        'cloud': 'SECURE',
        'dataCenterIds': [dataCenterId],
        'gpu': {'id': gpuId, 'count': 1},
        'disk': diskGb,
        'ports': ['$cloudWorkerPort/tcp'],
        // Without this the container gets no graphics libraries, so no Vulkan.
        'env': {'NVIDIA_DRIVER_CAPABILITIES': 'all', ...env},
        'entrypoint': ['/bin/bash', '-c'],
        'cmd': [cloudWorkerStartCommand],
      },
    );
    return CloudPodInfo.fromJson(json);
  }

  @override
  Future<CloudPodInfo?> getPod(String id) async {
    try {
      return CloudPodInfo.fromJson(await _request('GET', ['v2', 'pods', id]));
    } on RunpodException catch (e) {
      if (e.statusCode == HttpStatus.notFound) return null;
      rethrow;
    }
  }

  @override
  Future<void> deletePod(String id) async {
    try {
      await _request('DELETE', ['v2', 'pods', id]);
    } on RunpodException catch (e) {
      if (e.statusCode != HttpStatus.notFound) rethrow;
    }
  }

  @override
  Future<List<CloudPodInfo>> listPods() async {
    final json = await _request('GET', ['v2', 'pods']);
    return [
      for (final pod in json['pods'] as List? ?? const [])
        CloudPodInfo.fromJson(pod as Map<String, dynamic>),
    ];
  }

  Future<Map<String, dynamic>> _request(
    String method,
    List<String> segments, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final uri = base.replace(pathSegments: segments, queryParameters: query);
      final request = await client.openUrl(method, uri);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final text = await utf8.decodeStream(response);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw runpodError(response.statusCode, text);
      }
      return text.isEmpty ? {} : jsonDecode(text) as Map<String, dynamic>;
    } on SocketException {
      throw const RunpodException('无法连接到 Runpod');
    } on TimeoutException {
      throw const RunpodException('连接 Runpod 超时');
    } finally {
      client.close(force: true);
    }
  }
}

@visibleForTesting
RunpodException runpodError(int status, String body) {
  var detail = body;
  try {
    final json = jsonDecode(body);
    if (json is Map) {
      detail = '${json['detail'] ?? json['title'] ?? json['error'] ?? body}';
    }
  } on FormatException {
    // Not JSON; keep the raw body.
  }
  final lower = detail.toLowerCase();
  if (status == HttpStatus.unauthorized) {
    return RunpodException('Runpod API Key 无效', statusCode: status);
  }
  if (lower.contains('balance') ||
      lower.contains('insufficient funds') ||
      lower.contains('credit')) {
    return RunpodException('Runpod 余额不足', statusCode: status);
  }
  if (status == HttpStatus.forbidden) {
    return RunpodException('Runpod API Key 权限不足 (需要读写权限)', statusCode: status);
  }
  if (lower.contains('capacity') ||
      lower.contains('no instances') ||
      lower.contains('not available') ||
      lower.contains('no available')) {
    return RunpodException('悉尼暂无可用 GPU', statusCode: status, noCapacity: true);
  }
  return RunpodException('Runpod 返回错误 $status: $detail', statusCode: status);
}
