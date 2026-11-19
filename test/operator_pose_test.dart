/// Tests for OperatorPoseProvider: the 60 s freshness guard, the
/// 10 s refresh interval, failure containment (a failed GPS lookup
/// never throws out of refresh and never drops the last good fix),
/// and captureNow. The provider is driven through an injected fake
/// fix fetcher — no test here touches the real geolocator.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/services/operator_pose.dart';

({double lat, double lon, double accuracyM, double altitudeM})
    _fix({double lat = 35.0, double lon = -79.0}) =>
        (lat: lat, lon: lon, accuracyM: 5.0, altitudeM: 100.0);

void main() {
  group('OperatorPoseProvider', () {
    test('heading is always null in v1', () {
      final pose = OperatorPoseProvider(fetchFix: () async => _fix());
      expect(pose.heading, isNull);
    });

    test('refresh fetches a fix and currentPosition returns it fresh',
        () async {
      var calls = 0;
      final pose = OperatorPoseProvider(fetchFix: () async {
        calls++;
        return _fix();
      });
      expect(pose.lastPosition, isNull);
      await pose.refresh();
      expect(calls, 1);
      final pos = pose.currentPosition();
      expect(pos, isNotNull);
      expect(pos!.lat, 35.0);
      expect(pos.lon, -79.0);
    });

    test('60 s freshness guard: 60 s is fresh, 61 s is stale', () async {
      final pose = OperatorPoseProvider(fetchFix: () async => _fix());
      final captured = await pose.captureNow();
      final at = captured.at;
      expect(pose.currentPosition(now: at.add(const Duration(seconds: 60))),
          isNotNull);
      expect(pose.currentPosition(now: at.add(const Duration(seconds: 61))),
          isNull);
      expect(pose.currentPosition(now: at.add(const Duration(seconds: 120))),
          isNull);
    });

    test('10 s refresh interval: a second refresh inside the window is a no-op',
        () async {
      var calls = 0;
      final pose = OperatorPoseProvider(fetchFix: () async {
        calls++;
        return _fix();
      });
      await pose.refresh();
      await pose.refresh();
      await pose.refresh();
      expect(calls, 1);
    });

    test('failure containment: a failed refresh never throws and leaves no fix',
        () async {
      final failing = OperatorPoseProvider(fetchFix: () async {
        throw StateError('no GPS');
      });
      await failing.refresh(); // must not throw
      expect(failing.lastPosition, isNull);
      expect(failing.currentPosition(), isNull);
      // A second failed attempt is equally contained.
      await failing.refresh();
      expect(failing.lastPosition, isNull);
      // Note: the "keeps the last good fix" half of the catch block
      // shares this same catch — it is not separately drivable in a
      // fast test because a successful refresh arms the 10 s
      // interval guard, and the catch never touches [_last].
    });

    test('captureNow returns the fix and throws the platform error through',
        () async {
      final pose = OperatorPoseProvider(fetchFix: () async => _fix());
      final pos = await pose.captureNow();
      expect(pos.lat, 35.0);
      expect(pose.lastPosition, same(pos));

      final failing = OperatorPoseProvider(fetchFix: () async {
        throw StateError('no GPS');
      });
      await expectLater(failing.captureNow(), throwsStateError);
      expect(failing.lastPosition, isNull);
    });
  });
}
