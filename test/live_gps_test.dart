/// Tests for the live GPS map view (v0.28.0, EXPERIMENTAL):
/// the provider's live stream (fixes flow with accuracy, denial
/// sets state instead of throwing, stop clears it), the follow-mode
/// transform math, and the AppState marker fallback (live fix ->
/// live marker; stop/deny -> simulated marker; map still works).
///
/// The provider is driven through an injected fake watch stream —
/// no test here touches the real geolocator.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/services/gps_positioning.dart';
import 'package:outride/services/operator_pose.dart';
import 'package:outride/services/simulated.dart';
import 'package:outride/state/app_state.dart';
import 'package:outride/utils/field_map_transform.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef _Fix = ({
  double lat,
  double lon,
  double accuracyM,
  double altitudeM,
});

/// A watch stream that stays open (like a real position stream)
/// and has already delivered one fix at the sim demo anchor.
Stream<_Fix> _openWatch({int distanceFilterM = 2}) {
  final controller = StreamController<_Fix>();
  controller.add((
    lat: SimGroundFeed.demoOriginLat,
    lon: SimGroundFeed.demoOriginLon,
    accuracyM: 8.0,
    altitudeM: 100.0,
  ));
  return controller.stream;
}

/// A watch stream that fails immediately with a denial, like a
/// user refusing the browser/system location prompt.
Stream<_Fix> _deniedWatch({int distanceFilterM = 2}) async* {
  throw GpsException('LOCATION PERMISSION DENIED.');
}

void main() {
  group('OperatorPoseProvider live stream', () {
    test('fixes flow with accuracy; state goes live; stop clears it',
        () async {
      final pose = OperatorPoseProvider(watchFix: _openWatch);
      final firstFix = pose.liveFixes.first;
      await pose.startLive();
      final fix = await firstFix.timeout(const Duration(seconds: 5));
      expect(fix.lat, SimGroundFeed.demoOriginLat);
      expect(fix.accuracyM, 8.0);
      expect(pose.liveState, LiveGpsState.live);
      expect(pose.liveFix, isNotNull);
      // The stream also refreshes the cached pose voice alerts use.
      expect(pose.lastPosition, isNotNull);
      expect(pose.lastPosition!.accuracyM, 8.0);

      await pose.stopLive();
      expect(pose.liveState, LiveGpsState.off);
      expect(pose.liveFix, isNull);
      await pose.disposeLive();
    });

    test('a second startLive while live is a no-op', () async {
      final pose = OperatorPoseProvider(watchFix: _openWatch);
      final firstFix = pose.liveFixes.first;
      await pose.startLive();
      await firstFix.timeout(const Duration(seconds: 5));
      // Second call must not restart the stream or throw.
      await pose.startLive();
      expect(pose.liveState, LiveGpsState.live);
      await pose.stopLive();
      await pose.disposeLive();
    });

    test('denied stream sets state denied, never throws', () async {
      final pose = OperatorPoseProvider(watchFix: _deniedWatch);
      await pose.startLive();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(pose.liveState, LiveGpsState.denied);
      expect(pose.liveFix, isNull);
      await pose.stopLive();
      await pose.disposeLive();
    });
  });

  group('FieldMapTransform', () {
    test('centered puts the center on the screen center', () {
      const size = Size(400, 300);
      final t = FieldMapTransform.centered(
        size: size,
        centerX: 10,
        centerY: -20,
        scale: 2.0,
      );
      expect(t.toScreen(10, -20), const Offset(200, 150));
      // 5 m east of center is 10 px right of screen center.
      expect(t.toScreen(15, -20), const Offset(210, 150));
      // 5 m north of center is 10 px above screen center.
      expect(t.toScreen(10, -15), const Offset(200, 140));
    });

    test('fit has positive scale and centers the points', () {
      const size = Size(400, 300);
      final t = FieldMapTransform.fit(
        size,
        [const math.Point(0.0, 0.0), const math.Point(100.0, 0.0)],
      );
      expect(t.scale, greaterThan(0));
      final c = t.toScreen(50, 0);
      expect(c.dx, closeTo(200, 1.0));
      expect(c.dy, closeTo(150, 1.0));
    });
  });

  group('AppState map operator position', () {
    test(
        'live fix -> live marker; stop/deny -> simulated marker; map still works',
        () async {
      // This test exercises the simulated marker fallback, so it
      // stores a simulated choice: the fresh-install default is now
      // LIVE (see simulated_mode), and the async settings load would
      // otherwise flip an in-memory write back to LIVE mid-test.
      SharedPreferences.setMockInitialValues({
        'rf_sentry_zmeta_v1': jsonEncode({'simulatedMode': true}),
      });
      final state = AppState();
      addTearDown(state.dispose);
      // Let the async settings load land before asserting on the
      // marker: the stored simulated choice is what it reads.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(state.settings.simulatedMode, isTrue);
      final simPos = state.mapOperatorPosition;
      expect(simPos, isNotNull);
      expect(state.mapOperatorIsLive, isFalse);
      expect(state.mapOperatorAccuracyM, isNull);
      expect(simPos!.lat, SimGroundFeed.demoOriginLat);
      expect(state.mapOperatorMeters, isNotNull);
      expect(state.mapOperatorMeters!.x, closeTo(0, 1e-9));
      expect(state.mapOperatorMeters!.y, closeTo(0, 1e-9));

      // Live fix at the demo anchor: the marker goes live.
      state.operatorPoseForTest =
          OperatorPoseProvider(watchFix: _openWatch);
      await state.startLiveGps();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(state.liveGpsState, LiveGpsState.live);
      expect(state.mapOperatorIsLive, isTrue);
      expect(state.mapOperatorAccuracyM, 8.0);
      expect(state.mapOperatorPosition!.lat, SimGroundFeed.demoOriginLat);

      // Stop: back to the simulated marker.
      await state.stopLiveGps();
      expect(state.liveGpsState, LiveGpsState.off);
      expect(state.mapOperatorIsLive, isFalse);
      expect(state.mapOperatorPosition!.lat, SimGroundFeed.demoOriginLat);

      // Denied: state denied, simulated marker stays, map works.
      state.operatorPoseForTest =
          OperatorPoseProvider(watchFix: _deniedWatch);
      await state.startLiveGps();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(state.liveGpsState, LiveGpsState.denied);
      expect(state.mapOperatorIsLive, isFalse);
      expect(state.mapOperatorPosition, isNotNull);
      await state.stopLiveGps();
    });

    test('follow refuses to turn on with no operator position', () {
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      addTearDown(state.dispose);
      // Live mode, no GPS origin, no live fix: there is no operator
      // position at all, so follow must refuse to turn on.
      state.settings.simulatedMode = false;
      expect(state.mapOperatorPosition, isNull);
      state.setLiveGpsFollow(true);
      expect(state.liveGpsFollow, isFalse);
    });
  });
}
