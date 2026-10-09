import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/utils/version.dart';
import 'package:url_launcher/url_launcher.dart';

/// The parts of a GitHub `releases/latest` answer the public checker uses.
class PublicRelease {
  const PublicRelease({
    required this.version,
    required this.page,
    this.notes = '',
  });

  final String version;
  final String page;
  final String notes;

  static PublicRelease? tryParse(Object? json) {
    if (json is! Map) return null;
    final tag = json['tag_name'];
    if (tag is! String || !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(tag)) {
      return null;
    }
    final page = json['html_url'];
    final notes = json['body'];
    return PublicRelease(
      version: tag,
      page: page is String && page.startsWith('https://')
          ? page
          : ApiEndpoints.latestApp,
      notes: notes is String ? notes.trim() : '',
    );
  }
}

/// Update check for public Windows builds. They ship a portable zip, which
/// upstream's AutoUpdater can't install, so this only points at the release
/// page.
class PublicUpdate {
  PublicUpdate({
    Future<String> Function()? fetchLatest,
    Future<bool> Function(Uri uri)? launch,
    String? currentVersion,
    this.fetchTimeout = const Duration(seconds: 8),
  }) : _fetchLatest = fetchLatest ?? _fetchFromGitHub,
       _launch = launch ?? _launchExternal,
       currentVersion = currentVersion ?? ApiEndpoints.version;

  static final PublicUpdate instance = PublicUpdate();

  final Future<String> Function() _fetchLatest;
  final Future<bool> Function(Uri uri) _launch;
  final String currentVersion;
  final Duration fetchTimeout;

  // 稍后 holds until the app restarts; a manual check still shows it.
  String? _laterVersion;

  Future<PublicRelease?> fetch() async {
    try {
      final raw = await _fetchLatest().timeout(fetchTimeout);
      return PublicRelease.tryParse(jsonDecode(raw));
    } catch (e) {
      KazumiLogger().w('Update: could not read the latest release', error: e);
      return null;
    }
  }

  bool isNewer(PublicRelease release) {
    try {
      return needUpdate(currentVersion, release.version);
    } on FormatException {
      return false;
    }
  }

  /// Returns false when GitHub couldn't be reached.
  Future<bool> check({bool manual = false}) async {
    final release = await fetch();
    if (release == null) {
      if (manual) KazumiDialog.showToast(message: '检查更新失败，请稍后重试');
      return false;
    }
    if (!isNewer(release)) {
      if (manual) {
        KazumiDialog.showToast(message: '已是最新版本 ($currentVersion)');
      }
      return true;
    }
    if (!manual && release.version == _laterVersion) return true;
    unawaited(
      KazumiDialog.show<void>(
        builder: (context) => PublicUpdateDialog(
          release: release,
          onLater: () {
            _laterVersion = release.version;
            KazumiDialog.dismiss();
          },
          onDownload: () {
            KazumiDialog.dismiss();
            unawaited(open(release));
          },
        ),
      ),
    );
    return true;
  }

  Future<void> open(PublicRelease release) async {
    try {
      if (await _launch(Uri.parse(release.page))) return;
    } catch (e) {
      KazumiLogger().w('Update: could not open the release page', error: e);
    }
    KazumiDialog.showToast(message: '打不开浏览器，请访问 ${release.page}');
  }

  static Future<String> _fetchFromGitHub() async {
    final uri = Uri.parse(ApiEndpoints.latestAppMirror);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(uri);
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.github+json',
      );
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'releases/latest: ${response.statusCode}',
          uri: uri,
        );
      }
      return await response.transform(utf8.decoder).join();
    } finally {
      client.close(force: true);
    }
  }

  static Future<bool> _launchExternal(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);
}

class PublicUpdateDialog extends StatelessWidget {
  const PublicUpdateDialog({
    super.key,
    required this.release,
    required this.onLater,
    required this.onDownload,
  });

  final PublicRelease release;
  final VoidCallback onLater;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('发现新版本 ${release.version}'),
    content: release.notes.isEmpty
        ? null
        : SingleChildScrollView(child: Text(release.notes)),
    actions: [
      TextButton(
        onPressed: onLater,
        child: Text(
          '稍后',
          style: TextStyle(color: Theme.of(context).colorScheme.outline),
        ),
      ),
      FilledButton(onPressed: onDownload, child: const Text('去下载')),
    ],
  );
}
