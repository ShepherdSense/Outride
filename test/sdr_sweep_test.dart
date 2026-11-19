/// Tests for the SdrDriver wideband sweep store: sweep_step ingest,
/// pass grouping, display-only contract (sweeps never become
/// LinkSamples), state-aware emptyPollIsError, and AppState
/// aggregation.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/services/radio_driver.dart';
import 'package:outride/state/app_state.dart';

String _sweepStep({
  required double center,
  required int sweepId,
  required int stepIndex,
  int stepCount = 3,
  double energy = -80.0,
  double noise = -100.0,
  List<Map<String, dynamic>>? peaks,
}) {
  final peaksJson = peaks == null
      ? '[]'
      : '[${peaks.map((p) => '{"freq_mhz":${p['freq_mhz']},"dbfs":${p['dbfs']}}').join(',')}]';
  final bins = List.filled(32, -90.0).join(',');
  return '{"v":1,"kind":"sweep_step","radio":"rtlsdr0",'
      '"sweep_id":$sweepId,"step_index":$stepIndex,'
      '"step_count":$stepCount,"center_mhz":$center,"span_mhz":1.92,'
      '"energy_dbfs":$energy,"noise_dbfs":$noise,'
      '"bins_dbfs":[$bins],"peaks":$peaksJson,"t":1729123456.0}';
}

void main() {
  group('SdrDriver sweep ingest', () {
    test('sweep steps land in the store, center-sorted', () {
      final d = SdrDriver(host: '127.0.0.1', port: 49161);
      d.datagramForTest(_sweepStep(center: 915.0, sweepId: 0, stepIndex: 1));
      d.datagramForTest(_sweepStep(center: 88.0, sweepId: 0, stepIndex: 0));
      d.datagramForTest(_sweepStep(center: 1090.0, sweepId: 0, stepIndex: 2));
      expect(d.sweepIngestedCount, 3);
      expect(d.sweepMalformedCount, 0);
      expect(d.latestSweepId, 0);
      final steps = d.latestSweepSteps;
      expect(steps.map((s) => s.centerMhz).toList(), [88.0, 915.0, 1090.0]);
      expect(d.lastSweepAt, isNotNull);
    });

    test('peaks surface strongest first, capped at 20', () {
      final d = SdrDriver(host: '127.0.0.1', port: 49161);
      d.datagramForTest(_sweepStep(
        center: 915.0,
        sweepId: 0,
        stepIndex: 0,
        peaks: [
          {'freq_mhz': 915.5, 'dbfs': -70.0},
          {'freq_mhz': 915.14, 'dbfs': -48.3},
        ],
      ));
      d.datagramForTest(_sweepStep(
        center: 1090.0,
        sweepId: 0,
        stepIndex: 1,
        peaks: [
          {'freq_mhz': 1090.15, 'dbfs': -59.1},
        ],
      ));
      final peaks = d.latestSweepPeaks;
      expect(peaks.map((p) => p.dbfs).toList(), [-48.3, -59.1, -70.0]);
    });

    test('new sweep_id starts a new pass: old steps drop', () {
      final d = SdrDriver(host: '127.0.0.1', port: 49161);
      d.datagramForTest(_sweepStep(center: 88.0, sweepId: 0, stepIndex: 0));
      d.datagramForTest(_sweepStep(center: 915.0, sweepId: 0, stepIndex: 1));
      expect(d.latestSweepSteps, hasLength(2));
      d.datagramForTest(_sweepStep(center: 88.0, sweepId: 1, stepIndex: 0));
      expect(d.latestSweepId, 1);
      expect(d.latestSweepSteps, hasLength(1));
      expect(d.latestSweepSteps.first.centerMhz, 88.0);
      // Total ingested keeps counting across passes.
      expect(d.sweepIngestedCount, 3);
    });

    test('bridge restart (same sweep_id after a gap) starts a new pass',
        () {
      // Review B1: the bridge restarts its sweep_id at 0, so a
      // rerun used to merge into the stale old pass (846 stale
      // steps on screen after full pass -> focus pass).
      final d = SdrDriver(host: '127.0.0.1', port: 49161);
      d.datagramForTest(_sweepStep(center: 88.0, sweepId: 0, stepIndex: 0));
      d.datagramForTest(_sweepStep(center: 915.0, sweepId: 0, stepIndex: 1));
      expect(d.latestSweepSteps, hasLength(2));
      // Restart: same sweep_id, first step after a gap with no steps.
      d.setLastSweepAtForTest(
          DateTime.now().subtract(const Duration(seconds: 10)));
      d.datagramForTest(_sweepStep(center: 1090.0, sweepId: 0, stepIndex: 0));
      expect(d.latestSweepId, 0);
      expect(d.latestSweepSteps, hasLength(1));
      expect(d.latestSweepSteps.first.centerMhz, 1090.0);
      expect(d.sweepIngestedCount, 3);
    });

    test('same-id step-0 with NO gap does not wipe the live pass', () {
      // A duplicate / late step-0 of the current pass, arriving
      // immediately: it overwrites its own center only.
      final d = SdrDriver(host: '127.0.0.1', port: 49161);
      d.datagramForTest(_sweepStep(center: 88.0, sweepId: 0, stepIndex: 0));
      d.datagramForTest(_sweepStep(center: 915.0, sweepId: 0, stepIndex: 1));
      d.datagramForTest(_sweepStep(
          center: 88.0, sweepId: 0, stepIndex: 0, energy: -70.0));
      expect(d.latestSweepSteps, hasLength(2));
      expect(
          d.latestSweepSteps
              .firstWhere((s) => s.centerMhz == 88.0)
              .energyDbfs,
          -70.0);
    });

    test('same center re-sent overwrites, does not duplicate', () {
      final d = SdrDriver(host: '127.0.0.1', port: 49161);
      d.datagramForTest(_sweepStep(
          center: 915.0, sweepId: 0, stepIndex: 0, energy: -80.0));
      d.datagramForTest(_sweepStep(
          center: 915.0, sweepId: 0, stepIndex: 0, energy: -60.0));
      expect(d.latestSweepSteps, hasLength(1));
      expect(d.latestSweepSteps.first.energyDbfs, -60.0);
    });

    test('malformed sweep_step counts, never crashes ingest', () {
      final d = SdrDriver(host: '127.0.0.1', port: 49161);
      d.datagramForTest(_sweepStep(center: 915.0, sweepId: 0, stepIndex: 0));
      expect(d.sweepIngestedCount, 1);
      // Missing center: malformed.
      d.datagramForTest(
          '{"v":1,"kind":"sweep_step","span_mhz":1.92,"energy_dbfs":-80.0,'
          '"noise_dbfs":-100.0,"bins_dbfs":[-90.0],"peaks":[],"t":1.0}');
      // Not JSON at all.
      d.datagramForTest('garbage');
      // Wrong kind: ignored by the sweep path (and by the band path).
      d.datagramForTest('{"v":1,"kind":"something_else","t":1.0}');
      expect(d.sweepIngestedCount, 1);
      expect(d.sweepMalformedCount, 1);
      expect(d.latestSweepSteps, hasLength(1));
    });

    test('sweep steps never become LinkSamples', () async {
      final d = SdrDriver(host: '127.0.0.1', port: 49199);
      addTearDown(d.dispose);
      d.datagramForTest(_sweepStep(center: 915.0, sweepId: 0, stepIndex: 0));
      d.datagramForTest(_sweepStep(center: 1090.0, sweepId: 0, stepIndex: 1));
      expect(d.latestSweepSteps, hasLength(2));
      final links = await d.poll();
      expect(links, isEmpty);
      // And the steps survive the poll (fresh, not pruned).
      expect(d.latestSweepSteps, hasLength(2));
    });

    test('band packets still become LinkSamples alongside sweeps',
        () async {
      final d = SdrDriver(host: '127.0.0.1', port: 49199);
      addTearDown(d.dispose);
      d.datagramForTest(_sweepStep(center: 915.0, sweepId: 0, stepIndex: 0));
      final nowSec = DateTime.now().millisecondsSinceEpoch / 1000.0;
      d.datagramForTest(
          '{"v":1,"kind":"band","radio":"rtlsdr0","band":"915",'
          '"center_mhz":915.0,"bw_mhz":20.0,"span_mhz":1.92,'
          '"energy_dbfs":-62.0,'
          '"noise_dbfs":-81.0,"peak_mhz":915.14,"peak_dbfs":-48.3,'
          '"bins_dbfs":[-80.0,-79.0,-78.0,-77.0,-76.0,-75.0,-74.0,-73.0],'
          '"t":$nowSec}');
      final links = await d.poll();
      expect(links, hasLength(1));
      expect(links.first.toNode, 'sdr:band-915');
      expect(d.latestSweepSteps, hasLength(1));
    });
  });

  group('SdrDriver.emptyPollIsError with sweeps', () {
    test('fresh driver with no data: empty poll is an error', () {
      final d = SdrDriver(host: '127.0.0.1', port: 49161);
      expect(d.emptyPollIsError, isTrue);
    });

    test('fresh sweep step: empty poll is NOT an error', () {
      final d = SdrDriver(host: '127.0.0.1', port: 49161);
      d.datagramForTest(_sweepStep(center: 915.0, sweepId: 0, stepIndex: 0));
      expect(d.emptyPollIsError, isFalse);
    });

    test('stale sweep: empty poll reads as an error again after 15 s',
        () {
      // Review: the dead-bridge re-error path had no test.
      final d = SdrDriver(host: '127.0.0.1', port: 49161);
      d.datagramForTest(_sweepStep(center: 915.0, sweepId: 0, stepIndex: 0));
      expect(d.emptyPollIsError, isFalse);
      // 10 s later: still fresh (maxBandAge is 15 s).
      d.setLastSweepAtForTest(
          DateTime.now().subtract(const Duration(seconds: 10)));
      expect(d.emptyPollIsError, isFalse);
      // 20 s later: the bridge is dead, the error returns.
      d.setLastSweepAtForTest(
          DateTime.now().subtract(const Duration(seconds: 20)));
      expect(d.emptyPollIsError, isTrue);
    });

    test('dispose clears the sweep store', () {
      final d = SdrDriver(host: '127.0.0.1', port: 49161);
      d.datagramForTest(_sweepStep(center: 915.0, sweepId: 0, stepIndex: 0));
      expect(d.latestSweepSteps, hasLength(1));
      d.dispose();
      expect(d.latestSweepSteps, isEmpty);
      expect(d.latestSweepId, -1);
      expect(d.lastSweepAt, isNull);
      // Counters are session totals: they survive dispose.
      expect(d.sweepIngestedCount, 1);
    });
  });

  group('AppState sweep aggregation', () {
    test('sweepSteps/sweepPeaks aggregate across SDR pollers', () {
      final state = AppState();
      addTearDown(state.dispose);
      final d = SdrDriver(host: '127.0.0.1', port: 49161);
      state.attachDriverForTest(d);
      expect(state.hasSdrDriver, isTrue);
      expect(state.hasSweepSteps, isFalse);
      expect(state.sweepSteps, isEmpty);
      d.datagramForTest(_sweepStep(
        center: 1090.0,
        sweepId: 0,
        stepIndex: 1,
        peaks: [
          {'freq_mhz': 1090.15, 'dbfs': -59.1},
        ],
      ));
      d.datagramForTest(_sweepStep(center: 88.0, sweepId: 0, stepIndex: 0));
      expect(state.hasSweepSteps, isTrue);
      expect(state.sweepSteps.map((s) => s.centerMhz).toList(),
          [88.0, 1090.0]);
      expect(state.sweepPeaks, hasLength(1));
      expect(state.sweepPeaks.first.freqMhz, 1090.15);
    });
  });
}
