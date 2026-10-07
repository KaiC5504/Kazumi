import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show appBuildName, appBuildNumber;
import 'package:kazumi/bean/dialog/dialog.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:url_launcher/url_launcher.dart';

/// What `latest.json` on the HK box says about the newest TestFlight build.
class AppRelease {
  const AppRelease({
    required this.build,
    required this.version,
    this.minBuild = 0,
    this.notes = '',
    this.requiredSince,
  });

  final int build;
  final String version;

  /// Builds below this have to update before the app can be used.
  final int minBuild;
  final String notes;

  /// When [minBuild] was last raised.
  final DateTime? requiredSince;

  String get label => '$version ($build)';

  static AppRelease? tryParse(Object? json) {
    if (json is! Map) return null;
    final build = json['build'];
    final version = json['version'];
    if (build is! int || build <= 0 || version is! String || version.isEmpty) {
      return null;
    }
    final minBuild = json['minBuild'];
    final notes = json['notes'];
    final requiredSince = json['requiredSince'];
    return AppRelease(
      build: build,
      version: version,
      minBuild: minBuild is int ? minBuild : 0,
      notes: notes is String ? notes.trim() : '',
      requiredSince: requiredSince is String
          ? DateTime.tryParse(requiredSince)
          : null,
    );
  }
}

enum UpdateNeed { none, optional, required }

/// Apple can still be processing a build when it's published, so a required
/// update only locks the app once TestFlight has had time to offer it.
const requiredUpdateGrace = Duration(minutes: 30);

UpdateNeed updateNeedFor(AppRelease release, int currentBuild, DateTime now) {
  if (currentBuild <= 0 || release.build <= currentBuild) {
    return UpdateNeed.none;
  }
  if (currentBuild < release.minBuild) {
    final since = release.requiredSince;
    if (since == null || !now.isBefore(since.add(requiredUpdateGrace))) {
      return UpdateNeed.required;
    }
  }
  return UpdateNeed.optional;
}

/// Update prompt for the fork's TestFlight builds; upstream's checker looks at
/// Predidit's GitHub releases instead.
class TestflightUpdate {
  TestflightUpdate({
    Future<String> Function()? fetchLatest,
    Future<bool> Function(Uri uri)? launch,
    DateTime Function()? clock,
    int? currentBuild,
    bool? isIOS,
    this.fetchTimeout = const Duration(seconds: 8),
  }) : _fetchLatest = fetchLatest ?? _fetchFromServer,
       _launch = launch ?? _launchExternal,
       _clock = clock ?? DateTime.now,
       currentBuild = currentBuild ?? buildNumber,
       _isIOS = isIOS ?? Platform.isIOS;

  static final TestflightUpdate instance = TestflightUpdate();

  static final latestUri = Uri.parse('https://hk.kaic5504.com/app/latest.json');
  static final testflightUri = Uri.parse(
    'itms-beta://beta.itunes.apple.com/v1/app/6818711929',
  );
  static final testflightWebUri = Uri.parse(
    'https://beta.itunes.apple.com/v1/app/6818711929',
  );

  /// Codemagic passes `--build-number`; local builds have none and never prompt.
  static final int buildNumber = int.tryParse(appBuildNumber ?? '') ?? 0;

  static String get versionLabel {
    final name = appBuildName ?? '0.0.0';
    return buildNumber > 0 ? '$name ($buildNumber)' : name;
  }

  static bool get replacesUpstream => true;

  static const _recheckAfter = Duration(minutes: 30);

  final Future<String> Function() _fetchLatest;
  final Future<bool> Function(Uri uri) _launch;
  final DateTime Function() _clock;
  final bool _isIOS;
  final int currentBuild;
  final Duration fetchTimeout;

  AppLifecycleListener? _lifecycle;
  DateTime? _lastCheck;
  KazumiDialogHandle<void>? _dialog;
  UpdateNeed _shownNeed = UpdateNeed.none;
  AppRelease? _shownRelease;
  int? _postponedBuild;

  @visibleForTesting
  UpdateNeed get shownNeed => _dialog == null ? UpdateNeed.none : _shownNeed;

  Future<AppRelease?> fetch() async {
    try {
      final raw = await _fetchLatest().timeout(fetchTimeout);
      return AppRelease.tryParse(jsonDecode(raw));
    } catch (e) {
      KazumiLogger().w('Update: could not read latest.json', error: e);
      return null;
    }
  }

  /// Returns false when the server couldn't be reached.
  Future<bool> check({bool manual = false}) async {
    if (_isIOS) _lifecycle ??= AppLifecycleListener(onResume: _onResume);
    _lastCheck = _clock();
    final release = await fetch();
    if (release == null) {
      if (manual) KazumiDialog.showToast(message: '检查更新失败，请稍后重试');
      return false;
    }
    if (!_isIOS) {
      if (manual) {
        KazumiDialog.showToast(message: 'iPhone / iPad 最新版本 ${release.label}');
      }
      return true;
    }
    final need = updateNeedFor(release, currentBuild, _clock());
    if (need == UpdateNeed.none) {
      if (manual) KazumiDialog.showToast(message: '已是最新版本 ($versionLabel)');
      return true;
    }
    if (need == UpdateNeed.optional &&
        !manual &&
        _postponedBuild == release.build) {
      return true;
    }
    _show(release, need);
    return true;
  }

  void _onResume() {
    final last = _lastCheck;
    if (last != null && _clock().difference(last) < _recheckAfter) return;
    unawaited(check());
  }

  void _show(AppRelease release, UpdateNeed need) {
    final open = _dialog;
    if (open != null) {
      final upgrade =
          need == UpdateNeed.required && _shownNeed != UpdateNeed.required;
      final newer = release.build > (_shownRelease?.build ?? 0);
      if (!upgrade && !newer) return;
      _dialog = null;
      open.dismiss();
    }
    final handle = KazumiDialogHandle<void>();
    _dialog = handle;
    _shownNeed = need;
    _shownRelease = release;
    final required = need == UpdateNeed.required;
    var built = false;
    unawaited(
      KazumiDialog.show<void>(
        handle: handle,
        clickMaskDismiss: !required,
        onDismiss: () {
          if (_dialog != handle) return;
          _dialog = null;
          // Something else popped the route (a stray dismiss, a navigation
          // reset). A required update has to stay up.
          if (required && built) {
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => _show(release, need),
            );
          }
        },
        builder: (context) {
          built = true;
          return UpdateDialog(
            release: release,
            required: required,
            onLater: () {
              _postponedBuild = release.build;
              handle.dismiss();
            },
            onUpdate: () async {
              await openTestflight();
              if (!required) {
                _postponedBuild = release.build;
                handle.dismiss();
              }
            },
          );
        },
      ),
    );
  }

  Future<void> openTestflight() async {
    try {
      if (await _launch(testflightUri)) return;
    } catch (e) {
      KazumiLogger().w('Update: itms-beta link failed', error: e);
    }
    try {
      if (await _launch(testflightWebUri)) return;
    } catch (e) {
      KazumiLogger().w('Update: TestFlight web link failed', error: e);
    }
    KazumiDialog.showToast(message: '打不开 TestFlight，请手动打开并更新 Kazumi');
  }

  void dispose() {
    _lifecycle?.dispose();
    _lifecycle = null;
  }

  static Future<String> _fetchFromServer() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(latestUri);
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'latest.json: ${response.statusCode}',
          uri: latestUri,
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

class UpdateDialog extends StatelessWidget {
  const UpdateDialog({
    super.key,
    required this.release,
    required this.required,
    required this.onLater,
    required this.onUpdate,
  });

  final AppRelease release;
  final bool required;
  final VoidCallback onLater;
  final VoidCallback onUpdate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: !required,
      child: AlertDialog(
        title: Text(
          required ? '需要更新到 ${release.label}' : '有新版本 ${release.label}',
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (required) const Text('这个版本需要更新后才能继续使用。'),
              if (required && release.notes.isNotEmpty)
                const SizedBox(height: 8),
              if (release.notes.isNotEmpty) Text(release.notes),
            ],
          ),
        ),
        actions: [
          if (!required)
            TextButton(
              onPressed: onLater,
              child: Text(
                '稍后',
                style: TextStyle(color: theme.colorScheme.outline),
              ),
            ),
          FilledButton(onPressed: onUpdate, child: const Text('去更新')),
        ],
      ),
    );
  }
}
