import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/upscale/upscaled_package.dart';

class SharedUpscaledEpisode {
  const SharedUpscaledEpisode({
    required this.manifest,
    required this.videoPath,
    this.danmakuPath,
  });

  final UpscaledEpisodeManifest manifest;
  final String videoPath;
  final String? danmakuPath;
}

String generateLanShareToken() {
  final random = Random.secure();
  return List.generate(6, (_) => random.nextInt(10)).join();
}

/// Serves baked episodes to other Kazumi devices on the same network.
class LanShareServer {
  LanShareServer(this._episodes);

  final List<SharedUpscaledEpisode> Function() _episodes;
  HttpServer? _server;
  String _token = '';

  bool get isRunning => _server != null;

  Future<void> start(String token) async {
    await stop();
    _token = token;
    _server = await HttpServer.bind(InternetAddress.anyIPv4, lanSharePort);
    _server!.listen(
      _handle,
      onError: (Object e) {
        KazumiLogger().w('LanShareServer: request stream error', error: e);
      },
    );
    KazumiLogger().i('LanShareServer: listening on port $lanSharePort');
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  static Future<List<String>> localAddresses() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    final addresses = <String>[];
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (!address.isLinkLocal) addresses.add(address.address);
      }
    }
    // Home Wi-Fi is almost always 192.168.x; VPN, WSL and the Windows hotspot
    // (192.168.137.x) adapters are listed too but unreachable from an iPad.
    int rank(String a) {
      if (a.startsWith('192.168.137.')) return 2;
      if (a.startsWith('192.168.')) return 0;
      return a.startsWith('10.') ? 1 : 3;
    }

    addresses.sort((a, b) => rank(a).compareTo(rank(b)));
    return addresses;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final token =
          request.headers.value(lanShareTokenHeader) ??
          request.uri.queryParameters['token'];
      if (token != _token) {
        response.statusCode = HttpStatus.unauthorized;
        await response.close();
        return;
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        await response.close();
        return;
      }

      final segments = request.uri.pathSegments;
      if (segments.length == 2 &&
          segments[0] == 'api' &&
          segments[1] == 'episodes') {
        response.headers.contentType = ContentType.json;
        response.write(
          jsonEncode({
            'episodes': _episodes()
                .map((e) => {...e.manifest.toJson(), 'id': e.manifest.shareId})
                .toList(),
          }),
        );
        await response.close();
        return;
      }

      if (segments.length == 3 && segments[0] == 'episodes') {
        final episode = _find(segments[1]);
        final filePath = switch (segments[2]) {
          upscaledVideoFileName => episode?.videoPath,
          upscaledDanmakuFileName => episode?.danmakuPath,
          _ => null,
        };
        if (filePath == null || !await File(filePath).exists()) {
          response.statusCode = HttpStatus.notFound;
          await response.close();
          return;
        }
        await _serveFile(request, File(filePath));
        return;
      }

      response.statusCode = HttpStatus.notFound;
      await response.close();
    } catch (e) {
      KazumiLogger().w('LanShareServer: request failed', error: e);
      try {
        await response.close();
      } catch (_) {}
    }
  }

  SharedUpscaledEpisode? _find(String shareId) {
    for (final episode in _episodes()) {
      if (episode.manifest.shareId == shareId) return episode;
    }
    return null;
  }

  /// Range support lets the receiving download manager resume transfers.
  Future<void> _serveFile(HttpRequest request, File file) async {
    final response = request.response;
    final length = await file.length();
    var start = 0;
    var end = length - 1;

    final range = request.headers.value(HttpHeaders.rangeHeader);
    final match = range == null
        ? null
        : RegExp(r'bytes=(\d*)-(\d*)').firstMatch(range);
    if (match != null) {
      final rangeStart = int.tryParse(match.group(1)!);
      final rangeEnd = int.tryParse(match.group(2)!);
      if (rangeStart != null) {
        start = rangeStart;
        if (rangeEnd != null) end = min(rangeEnd, length - 1);
      } else if (rangeEnd != null) {
        start = max(0, length - rangeEnd);
      }
      if (start >= length || start > end) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
        await response.close();
        return;
      }
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/$length',
      );
    }

    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    response.headers.contentLength = end - start + 1;
    response.headers.contentType = file.path.endsWith('.json')
        ? ContentType.json
        : ContentType('video', 'mp4');
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }
    await response.addStream(file.openRead(start, end + 1));
    await response.close();
  }
}

class LanShareClient {
  LanShareClient(String address, this.token) : baseUri = _normalize(address);

  final Uri baseUri;
  final String token;

  static Uri _normalize(String address) {
    var value = address.trim();
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      value = 'http://$value';
    }
    final uri = Uri.parse(value);
    return uri.hasPort && uri.port != 80
        ? uri.replace(path: '')
        : uri.replace(port: lanSharePort, path: '');
  }

  Uri videoUri(UpscaledEpisodeManifest manifest) => baseUri.replace(
    path: '/episodes/${manifest.shareId}/$upscaledVideoFileName',
  );

  Uri danmakuUri(UpscaledEpisodeManifest manifest) => baseUri.replace(
    path: '/episodes/${manifest.shareId}/$upscaledDanmakuFileName',
  );

  Future<List<UpscaledEpisodeManifest>> listEpisodes() async {
    final body = await _get(baseUri.replace(path: '/api/episodes'));
    final json = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
    return (json['episodes'] as List)
        .map((e) => UpscaledEpisodeManifest.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<int>> download(Uri uri) => _get(uri);

  Future<List<int>> _get(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.getUrl(uri);
      request.headers.set(lanShareTokenHeader, token);
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode == HttpStatus.unauthorized) {
        throw const LanShareException('连接码错误');
      }
      if (response.statusCode != HttpStatus.ok) {
        throw LanShareException('电脑返回错误 ${response.statusCode}');
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
      }
      return bytes;
    } on SocketException {
      throw const LanShareException('无法连接到电脑，请确认两台设备在同一 Wi-Fi 且电脑端已开启共享');
    } on TimeoutException {
      throw const LanShareException('连接电脑超时');
    } finally {
      client.close(force: true);
    }
  }
}

class LanShareException implements Exception {
  const LanShareException(this.message);
  final String message;

  @override
  String toString() => message;
}
