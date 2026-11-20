/// v0.29.2 banner-contradiction fix: Picture showed DEGRADED
/// (orange) while its subtitle read "CLEAR ON 12 OF 12 LINK
/// DIRECTION(S)". The subtitle was built from link counts only, but
/// assessHealth degrades for six reasons — so live == expected with
/// a deep-fade link contradicted the banner. [degradedSubtitle]
/// now names the actual reason, keeping the "CLEAR ON x OF y" form
/// only when the cause really is missing links.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/models/link_sample.dart';
import 'package:outride/services/health.dart';

void main() {
  group('degradedSubtitle', () {
    test('deep fade with all links live names the fade, never '
        '"CLEAR ON 12 OF 12"', () {
      final now = DateTime.now();
      final sample = LinkSample(
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
        ],
        lastByLink: {sample.linkKey: sample},
        staleAfter: (_) => const Duration(seconds: 5),
        fadeLevels: {sample.linkKey: -10.0},
      );
      expect(report.level, Coverage.degraded);
      expect(report.liveLinks, report.expectedLinks);
      final subtitle = degradedSubtitle(report);
      expect(subtitle, contains('DEEP FADE'));
      expect(subtitle, isNot(contains('CLEAR ON')));
    });

    test('missing links keep the "CLEAR ON x OF y" form', () {
      final now = DateTime.now();
      final live = LinkSample(
        timestamp: now,
        fromNode: 'silvus:90550',
        toNode: 'silvus:90551',
        snr: 10.0,
      );
      final stale = LinkSample(
        timestamp: now.subtract(const Duration(seconds: 60)),
        fromNode: 'silvus:90550',
        toNode: 'silvus:90552',
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
        ],
        lastByLink: {live.linkKey: live, stale.linkKey: stale},
        staleAfter: (_) => const Duration(seconds: 5),
      );
      expect(report.level, Coverage.degraded);
      expect(degradedSubtitle(report),
          'CLEAR ON 1 OF 2 LINK DIRECTION(S)');
    });

    test('driver fault names the driver', () {
      final now = DateTime.now();
      final sample = LinkSample(
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
        ],
        lastByLink: {sample.linkKey: sample},
        staleAfter: (_) => const Duration(seconds: 5),
      );
      expect(report.level, Coverage.degraded);
      expect(degradedSubtitle(report), contains('SILVUS'));
      expect(degradedSubtitle(report), isNot(contains('CLEAR ON')));
    });
  });
}
