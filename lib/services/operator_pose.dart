/// Operator pose for Fetch voice alerts: where the EUD is, and
/// which way the operator faces.
///
/// Position comes from [GpsPositioning.currentFix], cached and
/// refreshed at most every 10 s, fire-and-forget — a GPS lookup must
/// never block the poll loop. A fix older than 60 s counts as stale
/// (see [OperatorPosition.freshAt]) and the phrase builder treats it
/// as no position at all.
///
/// LIVE STREAM (v0.28.0, EXPERIMENTAL): [startLive] subscribes to
/// [GpsPositioning.watchPosition] and pushes every fix to
/// [liveFixes] with its accuracy, for the Field map's "you are here"
/// marker + accuracy ring. A denied/unavailable stream sets
/// [liveState] and the map falls back to the simulated operator
/// position — never a crash, never a blank map. Fixes from the
/// stream also refresh the cached [_last] position, so voice alerts
/// benefit from them too. Stream fixes are never transmitted or
/// persisted anywhere; they live in memory for the map only.
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

/// Watches the EUD position as a stream. Injectable so tests can
/// drive the live path without the platform location channel.
typedef OperatorWatchFetcher = Stream<
    ({
      double lat,
      double lon,
      double accuracyM,
      double altitudeM,
    })> Function({int distanceFilterM});

/// State of the live GPS stream (v0.28.0).
enum LiveGpsState {
  /// No live stream running.
  off,

  /// Permission/service checks running; no fix yet.
  starting,

  /// Fixes flowing.
  live,

  /// The user denied location permission (or denied it forever).
  /// The map falls back to the simulated operator position.
  denied,

  /// Location services off, or the stream failed for another
  /// reason. Same fallback as [denied].
  unavailable,
}

class OperatorPoseProvider {
  OperatorPoseProvider({OperatorFixFetcher? fetchFix, OperatorWatchFetcher? watchFix})
      : _fetchFix = fetchFix ?? GpsPositioning.currentFix,
        _watchFix = watchFix ?? GpsPositioning.watchPosition;

  final OperatorFixFetcher _fetchFix;
  final OperatorWatchFetcher _watchFix;

  /// Minimum gap between GPS refresh attempts (a fix lookup can
  /// take seconds on a cold start; hammering it would stall the
  /// UI thread with platform calls).
  static const Duration refreshInterval = Duration(seconds: 10);

  OperatorPosition? _last;
  DateTime? _lastAttempt;
  bool _refreshing = false;

  // --- Live stream (v0.28.0) ---------------------------------------

  StreamSubscription<({double lat, double lon, double accuracyM, double altitudeM})>?
      _liveSub;
  LiveGpsState _liveState = LiveGpsState.off;
  OperatorPosition? _liveFix;
  final _liveFixController = StreamController<OperatorPosition>.broadcast();
  final _liveStateController = StreamController<LiveGpsState>.broadcast();

  /// Latest live-stream fix, or null when the stream never produced
  /// one (or was stopped).
  OperatorPosition? get liveFix => _liveFix;

  /// Current live-stream state.
  LiveGpsState get liveState => _liveState;

  /// Every live fix, as it arrives. Broadcast — the AppState
  /// subscribes for map updates; tests subscribe directly.
  Stream<OperatorPosition> get liveFixes => _liveFixController.stream;

  /// Every live-state change. Broadcast.
  Stream<LiveGpsState> get liveStates => _liveStateController.stream;

  void _setLiveState(LiveGpsState state) {
    _liveState = state;
    if (!_liveStateController.isClosed) _liveStateController.add(state);
  }

  /// Starts the live position stream. Never throws: a denial or
  /// failure sets [liveState] to [LiveGpsState.denied] /
  /// [LiveGpsState.unavailable] and the caller falls back to the
  /// simulated operator position. A second call while live is a
  /// no-op. Each fix updates the cached [_last] position too.
  Future<void> startLive({int distanceFilterM = 2}) async {
    if (_liveSub != null) return;
    _setLiveState(LiveGpsState.starting);
    Stream<({double lat, double lon, double accuracyM, double altitudeM})> stream;
    try {
      stream = _watchFix(distanceFilterM: distanceFilterM);
    } catch (e) {
      _setLiveState(
          _isDenied(e) ? LiveGpsState.denied : LiveGpsState.unavailable);
      return;
    }
    _liveSub = stream.listen(
      (fix) {
        final pos = OperatorPosition(
          lat: fix.lat,
          lon: fix.lon,
          at: DateTime.now(),
          accuracyM: fix.accuracyM,
        );
        _liveFix = pos;
        _last = pos;
        _setLiveState(LiveGpsState.live);
        if (!_liveFixController.isClosed) _liveFixController.add(pos);
      },
      onError: (Object e) {
        _liveSub = null;
        _setLiveState(
            _isDenied(e) ? LiveGpsState.denied : LiveGpsState.unavailable);
      },
      onDone: () {
        _liveSub = null;
        if (_liveState != LiveGpsState.denied &&
            _liveState != LiveGpsState.unavailable) {
          _setLiveState(LiveGpsState.off);
        }
      },
      cancelOnError: true,
    );
  }

  /// Stops the live stream. The last live fix is dropped, so the
  /// map falls back to the simulated operator position.
  Future<void> stopLive() async {
    await _liveSub?.cancel();
    _liveSub = null;
    _liveFix = null;
    _setLiveState(LiveGpsState.off);
  }

  /// Closes the live-stream controllers. Call once, when the owner
  /// (AppState) is disposed.
  Future<void> disposeLive() async {
    await _liveSub?.cancel();
    _liveSub = null;
    if (!_liveFixController.isClosed) await _liveFixController.close();
    if (!_liveStateController.isClosed) await _liveStateController.close();
  }

  static bool _isDenied(Object e) =>
      e is GpsException && e.message.contains('DENIED');

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
      _last = OperatorPosition(
        lat: fix.lat,
        lon: fix.lon,
        at: DateTime.now(),
        accuracyM: fix.accuracyM,
      );
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
    final pos = OperatorPosition(
      lat: fix.lat,
      lon: fix.lon,
      at: DateTime.now(),
      accuracyM: fix.accuracyM,
    );
    _last = pos;
    _lastAttempt = DateTime.now();
    return pos;
  }
}
