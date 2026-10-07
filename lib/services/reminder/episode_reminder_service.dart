import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:kazumi/modules/bangumi/episode_item.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/reminder/reminder_planner.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Schedules one local notification per upcoming episode of every 在看
/// show. Runs on the phone only; no server involved.
class EpisodeReminderService {
  EpisodeReminderService._();
  static final EpisodeReminderService instance = EpisodeReminderService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  DateTime? _lastRun;
  Future<void>? _running;
  Timer? _soon;
  void Function(int bangumiId)? onOpen;

  /// Set when the OS refused notifications, so settings can point at the
  /// system page instead of a switch that silently does nothing.
  final permissionDenied = ValueNotifier<bool>(false);

  bool get _supported => Platform.isIOS || Platform.isAndroid;

  Future<void> _init() async {
    if (_ready) return;
    tzdata.initializeTimeZones();
    final local = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(local.identifier));
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: (r) => _open(r.payload),
    );
    _ready = true;
    AppLifecycleListener(
      onResume: () {
        final last = _lastRun;
        if (last == null ||
            DateTime.now().difference(last) > const Duration(hours: 6)) {
          unawaited(refresh());
        }
      },
    );
  }

  void _open(String? payload) {
    final id = int.tryParse(payload ?? '');
    if (id != null) onOpen?.call(id);
  }

  Future<void> handleLaunchTap() async {
    if (!_supported) return;
    try {
      await _init();
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp ?? false) {
        _open(details!.notificationResponse?.payload);
      }
    } catch (e) {
      KazumiLogger().w('Reminders: launch tap check failed', error: e);
    }
  }

  Future<void> openSystemSettings() async {
    try {
      await _init();
      await _plugin.openAppNotificationSettings();
    } catch (e) {
      KazumiLogger().w('Reminders: open settings failed', error: e);
    }
  }

  void refreshSoon() {
    _soon?.cancel();
    _soon = Timer(const Duration(seconds: 3), () => unawaited(refresh()));
  }

  Future<void> refresh() =>
      _running ??= _refresh().whenComplete(() => _running = null);

  Future<void> _refresh() async {
    if (!_supported) return;
    try {
      await _init();
      _lastRun = DateTime.now();
      await _cancelOurs();
      if (!GStorage.getSetting(SettingsKeys.episodeReminders)) return;
      final watching = GStorage.collectibles.values
          .where((c) => c.type == CollectType.watching.value)
          .toList();
      if (watching.isEmpty) return;
      final shows = <ReminderShow>[];
      for (final c in watching) {
        final item = c.bangumiItem;
        final name = item.nameCn.isNotEmpty ? item.nameCn : item.name;
        shows.add(ReminderShow(item.id, name, await _episodes(item.id)));
      }
      final plan = planReminders(shows: shows, nowLocal: DateTime.now());
      if (plan.isEmpty) return;
      final granted = await _requestPermission();
      permissionDenied.value = !granted;
      if (!granted) return;
      for (final p in plan) {
        await _plugin.zonedSchedule(
          id: p.id,
          title: p.title,
          body: p.body,
          scheduledDate: tz.TZDateTime.from(p.fireAtLocal, tz.local),
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
              'kazumi_episode_reminders',
              '新集提醒',
            ),
            iOS: DarwinNotificationDetails(),
          ),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          payload: '${p.bangumiId}',
        );
      }
      KazumiLogger().i('Reminders: scheduled ${plan.length}');
    } catch (e) {
      KazumiLogger().w('Reminders: refresh failed', error: e);
    }
  }

  Future<bool> _requestPermission() async {
    if (Platform.isIOS) {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin
              >()
              ?.requestPermissions(alert: true, sound: true) ??
          false;
    }
    return await _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.requestNotificationsPermission() ??
        true;
  }

  Future<void> _cancelOurs() async {
    for (final p in await _plugin.pendingNotificationRequests()) {
      if (p.id >= 1000000000) await _plugin.cancel(id: p.id);
    }
  }

  /// Episode lists are cached for a day per show so a launch doesn't
  /// refetch them.
  Future<List<EpisodeInfo>> _episodes(int id) async {
    Map<String, dynamic> cache;
    try {
      cache =
          jsonDecode(GStorage.getSetting(SettingsKeys.reminderEpisodeCache))
              as Map<String, dynamic>;
    } catch (_) {
      cache = {};
    }
    final hit = cache['$id'] as Map<String, dynamic>?;
    if (hit != null &&
        DateTime.now().difference(DateTime.parse(hit['at'] as String)) <
            const Duration(hours: 24)) {
      return [
        for (final e in hit['eps'] as List)
          EpisodeInfo(
            id: 0,
            episode: e['s'] as num,
            ep: e['e'] as num,
            type: e['t'] as int,
            name: '',
            nameCn: '',
            airdate: e['a'] as String,
          ),
      ];
    }
    final eps = await BangumiApi.getBangumiEpisodesByID(id);
    if (eps.isNotEmpty) {
      cache['$id'] = {
        'at': DateTime.now().toIso8601String(),
        'eps': [
          for (final e in eps)
            {'s': e.episode, 'e': e.ep, 't': e.type, 'a': e.airdate},
        ],
      };
      await GStorage.putSetting<String>(
        SettingsKeys.reminderEpisodeCache,
        jsonEncode(cache),
      );
    }
    return eps;
  }
}
