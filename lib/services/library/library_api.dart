import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kazumi/services/upscale/upscaled_package.dart';

class LibraryEpisode {
  const LibraryEpisode({
    required this.id,
    required this.manifest,
    required this.watchedBy,
  });

  final String id;
  final UpscaledEpisodeManifest manifest;
  final List<String> watchedBy;

  factory LibraryEpisode.fromJson(Map<String, dynamic> json) => LibraryEpisode(
    id: json['id'] as String,
    manifest: UpscaledEpisodeManifest.fromJson(json),
    watchedBy: [for (final name in json['watchedBy'] as List? ?? []) '$name'],
  );
}

class LibraryMember {
  const LibraryMember({
    required this.deviceId,
    required this.name,
    required this.state,
    required this.episodeId,
  });

  final String deviceId;
  final String name;
  final String state;
  final String? episodeId;

  bool get watching => state == 'watching';

  factory LibraryMember.fromJson(Map<String, dynamic> json) => LibraryMember(
    deviceId: json['deviceId'] as String? ?? '',
    name: json['name'] as String? ?? '',
    state: json['state'] as String? ?? 'idle',
    episodeId: json['episodeId'] as String?,
  );
}

class LibrarySelection {
  const LibrarySelection({
    required this.seq,
    required this.episodeId,
    required this.by,
    required this.byDeviceId,
  });

  final int seq;
  final String episodeId;
  final String by;
  final String byDeviceId;
}

class LibraryRoomState {
  const LibraryRoomState({required this.members, this.selection});

  final List<LibraryMember> members;
  final LibrarySelection? selection;

  static const empty = LibraryRoomState(members: []);

  factory LibraryRoomState.fromJson(Map<String, dynamic> json) {
    final selection = json['selection'] as Map<String, dynamic>?;
    return LibraryRoomState(
      members: [
        for (final m in json['members'] as List? ?? [])
          LibraryMember.fromJson(m as Map<String, dynamic>),
      ],
      selection: selection == null
          ? null
          : LibrarySelection(
              seq: selection['seq'] as int? ?? 0,
              episodeId: selection['episodeId'] as String? ?? '',
              by: selection['by'] as String? ?? '',
              byDeviceId: selection['byDeviceId'] as String? ?? '',
            ),
    );
  }
}

class LibraryConfig {
  const LibraryConfig({
    required this.syncPlayEndPoint,
    required this.syncPlayTls,
    required this.room,
  });

  final String syncPlayEndPoint;
  final bool syncPlayTls;
  final String room;
}

class LibraryException implements Exception {
  const LibraryException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Client for the shared episode library on the owner's server.
class LibraryApi {
  LibraryApi(String server, this.key) : baseUri = normalizeServer(server);

  final Uri baseUri;
  final String key;

  static Uri normalizeServer(String server) {
    var value = server.trim();
    if (!value.contains('://')) value = 'https://$value';
    final uri = Uri.parse(value);
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    );
  }

  /// Media players and the download manager can't always send custom
  /// headers, so file URLs carry the key as a query parameter.
  Uri videoUri(String id) => baseUri.replace(
    path: '/episodes/$id/$upscaledVideoFileName',
    queryParameters: {'token': key},
  );

  Uri danmakuUri(String id) => baseUri.replace(
    path: '/episodes/$id/$upscaledDanmakuFileName',
    queryParameters: {'token': key},
  );

  bool ownsUrl(String url) => url.startsWith(baseUri.toString());

  /// Trades a short invite code for the library key.
  static Future<String> redeem(String server, String code) async {
    final api = LibraryApi(server, '');
    try {
      final json = await api._json('POST', '/api/redeem', body: {'code': code});
      final key = json['key'] as String? ?? '';
      if (key.isEmpty) throw const LibraryException('服务器没有返回密钥');
      return key;
    } on LibraryException catch (e) {
      throw switch (e.statusCode) {
        HttpStatus.notFound => const LibraryException('邀请码不对或已过期，请让对方重新生成'),
        HttpStatus.tooManyRequests => const LibraryException('尝试次数太多，请一分钟后再试'),
        _ => e,
      };
    }
  }

  Future<({String code, DateTime expiresAt})> createInvite() async {
    final json = await _json('POST', '/api/invites');
    return (
      code: json['code'] as String,
      expiresAt: DateTime.parse(json['expiresAt'] as String).toLocal(),
    );
  }

  Future<LibraryConfig> config() async {
    final json = await _json('GET', '/api/config');
    return LibraryConfig(
      syncPlayEndPoint: json['syncplay'] as String? ?? '',
      syncPlayTls: json['syncplayTls'] as bool? ?? false,
      room: json['room'] as String? ?? '',
    );
  }

  Future<List<LibraryEpisode>> episodes() async {
    final json = await _json('GET', '/api/episodes');
    final episodes = <LibraryEpisode>[];
    for (final e in json['episodes'] as List? ?? []) {
      try {
        episodes.add(LibraryEpisode.fromJson(e as Map<String, dynamic>));
      } on FormatException {
        // Entries from a newer manifest version are skipped, not fatal.
      }
    }
    return episodes;
  }

  Future<LibraryRoomState> heartbeat({
    required String deviceId,
    required String name,
    required String state,
    String? episodeId,
  }) async {
    final json = await _json(
      'POST',
      '/api/room/heartbeat',
      body: {
        'deviceId': deviceId,
        'name': name,
        'state': state,
        'episodeId': episodeId,
      },
    );
    return LibraryRoomState.fromJson(json);
  }

  Future<LibraryRoomState> select({
    required String deviceId,
    required String name,
    required String episodeId,
  }) async {
    final json = await _json(
      'POST',
      '/api/room/select',
      body: {'deviceId': deviceId, 'name': name, 'episodeId': episodeId},
    );
    return LibraryRoomState.fromJson(json);
  }

  Future<void> markWatched(String id, String name) async {
    await _json('POST', '/api/episodes/$id/watched', body: {'name': name});
  }

  Future<List<int>> download(Uri uri) async {
    final client = _client();
    try {
      final request = await client.getUrl(uri);
      final response = await request.close().timeout(_responseTimeout);
      _check(response);
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
      }
      return bytes;
    } on SocketException {
      throw const LibraryException('无法连接到片库服务器');
    } on TimeoutException {
      throw const LibraryException('连接片库服务器超时');
    } finally {
      client.close(force: true);
    }
  }

  Future<int> uploadedSize(String id, String file) async {
    final json = await _json('GET', '/api/upload/$id/$file');
    return json['size'] as int? ?? 0;
  }

  /// Streams [source] from [offset]. The server keeps whatever arrived, so a
  /// dropped upload resumes from [uploadedSize].
  Future<int> upload(
    String id,
    String file,
    File source, {
    required int offset,
    void Function(int sentBytes)? onProgress,
  }) async {
    final client = _client();
    try {
      final uri = baseUri.replace(
        path: '/api/upload/$id/$file',
        queryParameters: {'offset': '$offset'},
      );
      final request = await client.openUrl('PUT', uri);
      request.headers.set(lanShareTokenHeader, key);
      request.headers.contentType = ContentType.binary;
      final length = await source.length();
      request.contentLength = length - offset;
      var sent = offset;
      await request.addStream(
        source.openRead(offset).map((chunk) {
          sent += chunk.length;
          onProgress?.call(sent);
          return chunk;
        }),
      );
      final response = await request.close().timeout(_responseTimeout);
      final body = await utf8.decodeStream(response);
      if (response.statusCode == HttpStatus.conflict) {
        throw LibraryException('上传位置不一致', statusCode: response.statusCode);
      }
      _check(response);
      return (jsonDecode(body) as Map<String, dynamic>)['size'] as int? ?? 0;
    } on SocketException {
      throw const LibraryException('上传中断');
    } on HttpException {
      throw const LibraryException('上传中断');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> commit(String id, UpscaledEpisodeManifest manifest) async {
    await _json('POST', '/api/upload/$id/commit', body: manifest.toJson());
  }

  static const _responseTimeout = Duration(seconds: 30);

  HttpClient _client() =>
      HttpClient()..connectionTimeout = const Duration(seconds: 10);

  Future<Map<String, dynamic>> _json(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final client = _client();
    try {
      final request = await client.openUrl(method, baseUri.replace(path: path));
      request.headers.set(lanShareTokenHeader, key);
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(_responseTimeout);
      final text = await utf8.decodeStream(response);
      _check(response);
      return text.isEmpty ? {} : jsonDecode(text) as Map<String, dynamic>;
    } on SocketException {
      throw const LibraryException('无法连接到片库服务器');
    } on TimeoutException {
      throw const LibraryException('连接片库服务器超时');
    } finally {
      client.close(force: true);
    }
  }

  void _check(HttpClientResponse response) {
    final status = response.statusCode;
    if (status == HttpStatus.unauthorized) {
      throw LibraryException('邀请已失效，请重新打开邀请链接', statusCode: status);
    }
    if (status < 200 || status >= 300) {
      throw LibraryException('片库服务器返回错误 $status', statusCode: status);
    }
  }
}
