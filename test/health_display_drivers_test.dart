/// Regression tests for the review finding B2 (Fetch visualizer
/// review, 2026-11-12): a display-only driver must never poison
/// deployment health.
///
/// The Fetch (and Camera) drivers return no LinkSamples by design —
/// they corroborate/display, they don't drive the tripwire. Before
/// the fix, every empty poll set the driver's status error to its
/// emptyHint, and assessHealth treated any driver error as a fault:
/// adding FETCH alongside a live Silvus mesh dropped coverage to
/// degraded (or blind in a Fetch-only bench setup) with a permanent
/// red dashboard row, even while Fetch events were flowing.
///
/// The fix is a shared contract: RadioDriver.emptyPollIsError
/// (default true — an empty poll really does mean "radio broken"
/// for RF drivers), overridden to false by display-only drivers,
/// and respected by the poller in app_state._tickPoller.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/models/link_sample.dart';
import 'package:outride/services/camera_driver.dart';
import 'package:outride/services/fetch_driver.dart';
import 'package:outride/services/health.dart';
import 'package:outride/services/radio_driver.dart';

void main() {
  group('emptyPollIsError contract', () {
    test('display-only drivers do not treat an empty poll as an error',
        () {
      expect(FetchDriver().emptyPollIsError, isFalse);
      expect(CameraDriver().emptyPollIsError, isFalse);
    });

    test('RF drivers keep the default: an empty poll is an error', () {
      expect(RfDriverForTest().emptyPollIsError, isTrue);
      expect(SdrDriver.fromAddress('127.0.0.1:49161').emptyPollIsError,
          isTrue);
    });
  });

  group('assessHealth with a display-only driver attached (B2)', () {
    test('Fetch attached + live Silvus links stays OK, no FETCH reason',
        () {
      final now = DateTime.now();
      final silvusSample = LinkSample(
        timestamp: now,
        fromNode: 'silvus:90550',
        toNode: 'silvus:90551',
        snr: 10.0,
      );
      final report = assessHealth(
        now: now,
        startedAt: now.subtract(const Duration(seconds: 5)),
        drivers: [
          DriverHealthInput(
            driverId: 'silvus',
            label: 'SILVUS',
            pollIntervalSecs: 0.25,
            lastPoll: now,
          ),
          // What the poller now reports for Fetch: polled fresh, no
          // error — its empty polls are normal, not a fault.
          DriverHealthInput(
            driverId: 'fetch',
            label: 'FETCH',
            pollIntervalSecs: 0.25,
            lastPoll: now,
          ),
        ],
        lastByLink: {silvusSample.linkKey: silvusSample},
        staleAfter: (_) => const Duration(seconds: 5),
      );
      expect(report.level, Coverage.ok);
      expect(report.reasons, isEmpty);
      expect(report.liveLinks, 1);
      expect(report.expectedLinks, 1);
    });

    test('Fetch-only bench setup does not read BLIND', () {
      // No RF links yet, Fetch polling fresh, no error: the verdict
      // is "starting" (no verdict yet), never BLIND. Before the fix
      // the Fetch emptyHint error forced Coverage.blind here.
      final now = DateTime.now();
      final report = assessHealth(
        now: now,
        startedAt: now.subtract(const Duration(seconds: 5)),
        drivers: [
          DriverHealthInput(
            driverId: 'fetch',
            label: 'FETCH',
            pollIntervalSecs: 0.25,
            lastPoll: now,
          ),
        ],
        lastByLink: const {},
        staleAfter: (_) => const Duration(seconds: 5),
      );
      expect(report.level, Coverage.starting);
      expect(report.reasons, isEmpty);
    });

    test('a real RF driver error still degrades health (control)', () {
      // The fix must not mute genuine faults: an RF driver reporting
      // an error still degrades, with its label in the reasons.
      final now = DateTime.now();
      final silvusSample = LinkSample(
        timestamp: now,
        fromNode: 'silvus:90550',
        toNode: 'silvus:90551',
        snr: 10.0,
      );
      final report = assessHealth(
        now: now,
        startedAt: now.subtract(const Duration(seconds: 5)),
        drivers: [
          DriverHealthInput(
            driverId: 'silvus',
            label: 'SILVUS',
            pollIntervalSecs: 0.25,
            lastPoll: now,
            error: 'Radio reachable but reports no RF links',
          ),
          DriverHealthInput(
            driverId: 'fetch',
            label: 'FETCH',
            pollIntervalSecs: 0.25,
            lastPoll: now,
          ),
        ],
        lastByLink: {silvusSample.linkKey: silvusSample},
        staleAfter: (_) => const Duration(seconds: 5),
      );
      expect(report.level, Coverage.degraded);
      expect(report.reasons.any((r) => r.startsWith('SILVUS:')), isTrue);
      expect(report.reasons.any((r) => r.startsWith('FETCH:')), isFalse);
    });
  });
}

/// Minimal RF driver standing in for Silvus in the default-value
/// check: it inherits the base contract untouched, so its
/// emptyPollIsError must be the default (true).
class RfDriverForTest extends RadioDriver {
  @override
  String get driverId => 'silvus-test';

  @override
  String get label => 'SILVUS-TEST';

  @override
  bool get isImplemented => true;

  @override
  Future<List<LinkSample>> poll() async => const [];

  @override
  Future<bool> probe() async => true;
}
