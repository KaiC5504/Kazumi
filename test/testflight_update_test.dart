import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/bean/dialog/dialog.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/services/update/testflight_update.dart';

final now = DateTime.utc(2026, 10, 6, 12);

String latest({
  int build = 15,
  String version = '3.0.0',
  int? minBuild,
  DateTime? requiredSince,
  String notes = '',
}) => jsonEncode({
  'build': build,
  'version': version,
  if (minBuild != null) 'minBuild': minBuild,
  if (requiredSince != null) 'requiredSince': requiredSince.toIso8601String(),
  'notes': notes,
});

Future<void> pumpApp(WidgetTester tester) => tester.pumpWidget(
  MaterialApp(
    navigatorKey: rootNavigatorKey,
    scaffoldMessengerKey: rootScaffoldMessengerKey,
    navigatorObservers: [KazumiDialog.observer],
    home: const Scaffold(body: Text('home')),
  ),
);

void main() {
  group('AppRelease.tryParse', () {
    test('reads every field', () {
      final release = AppRelease.tryParse(
        jsonDecode(latest(minBuild: 15, requiredSince: now, notes: ' 一起看修复 ')),
      )!;
      expect(release.build, 15);
      expect(release.version, '3.0.0');
      expect(release.minBuild, 15);
      expect(release.requiredSince, now);
      expect(release.notes, '一起看修复');
      expect(release.label, '3.0.0 (15)');
    });

    test('a missing minBuild means nothing is required', () {
      final release = AppRelease.tryParse(jsonDecode(latest()))!;
      expect(release.minBuild, 0);
      expect(release.requiredSince, isNull);
    });

    test('rejects anything without a usable build and version', () {
      expect(AppRelease.tryParse(null), isNull);
      expect(AppRelease.tryParse([15]), isNull);
      expect(AppRelease.tryParse({'version': '3.0.0'}), isNull);
      expect(AppRelease.tryParse({'build': '15', 'version': '3.0.0'}), isNull);
      expect(AppRelease.tryParse({'build': 0, 'version': '3.0.0'}), isNull);
      expect(AppRelease.tryParse({'build': 15, 'version': ''}), isNull);
    });
  });

  group('updateNeedFor', () {
    AppRelease release({int build = 15, int minBuild = 0, DateTime? since}) =>
        AppRelease(
          build: build,
          version: '3.0.0',
          minBuild: minBuild,
          requiredSince: since,
        );

    test('same or newer build needs nothing', () {
      expect(updateNeedFor(release(), 15, now), UpdateNeed.none);
      expect(updateNeedFor(release(), 16, now), UpdateNeed.none);
    });

    test('a build without a number (local or debug) never prompts', () {
      expect(updateNeedFor(release(minBuild: 15), 0, now), UpdateNeed.none);
    });

    test('older build gets the optional prompt when nothing is required', () {
      expect(updateNeedFor(release(), 14, now), UpdateNeed.optional);
    });

    test('below minBuild is required once the grace period is over', () {
      final old = now.subtract(const Duration(hours: 1));
      expect(
        updateNeedFor(release(minBuild: 15, since: old), 14, now),
        UpdateNeed.required,
      );
    });

    test('required acts as optional while Apple may still be processing', () {
      final fresh = now.subtract(const Duration(minutes: 10));
      expect(
        updateNeedFor(release(minBuild: 15, since: fresh), 14, now),
        UpdateNeed.optional,
      );
      expect(
        updateNeedFor(
          release(minBuild: 15, since: fresh),
          14,
          fresh.add(requiredUpdateGrace),
        ),
        UpdateNeed.required,
      );
    });

    test('required without a timestamp is required straight away', () {
      expect(
        updateNeedFor(release(minBuild: 15), 14, now),
        UpdateNeed.required,
      );
    });

    test('a required 16 then an optional 17 still forces someone on 15', () {
      final r = release(
        build: 17,
        minBuild: 16,
        since: now.subtract(const Duration(days: 2)),
      );
      expect(updateNeedFor(r, 15, now), UpdateNeed.required);
      expect(updateNeedFor(r, 16, now), UpdateNeed.optional);
      expect(updateNeedFor(r, 17, now), UpdateNeed.none);
    });
  });

  test('deep links go straight to Kazumi in TestFlight', () {
    expect(
      TestflightUpdate.testflightUri.toString(),
      'itms-beta://beta.itunes.apple.com/v1/app/6818711929',
    );
    expect(
      TestflightUpdate.testflightWebUri.toString(),
      'https://beta.itunes.apple.com/v1/app/6818711929',
    );
    expect(
      TestflightUpdate.latestUri.toString(),
      'https://hk.kaic5504.com/app/latest.json',
    );
  });

  group('prompt', () {
    late String body;
    late List<Uri> launched;
    late bool launchWorks;

    TestflightUpdate updater({int currentBuild = 14, bool isIOS = true}) =>
        TestflightUpdate(
          fetchLatest: () async => body,
          launch: (uri) async {
            launched.add(uri);
            return launchWorks;
          },
          clock: () => now,
          currentBuild: currentBuild,
          isIOS: isIOS,
        );

    setUp(() {
      body = latest();
      launched = [];
      launchWorks = true;
    });

    testWidgets('optional update offers 稍后 and 去更新', (tester) async {
      await pumpApp(tester);
      final u = updater();
      await u.check();
      await tester.pumpAndSettle();

      expect(find.text('有新版本 3.0.0 (15)'), findsOneWidget);
      expect(find.text('稍后'), findsOneWidget);
      expect(find.text('去更新'), findsOneWidget);
      expect(u.shownNeed, UpdateNeed.optional);

      await tester.tap(find.text('稍后'));
      await tester.pumpAndSettle();
      expect(find.text('有新版本 3.0.0 (15)'), findsNothing);
      expect(u.shownNeed, UpdateNeed.none);
      u.dispose();
    });

    testWidgets('稍后 holds for this launch, a manual check still shows it', (
      tester,
    ) async {
      await pumpApp(tester);
      final u = updater();
      await u.check();
      await tester.pumpAndSettle();
      await tester.tap(find.text('稍后'));
      await tester.pumpAndSettle();

      await u.check();
      await tester.pumpAndSettle();
      expect(find.text('有新版本 3.0.0 (15)'), findsNothing);

      await u.check(manual: true);
      await tester.pumpAndSettle();
      expect(find.text('有新版本 3.0.0 (15)'), findsOneWidget);
      u.dispose();
    });

    testWidgets(
      '去更新 opens TestFlight on Kazumi and closes an optional prompt',
      (tester) async {
        await pumpApp(tester);
        final u = updater();
        await u.check();
        await tester.pumpAndSettle();

        await tester.tap(find.text('去更新'));
        await tester.pumpAndSettle();
        expect(launched, [TestflightUpdate.testflightUri]);
        expect(find.text('有新版本 3.0.0 (15)'), findsNothing);
        u.dispose();
      },
    );

    testWidgets('falls back to the web link when itms-beta cannot open', (
      tester,
    ) async {
      await pumpApp(tester);
      launchWorks = false;
      final u = updater();
      await u.openTestflight();
      await tester.pump();
      expect(launched, [
        TestflightUpdate.testflightUri,
        TestflightUpdate.testflightWebUri,
      ]);
      expect(find.text('打不开 TestFlight，请手动打开并更新 Kazumi'), findsOneWidget);
      u.dispose();
    });

    testWidgets('required update has no 稍后 and cannot be closed', (
      tester,
    ) async {
      body = latest(
        minBuild: 15,
        requiredSince: now.subtract(const Duration(hours: 2)),
        notes: '修复一起看',
      );
      await pumpApp(tester);
      final u = updater();
      await u.check();
      await tester.pumpAndSettle();

      expect(find.text('需要更新到 3.0.0 (15)'), findsOneWidget);
      expect(find.text('修复一起看'), findsOneWidget);
      expect(find.text('稍后'), findsNothing);
      expect(u.shownNeed, UpdateNeed.required);

      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.text('需要更新到 3.0.0 (15)'), findsOneWidget);

      await rootNavigatorKey.currentState!.maybePop();
      await tester.pumpAndSettle();
      expect(find.text('需要更新到 3.0.0 (15)'), findsOneWidget);

      await tester.tap(find.text('去更新'));
      await tester.pumpAndSettle();
      expect(launched, [TestflightUpdate.testflightUri]);
      expect(find.text('需要更新到 3.0.0 (15)'), findsOneWidget);
      u.dispose();
    });

    testWidgets('a stray dismiss brings a required prompt straight back', (
      tester,
    ) async {
      body = latest(minBuild: 15);
      await pumpApp(tester);
      final u = updater();
      await u.check();
      await tester.pumpAndSettle();

      KazumiDialog.dismiss();
      await tester.pumpAndSettle();
      expect(find.text('需要更新到 3.0.0 (15)'), findsOneWidget);
      u.dispose();
    });

    testWidgets('a required check replaces an open optional prompt', (
      tester,
    ) async {
      await pumpApp(tester);
      final u = updater();
      await u.check();
      await tester.pumpAndSettle();
      expect(find.text('有新版本 3.0.0 (15)'), findsOneWidget);

      body = latest(minBuild: 15);
      await u.check();
      await tester.pumpAndSettle();
      expect(find.text('有新版本 3.0.0 (15)'), findsNothing);
      expect(find.text('需要更新到 3.0.0 (15)'), findsOneWidget);
      expect(find.byType(UpdateDialog), findsOneWidget);
      u.dispose();
    });

    testWidgets('a second check does not stack another dialog', (tester) async {
      await pumpApp(tester);
      final u = updater();
      await u.check();
      await u.check(manual: true);
      await tester.pumpAndSettle();
      expect(find.byType(UpdateDialog), findsOneWidget);
      u.dispose();
    });

    testWidgets('up to date: no prompt, manual check says so', (tester) async {
      await pumpApp(tester);
      final u = updater(currentBuild: 15);
      await u.check();
      await tester.pumpAndSettle();
      expect(find.byType(UpdateDialog), findsNothing);

      await u.check(manual: true);
      await tester.pump();
      expect(find.textContaining('已是最新版本'), findsOneWidget);
      u.dispose();
    });

    testWidgets('server unreachable or broken never locks anyone out', (
      tester,
    ) async {
      await pumpApp(tester);
      for (final bad in <Future<String> Function()>[
        () async => throw const SocketExceptionLike(),
        () async => 'not json',
        () async => '{"build": "15"}',
        () => Completer<String>().future,
      ]) {
        final u = TestflightUpdate(
          fetchLatest: bad,
          clock: () => now,
          currentBuild: 14,
          isIOS: true,
          fetchTimeout: const Duration(milliseconds: 50),
        );
        final pending = u.check();
        await tester.pump(const Duration(seconds: 1));
        expect(await pending, isFalse);
        expect(find.byType(UpdateDialog), findsNothing);
        u.dispose();
      }
    });

    testWidgets('PC build never prompts; manual check names the iOS build', (
      tester,
    ) async {
      body = latest(minBuild: 15);
      await pumpApp(tester);
      final u = updater(currentBuild: 0, isIOS: false);
      await u.check();
      await tester.pumpAndSettle();
      expect(find.byType(UpdateDialog), findsNothing);

      await u.check(manual: true);
      await tester.pump();
      expect(find.text('iPhone / iPad 最新版本 3.0.0 (15)'), findsOneWidget);
      u.dispose();
    });
  });
}

class SocketExceptionLike implements Exception {
  const SocketExceptionLike();
}
