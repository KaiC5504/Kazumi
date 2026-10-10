import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/sync/webdav_upload.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

void main() {
  late HttpServer server;
  late Directory tmp;
  late File source;
  final stored = <String, String>{};
  var dropOptions = false;
  var putStatus = HttpStatus.created;

  setUp(() async {
    stored.clear();
    dropOptions = false;
    putStatus = HttpStatus.created;
    tmp = await Directory.systemTemp.createTemp('kazumi_webdav_upload');
    source = File('${tmp.path}/snapshot.json')..writeAsStringSync('{"v":1}');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      switch (request.method) {
        case 'OPTIONS' when dropOptions:
          // Like the reporter's server: no response, connection gone.
          (await request.response.detachSocket()).destroy();
        case 'PUT':
          stored[request.uri.path] = await request
              .cast<List<int>>()
              .transform(const SystemEncoding().decoder)
              .join();
          request.response.statusCode = putStatus;
          await request.response.close();
        default:
          request.response.statusCode = HttpStatus.ok;
          await request.response.close();
      }
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await tmp.delete(recursive: true);
  });

  webdav.Client client() =>
      webdav.newClient('http://127.0.0.1:${server.port}/dav/');

  test('uploads as before when the server answers OPTIONS', () async {
    await uploadFileToWebDav(client(), source.path, '/a.json.cache');
    expect(stored['/dav/a.json.cache'], '{"v":1}');
  });

  test('a server that drops OPTIONS still gets the file', () async {
    dropOptions = true;
    await uploadFileToWebDav(client(), source.path, '/a.json.cache');
    expect(stored['/dav/a.json.cache'], '{"v":1}');
  });

  test('a refused PUT still fails the sync', () async {
    dropOptions = true;
    putStatus = HttpStatus.forbidden;
    await expectLater(
      uploadFileToWebDav(client(), source.path, '/a.json.cache'),
      throwsA(isA<DioException>()),
    );
  });
}
