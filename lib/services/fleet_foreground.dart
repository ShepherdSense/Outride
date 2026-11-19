/// Android foreground-service bridge for the fleet (spec §8).
///
/// The fleet beacon/listener socket lives under a NEW Android
/// foreground service with a persistent notification ("Outride
/// Fleet — N members"), started when the operator opens Fleet /
/// joins or creates, stopped on "Forget fleet". The Kotlin side is
/// `FleetForegroundService` (MainActivity wires the
/// `outride/fleet_service` channel). Non-Android platforms and a
/// missing channel are no-ops that return false — the Dart fleet
/// service runs either way; only the persistent notification is
/// lost. No new runtime permission: the Android 13+ notification
/// permission, if denied, only hides the notification — the service
/// still runs, with no blocking prompt.
library;

import 'dart:io';

import 'package:flutter/services.dart';

class FleetForegroundService {
  static const _channel = MethodChannel('outride/fleet_service');

  /// Start (or update) the foreground service with the current
  /// member count. Returns true when the platform acknowledged it.
  static Future<bool> start({required int members}) async {
    if (!Platform.isAndroid) return false;
    try {
      return (await _channel.invokeMethod<bool>(
              'start', {'members': members})) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Refresh the notification's member count while running.
  static Future<bool> update({required int members}) async {
    if (!Platform.isAndroid) return false;
    try {
      return (await _channel.invokeMethod<bool>(
              'update', {'members': members})) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Stop the foreground service. Returns true when acknowledged.
  static Future<bool> stop() async {
    if (!Platform.isAndroid) return false;
    try {
      return (await _channel.invokeMethod<bool>('stop')) ?? false;
    } catch (_) {
      return false;
    }
  }
}
