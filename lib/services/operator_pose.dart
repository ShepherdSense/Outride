/// Operator pose for Fetch voice alerts: where the EUD is, and
/// which way the operator faces.
///
/// Position comes from [GpsPositioning.currentFix], cached and
/// refreshed at most every 10 s, fire-and-forget — a GPS lookup must
/// never block the poll loop. A fix older than 60 s counts as stale
/// (see [OperatorPosition.freshAt]) and the phrase builder treats it
/// as no position at all.
///
/// HEADING IS DEFERRED IN v1: there is no compass heading here.
/// sensors_plus exposes a raw magnetometer + accelerometer, and a
/// tilt-compensated heading from them is only trustworthy after
/// validation against a known bearing on real hardware — which this
/// sandbox cannot do. Shipping an unverified heading would point
/// the operator the wrong way inside a structure, which is worse
/// than no heading. So [heading] is always null in v1 and phrases
/// use the cardinal fallback ("north-east") instead of relative
/// terms ("ahead left"). Relative terms are deferred until compass
/// validation on the EUD. The throw point still records a heading
/// field (null in v1) so the shape is ready when validation lands.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'fetch_voice_alerts.dart';
import 'gps_positioning.dart';

/// Fetches one EUD fix. Injectable so tests can drive the provider
/// without the platform location channel.
typedef OperatorFixFetcher = Future<
    ({
      double lat,
      double lon,
      double accuracyM,
      double altitudeM,
    })> Function();

class OperatorPoseProvider {
  OperatorPoseProvider({OperatorFixFetcher? fetchFix})
      : _fetchFix = fetchFix ?? GpsPositioning.currentFix;

  final OperatorFixFetcher _fetchFix;

  /// Minimum gap between GPS refresh attempts (a fix lookup can
  /// take seconds on a cold start; hammering it would stall the
  /// UI thread with platform calls).
  static const Duration refreshInterval = Duration(seconds: 10);

  OperatorPosition? _last;
  DateTime? _lastAttempt;
  bool _refreshing = false;

  /// Last good fix, or null when none has ever arrived.
  OperatorPosition? get lastPosition => _last;

  /// Compass heading in degrees, clockwise from north — ALWAYS null
  /// in v1 (see the file doc: unverified heading is worse than none).
  double? get heading => null;

  /// Fresh operator position, or null when there is none or it is
  /// stale (> 60 s old). Callers pass [now] for testability.
  OperatorPosition? currentPosition({DateTime? now}) {
    final p = _last;
    if (p == null) return null;
    return p.freshAt(now ?? DateTime.now()) ? p : null;
  }

  /// Fire-and-forget refresh: fetches a fresh fix unless one was
  /// attempted within [refreshInterval] or one is already in flight.
  /// Never throws — a failed fix leaves the last good one in place
  /// (or nothing, when there never was one).
  Future<void> refresh() async {
    final now = DateTime.now();
    if (_refreshing) return;
    if (_lastAttempt != null &&
        now.difference(_lastAttempt!) < refreshInterval) {
      return;
    }
    _lastAttempt = now;
    _refreshing = true;
    try {
      final fix = await _fetchFix();
      _last = OperatorPosition(lat: fix.lat, lon: fix.lon, at: DateTime.now());
    } catch (e) {
      // No fix: keep the last good one. The phrase builder treats
      // a stale/missing position as "no position" and speaks the
      // sensor phrase with no direction — never a guessed one.
      // Logged (not swallowed silently) so a permanently failing
      // GPS leaves a diagnostic trace.
      debugPrint('Fetch voice: operator pose refresh failed: $e');
    } finally {
      _refreshing = false;
    }
  }

  /// One-shot fix for the throw-point capture: awaits a fresh fix
  /// (up to the platform's own timeout) and returns it, or throws
  /// the platform's [GpsException] with its UI-ready message.
  /// Used only from the explicit "Mark throw" tap, never the poll
  /// loop — the operator asked for it, so waiting is correct.
  Future<OperatorPosition> captureNow() async {
    final fix = await _fetchFix();
    final pos = OperatorPosition(lat: fix.lat, lon: fix.lon, at: DateTime.now());
    _last = pos;
    _lastAttempt = DateTime.now();
    return pos;
  }
}
