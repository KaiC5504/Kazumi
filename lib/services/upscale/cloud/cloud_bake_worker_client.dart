import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kazumi/services/download/parted_transfer.dart';

class CloudWorkerException implements Exception {
  const CloudWorkerException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class WorkerEpisode {
  const WorkerEpisode({
    required this.state,
    required this.progress,
    required this.outBytes,
    this.error,
  });

  /// receiving, queued, baking, done or failed.
  final String state;
  final double progress;
  final int outBytes;
  final String? error;

  factory WorkerEpisode.fromJson(Map<String, dynamic> json) => WorkerEpisode(
    state: json['state'] as String? ?? '',
    progress: (json['progress'] as num?)?.toDouble() ?? 0,
    outBytes: (json['outBytes'] as num?)?.toInt() ?? 0,
    error: json['error'] as String?,
  );
}

class WorkerStatus {
  const WorkerStatus({
    required this.state,
    required this.episodes,
    this.encoder,
    this.error,
  });

  /// booting, ready or broken.
  final String state;
  final Map<String, WorkerEpisode> episodes;
  final String? encoder;
  final String? error;

  factory WorkerStatus.fromJson(Map<String, dynamic> json) => WorkerStatus(
    state: json['state'] as String? ?? '',
    encoder: json['encoder'] as String?,
    error: json['error'] as String?,
    episodes: {
      for (final e in (json['episodes'] as Map<String, dynamic>? ?? {}).entries)
        e.key: WorkerEpisode.fromJson(e.value as Map<String, dynamic>),
    },
  );
}

/// The worker on a cloud bake pod; the session is tested against a fake.
abstract class CloudWorker {
  Future<WorkerStatus> status();

  Future<void> putShader(String glsl);

  Future<void> upload(
    String id,
    File source, {
    void Function(int sent)? onProgress,
    bool Function()? stopped,
  });

  Future<void> commit(
    String id, {
    required int size,
    required double durationSec,
    required int height,
  });

  /// Fetches the finished file into [target], resuming a partial one.
  Future<void> download(
    String id,
    File target, {
    required int expectedBytes,
    void Function(int received)? onProgress,
    bool Function()? stopped,
  });

  Future<void> drop(String id);

  Future<void> shutdown();
}

class CloudBakeWorkerClient implements CloudWorker {
  CloudBakeWorkerClient(
    this.base,
    this.token, {
    this.partSize = transferPartSize,
  });

  static const tokenHeader = 'X-Kazumi-Token';
  static const _timeout = Duration(seconds: 30);

  final Uri base;
  final String token;
  final int partSize;

  @override
  Future<WorkerStatus> status() async =>
      WorkerStatus.fromJson(await _json('GET', ['status']));

  @override
  Future<void> putShader(String glsl) =>
      _json('PUT', ['shader'], raw: utf8.encode(glsl));

  @override
  Future<void> upload(
    String id,
    File source, {
    void Function(int sent)? onProgress,
    bool Function()? stopped,
  }) async {
    bool isStopped() => stopped?.call() ?? false;
    final size = await source.length();
    final json = await _json('GET', ['in', id, 'parts']);
    final done = {
      for (final e in (json['parts'] as Map<String, dynamic>? ?? {}).entries)
        int.parse(e.key): (e.value as num).toInt(),
    };
    int lengthOf(int i) => partLength(i, size, partSize);

    final pending = <int>[];
    var sent = 0;
    for (var i = 0; i < partCount(size, partSize); i++) {
      if (done[i] == lengthOf(i)) {
        sent += lengthOf(i);
      } else {
        pending.add(i);
      }
    }
    final inFlight = <int, int>{};
    void report() => onProgress?.call(
      sent + inFlight.values.fold<int>(0, (sum, n) => sum + n),
    );
    report();

    await runParts(
      pending: pending,
      attempts: 8,
      stopped: isStopped,
      transfer: (index) async {
        try {
          await _putPart(id, source, index, (n) {
            inFlight[index] = n;
            report();
          }, size);
        } finally {
          inFlight.remove(index);
        }
        sent += lengthOf(index);
        report();
      },
    );
    if (isStopped()) throw const CloudWorkerException('已停止');
  }

  Future<void> _putPart(
    String id,
    File source,
    int index,
    void Function(int sent) onProgress,
    int size,
  ) async {
    final start = index * partSize;
    final end = start + partLength(index, size, partSize);
    final client = _client();
    try {
      final request = await client.openUrl(
        'PUT',
        base.replace(pathSegments: ['in', id, 'parts', '$index']),
      );
      request.headers.set(tokenHeader, token);
      request.headers.contentType = ContentType.binary;
      request.contentLength = end - start;
      var sent = 0;
      await request.addStream(
        source.openRead(start, end).map((chunk) {
          sent += chunk.length;
          onProgress(sent);
          return chunk;
        }),
      );
      final response = await request.close().timeout(_timeout);
      await response.drain<void>();
      _check(response.statusCode);
    } on SocketException {
      throw const CloudWorkerException('上传中断');
    } on HttpException {
      throw const CloudWorkerException('上传中断');
    } on TimeoutException {
      throw const CloudWorkerException('上传超时');
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<void> commit(
    String id, {
    required int size,
    required double durationSec,
    required int height,
  }) => _json(
    'POST',
    ['in', id, 'commit'],
    body: {'size': size, 'durationSec': durationSec, 'height': height},
  );

  @override
  Future<void> download(
    String id,
    File target, {
    required int expectedBytes,
    void Function(int received)? onProgress,
    bool Function()? stopped,
  }) async {
    bool isStopped() => stopped?.call() ?? false;
    final size = await _outputSize(id);
    if (size != expectedBytes) {
      throw CloudWorkerException('云端文件大小不符 ($size / $expectedBytes)');
    }
    final tmp = File('${target.path}.part');
    final complete = await downloadInParts(
      tmpFile: tmp,
      partsLog: File('${target.path}.parts'),
      totalSize: size,
      partSize: partSize,
      stopped: isStopped,
      onProgress: onProgress,
      openRange: (start, end) => _openRange(id, start, end),
    );
    if (!complete) throw const CloudWorkerException('已停止');
    if (await target.exists()) await target.delete();
    await tmp.rename(target.path);
  }

  Future<int> _outputSize(String id) async {
    final client = _client();
    try {
      final request = await client.openUrl(
        'HEAD',
        base.replace(pathSegments: ['out', id]),
      );
      request.headers.set(tokenHeader, token);
      final response = await request.close().timeout(_timeout);
      await response.drain<void>();
      _check(response.statusCode);
      return response.contentLength;
    } on SocketException {
      throw const CloudWorkerException('无法连接到云端 GPU');
    } on TimeoutException {
      throw const CloudWorkerException('连接云端 GPU 超时');
    } finally {
      client.close(force: true);
    }
  }

  Future<Stream<List<int>>> _openRange(String id, int start, int end) async {
    final client = _client();
    try {
      final request = await client.openUrl(
        'GET',
        base.replace(pathSegments: ['out', id]),
      );
      request.headers.set(tokenHeader, token);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-${end - 1}');
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != HttpStatus.partialContent) {
        await response.drain<void>();
        throw CloudWorkerException(
          '云端返回 ${response.statusCode}',
          statusCode: response.statusCode,
        );
      }
      return response
          .timeout(const Duration(seconds: 60))
          .transform(
            StreamTransformer<List<int>, List<int>>.fromHandlers(
              handleError: (error, stackTrace, sink) {
                client.close(force: true);
                sink.addError(error, stackTrace);
              },
              handleDone: (sink) {
                client.close(force: true);
                sink.close();
              },
            ),
          );
    } catch (e) {
      client.close(force: true);
      if (e is SocketException) {
        throw const CloudWorkerException('无法连接到云端 GPU');
      }
      rethrow;
    }
  }

  @override
  Future<void> drop(String id) => _json('DELETE', ['out', id]);

  @override
  Future<void> shutdown() => _json('POST', ['shutdown']);

  HttpClient _client() =>
      HttpClient()..connectionTimeout = const Duration(seconds: 10);

  Future<Map<String, dynamic>> _json(
    String method,
    List<String> segments, {
    Map<String, dynamic>? body,
    List<int>? raw,
  }) async {
    final client = _client();
    try {
      final request = await client.openUrl(
        method,
        base.replace(pathSegments: segments),
      );
      request.headers.set(tokenHeader, token);
      // Python's http.server can't read chunked bodies, so always send a
      // length.
      final bytes = body != null ? utf8.encode(jsonEncode(body)) : raw;
      if (bytes != null) {
        request.headers.contentType = body != null
            ? ContentType.json
            : ContentType.binary;
        request.contentLength = bytes.length;
        request.add(bytes);
      } else {
        request.contentLength = 0;
      }
      final response = await request.close().timeout(_timeout);
      final text = await utf8.decodeStream(response);
      if (response.statusCode == HttpStatus.conflict) {
        final error = text.isEmpty ? null : jsonDecode(text)['error'];
        throw CloudWorkerException('云端拒绝: $error', statusCode: 409);
      }
      _check(response.statusCode);
      return text.isEmpty ? {} : jsonDecode(text) as Map<String, dynamic>;
    } on SocketException {
      throw const CloudWorkerException('无法连接到云端 GPU');
    } on HttpException {
      throw const CloudWorkerException('与云端 GPU 的连接中断');
    } on TimeoutException {
      throw const CloudWorkerException('连接云端 GPU 超时');
    } finally {
      client.close(force: true);
    }
  }

  void _check(int status) {
    if (status < 200 || status >= 300) {
      throw CloudWorkerException('云端返回 $status', statusCode: status);
    }
  }
}
