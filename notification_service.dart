// lib/services/notification_service.dart

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart'; // Essential for TimeOfDay
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

/// NotificationService
/// - Handles initialization, permission requests, channels, and scheduling.
/// - The 'uiLocalNotificationDateInterpretation' parameter has been removed
///   from zonedSchedule calls to ensure compatibility on Web/Chrome.
class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  // MethodChannel name MUST MATCH the one in your MainActivity.kt file.
  static const MethodChannel _exactAlarmChannel =
      MethodChannel('app.channel/exact_alarms');

  // ------------------------------------------------------------------
  // INIT
  // ------------------------------------------------------------------
  static Future<void> init() async {
    // 1. Timezone initialization
    tz.initializeTimeZones();
    if (!kIsWeb) {
      tz.setLocalLocation(tz.local);
    }

    // 2. Initialize Hive (safe to call multiple times)
    await Hive.initFlutter();
    await Hive.openBox('aayutrack_reminders');

    // 3. Platform-specific initialization settings
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestSoundPermission: true,
      requestBadgePermission: true,
    );

    const settings = InitializationSettings(
      android: androidInit,
      iOS: iosInit,
    );

    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: (response) {
        debugPrint("🔔 Notification tapped: ${response.payload}");
      },
    );

    // 4. Create channels and request permissions
    if (!kIsWeb && Platform.isAndroid) {
      await _createMainChannel();
      await _createDailyChannel();
    }
    await requestPermission();

    // 5. Reschedule any saved reminders (critical for persistence)
    await _rescheduleSavedReminders();
  }

  // ------------------------------------------------------------------
  // EXACT ALARM PERMISSION HELPERS (Android 12+)
  // ------------------------------------------------------------------
  static Future<bool> _canScheduleExactAlarms() async {
    if (!Platform.isAndroid) return true;
    try {
      final can =
          await _exactAlarmChannel.invokeMethod<bool>('canScheduleExactAlarms');
      return can ?? false;
    } on PlatformException catch (e) {
      debugPrint("Exact alarm check failed: $e");
      return false;
    } catch (e) {
      return false;
    }
  }

  static Future<void> _requestExactAlarmsPermission() async {
    if (!Platform.isAndroid) return;
    try {
      await _exactAlarmChannel.invokeMethod('requestExactAlarmsPermission');
    } on PlatformException catch (e) {
      debugPrint("Failed to open exact alarm settings: $e");
    }
  }

  static Future<bool> _ensureExactAlarmPermissionOrAsk() async {
    if (!kIsWeb && Platform.isAndroid) {
      final can = await _canScheduleExactAlarms();
      if (can) return true;

      await _requestExactAlarmsPermission();
      return false;
    }
    return true;
  }

  // ------------------------------------------------------------------
  // PERMISSIONS
  // ------------------------------------------------------------------
  static Future<void> requestPermission() async {
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();

    await _plugin
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);
  }

  // ------------------------------------------------------------------
  // CREATE CHANNELS
  // ------------------------------------------------------------------
  static Future<void> _createMainChannel() async {
    const channel = AndroidNotificationChannel(
      'aayutrack_reminders',
      'AayuTrack Health Alerts',
      description: 'Medicine, hydration, and health alerts',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
    );

    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(channel);
  }

  static Future<void> _createDailyChannel() async {
    const channel = AndroidNotificationChannel(
      'aayutrack_daily',
      'AayuTrack Daily Reminders',
      description: 'Daily scheduled reminders',
      importance: Importance.max,
      playSound: true,
    );

    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(channel);
  }

  static NotificationDetails _alarmDetails(String channelId, String name) {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        channelId,
        name,
        channelDescription: 'AayuTrack Alerts',
        importance: Importance.max,
        priority: Priority.max,
        playSound: true,
        enableVibration: true,
        category: AndroidNotificationCategory.alarm,
        ticker: 'AayuTrack Reminder',
        fullScreenIntent: false,
        icon: '@mipmap/ic_launcher',
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        interruptionLevel: InterruptionLevel.timeSensitive,
      ),
    );
  }

  // ------------------------------------------------------------------
  // SHOW INSTANT NOTIFICATION
  // ------------------------------------------------------------------
  static Future<void> showInstant({
    required String title,
    required String body,
    String? payload,
  }) async {
    await _plugin.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      _alarmDetails('aayutrack_reminders', "AayuTrack Health Alerts"),
      payload: payload,
    );
  }

  static Future<void> showNotification({
    required String title,
    required String body,
  }) async =>
      showInstant(title: title, body: body);

  // ------------------------------------------------------------------
  // SCHEDULE ONE-TIME NOTIFICATION (FIXED FOR CHROME COMPATIBILITY)
  // ------------------------------------------------------------------
  static Future<void> schedule({
    required String title,
    required String body,
    required DateTime time,
  }) async {
    final ok = await _ensureExactAlarmPermissionOrAsk();
    if (!ok) {
      debugPrint("Exact alarms not permitted yet. Please grant permission.");
      return;
    }

    final id = time.millisecondsSinceEpoch ~/ 1000;
    final box = Hive.box('aayutrack_reminders');

    await _plugin.zonedSchedule(
      id,
      title,
      body,
      tz.TZDateTime.from(time, tz.local),
      _alarmDetails('aayutrack_reminders', "AayuTrack Health Alerts"),
      // Removed uiLocalNotificationDateInterpretation parameter for stability on Web/Chrome
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    );

    await box.put(id, {
      'id': id,
      'title': title,
      'body': body,
      'time': time.toIso8601String(),
      'type': 'once',
    });
  }

  // ------------------------------------------------------------------
  // SCHEDULE DAILY NOTIFICATION (FIXED FOR CHROME COMPATIBILITY)
  // ------------------------------------------------------------------
  static Future<void> scheduleDaily({
    required String title,
    required String body,
    required TimeOfDay time,
  }) async {
    final ok = await _ensureExactAlarmPermissionOrAsk();
    if (!ok) {
      debugPrint("Exact alarms not permitted yet. Please grant permission.");
      return;
    }

    final id = time.hour * 100 + time.minute;

    final now = DateTime.now();
    DateTime scheduled = DateTime(
      now.year,
      now.month,
      now.day,
      time.hour,
      time.minute,
    );

    if (scheduled.isBefore(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }

    final box = Hive.box('aayutrack_reminders');

    await _plugin.zonedSchedule(
      id,
      title,
      body,
      tz.TZDateTime.from(scheduled, tz.local),
      _alarmDetails('aayutrack_daily', "AayuTrack Daily Reminders"),
      // Removed uiLocalNotificationDateInterpretation parameter for stability on Web/Chrome
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
    );

    await box.put(id, {
      'id': id,
      'title': title,
      'body': body,
      'hour': time.hour,
      'minute': time.minute,
      'type': 'daily',
    });
  }

  // ------------------------------------------------------------------
  // RESCHEDULE ON APP RESTART (CRITICAL FOR RELIABILITY)
  // ------------------------------------------------------------------
  static Future<void> _rescheduleSavedReminders() async {
    // Before rescheduling, cancel all existing scheduled notifications
    // to avoid duplicates and ensure the schedule is up-to-date.
    await _plugin.cancelAll();

    final box = Hive.box('aayutrack_reminders');

    for (final r in box.values) {
      try {
        if (r['type'] == 'daily') {
          await scheduleDaily(
            title: r['title'],
            body: r['body'],
            time: TimeOfDay(
              hour: (r['hour'] ?? 8) as int,
              minute: (r['minute'] ?? 0) as int,
            ),
          );
        } else if (r['type'] == 'once') {
          final t = DateTime.tryParse(r['time'] ?? '');
          if (t != null && t.isAfter(DateTime.now())) {
            await schedule(
              title: r['title'],
              body: r['body'],
              time: t,
            );
          } else {
            // Remove expired one-time reminders
            await box.delete(r['id']);
          }
        }
      } catch (e) {
        debugPrint("⚠ Reschedule error for ID ${r['id']}: $e");
      }
    }
  }

  // ------------------------------------------------------------------
  // CANCEL
  // ------------------------------------------------------------------
  static Future<void> cancel(int id) async {
    await _plugin.cancel(id);
    final box = Hive.box('aayutrack_reminders');
    await box.delete(id);
  }

  // ------------------------------------------------------------------
  // CANCEL ALL NOTIFICATIONS
  // ------------------------------------------------------------------
  static Future<void> cancelAll() async {
    await _plugin.cancelAll();
    await Hive.box('aayutrack_reminders').clear();
  }
}
