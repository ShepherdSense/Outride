/// Background tripwire alerts — local notifications (v0.30.0).
///
/// Posts a local notification when a Fetch trip confirms, BESIDE the
/// voice alert — never suppressing or replacing it. The trigger is
/// the same one: [FetchVoiceAlerts.nextPhrase] returning a phrase in
/// `AppState._maybeAnnounceFetchTrips`. The notification body IS
/// that phrase, so the wording follows the same honesty rules
/// (neutral presence wording, never identity or hostile intent).
///
/// Platform scope (explicit, not a silent gap): notifications post
/// on ANDROID only in this build. flutter_local_notifications 23
/// ships a Windows plugin, but its Windows support is limited and
/// unproven in this app, so every other platform is a deliberate
/// no-op: [TripwireNotifier.supported] is false there,
/// [LocalTripwireNotifier.ensurePermission] returns false, and
/// [LocalTripwireNotifier.postTripAlert] returns without posting.
/// The Settings toggle is disabled off-Android for the same reason.
///
/// Android: channel `outride_tripwire` is created on first use
/// (flutter_local_notifications requires the channel before posting
/// on Android 8+). Android 13+ needs the POST_NOTIFICATIONS runtime
/// permission — requested in-app via permission_handler at the point
/// alerts are enabled ([LocalTripwireNotifier.ensurePermission]);
/// the permission is already declared in
/// android/app/src/main/AndroidManifest.xml. On Android < 13 the
/// permission is install-time granted and the request is a no-op
/// that reports granted.
///
/// Tests never touch the platform channels: they inject a fake
/// [TripwireNotifier] through `AppState.tripwireNotifierForTest`.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

/// Notification sink for confirmed tripwire alerts. Production =
/// [LocalTripwireNotifier]; tests use a fake that records posts.
abstract class TripwireNotifier {
  /// True where posting actually happens (Android in this build).
  bool get supported;

  /// Request the notification permission where the platform needs
  /// one (Android 13+ POST_NOTIFICATIONS via permission_handler).
  /// Returns true when posting is allowed afterwards. Never throws.
  Future<bool> ensurePermission();

  /// Post one trip alert. Never throws — a failed post must never
  /// take down the poll loop that confirmed the trip.
  Future<void> postTripAlert({
    required String title,
    required String body,
  });
}

/// flutter_local_notifications implementation of [TripwireNotifier].
class LocalTripwireNotifier implements TripwireNotifier {
  LocalTripwireNotifier({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  /// Android notification channel for trip alerts.
  static const String channelId = 'outride_tripwire';
  static const String channelName = 'Tripwire alerts';
  static const String channelDescription =
      'Alerts when a Fetch sensor trip confirms.';

  bool _initialized = false;
  int _nextId = 0;

  @override
  bool get supported =>
      defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<bool> ensurePermission() async {
    if (!supported) return false;
    try {
      final status = await Permission.notification.request();
      return status.isGranted;
    } catch (e) {
      debugPrint('Tripwire notifications: permission request failed: $e');
      return false;
    }
  }

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              channelId,
              channelName,
              description: channelDescription,
              importance: Importance.high,
            ),
          );
      _initialized = true;
    } catch (e) {
      debugPrint('Tripwire notifications: init failed: $e');
    }
  }

  @override
  Future<void> postTripAlert({
    required String title,
    required String body,
  }) async {
    // Explicit no-op off-Android (see file doc) — not a silent gap.
    if (!supported) return;
    try {
      await _ensureInitialized();
      await _plugin.show(
        id: _nextId++,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            channelName,
            channelDescription: channelDescription,
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );
    } catch (e) {
      // A failed post must never crash the app or the poll loop.
      debugPrint('Tripwire notifications: post failed: $e');
    }
  }
}
