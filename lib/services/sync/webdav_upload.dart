import 'dart:io';

import 'package:dio/dio.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

/// Uploads [sourceFilePath] to [remotePath].
///
/// `writeFromFile` first sends OPTIONS to the target, and some servers drop
/// the connection for a path that doesn't exist yet. Sync has already
/// settled auth with earlier requests by then, so a plain PUT goes through.
Future<void> uploadFileToWebDav(
  webdav.Client client,
  String sourceFilePath,
  String remotePath,
) async {
  try {
    await client.writeFromFile(sourceFilePath, remotePath);
  } on DioException catch (e) {
    final file = File(sourceFilePath);
    final length = await file.length();
    final Response<dynamic> resp;
    try {
      resp = await client.c.req(
        client,
        'PUT',
        remotePath,
        data: file.openRead(),
        optionsHandler: (options) =>
            options.headers?['content-length'] = length,
      );
    } on DioException {
      throw e;
    }
    if (!const {200, 201, 204}.contains(resp.statusCode)) rethrow;
  }
}
