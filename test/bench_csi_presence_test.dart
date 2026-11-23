/// B12 / B-W1..B-W4 CSI-presence tests (bench_csi_presence.dart).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/services/bench_csi.dart' show kBenchPending;
import 'package:outride/services/bench_csi_presence.dart';

import 'bench_fixtures.dart';

Future<void> _writeSet(Directory dir) async {
  // B12 / B-W1 / B-W3: two present + two absent, 100 packets each.
  for (var i = 0; i < 2; i++) {
    await writeCsiSession(
      dir,
      'present$i.csv',
      type: 'present',
      ampMean: steppedAmp(100, 1.0, 0.5, 20 + i * 5),
      phaseMean: noisyPhase(100, 0.3),
    );
    await writeCsiSession(
      dir,
      'absent$i.csv',
      type: 'absent',
      ampMean: steadyAmp(100, 1.0),
    );
  }
  // B-W4: still (12 bpm breathing, 60 s at 2 Hz) + absent + fan-on
  // controls, perfectly steady so the breathing band is silent.
  await writeCsiSession(
    dir,
    'still.csv',
    type: 'still',
    ampMean: breathingAmp(12, 60, 2),
    stepS: 0.5,
    ambientCalibrationS: 1.0,
    breathingBpmRef: 12,
  );
  await writeCsiSession(
    dir,
    'absent_long.csv',
    type: 'absent',
    ampMean: steadyAmp(120, 1.0, 0.0),
    stepS: 0.5,
  );
  await writeCsiSession(
    dir,
    'fan_on.csv',
    type: 'fan-on',
    ampMean: steadyAmp(120, 1.0, 0.0),
    stepS: 0.5,
  );
}

void main() {
  group('CSI presence benches', () {
    test('no input → SKIPPED with the exact pending string', () async {
      final dir =
          await Directory.systemTemp.createTemp('bench_csi_empty');
      try {
        for (final run in [
          runCsiFeatureBench,
          runSplitNodePresenceBench,
          runSingleBoardMotionBench,
          runPhaseVarianceBench,
          runBreathingBench,
        ]) {
          final outcome = run(dir);
          expect(outcome.skipped, isTrue);
          expect(outcome.skipReason, kBenchPending);
        }
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('each bench runs on the minimal fixture set', () async {
      final dir =
          await Directory.systemTemp.createTemp('bench_csi_run');
      try {
        await _writeSet(dir);
        final runs = {
          'B12': runCsiFeatureBench(dir),
          'B-W1': runSplitNodePresenceBench(dir),
          'B-W2': runSingleBoardMotionBench(dir),
          'B-W3': runPhaseVarianceBench(dir),
          'B-W4': runBreathingBench(dir),
        };
        for (final e in runs.entries) {
          expect(e.value.skipped, isFalse, reason: e.key);
          expect(e.value.verdicts, isNotEmpty, reason: e.key);
          expect(e.value.verdicts.first.bar, contains(e.key),
              reason: e.key);
          for (final v in e.value.verdicts) {
            expect(v.detail, isNotEmpty, reason: '${e.key} detail');
          }
        }
        // B-W4 breathing: the still session's peak is within
        // tolerance of the 12 bpm reference, and the steady
        // controls raise no claim.
        final bw4 = runs['B-W4']!;
        expect(bw4.verdicts.first.detail, contains('within tolerance'));
        expect(bw4.verdicts.last.detail, contains('FAR'));
      } finally {
        await dir.delete(recursive: true);
      }
    });
    test('B-W4 hit rate is over ALL windows, not claimed windows',
        () async {
      final dir =
          await Directory.systemTemp.createTemp('bench_bw4_denom');
      try {
        // Still session, 3 × 60 s windows at 2 Hz: the first window
        // breathes at 12 bpm; the other two are perfectly steady
        // (jitter 0.0, subcarrier spread 0.0) so they claim nothing.
        // Old denominator (claimed) would score 1/1 = 100% PASS;
        // the pass bar says "≥80% of 60 s windows", so the honest
        // score is 1/3 = FAIL.
        final amp = [
          ...breathingAmp(12, 60, 2),
          ...steadyAmp(240, 1.0, 0.0),
        ];
        await writeCsiSession(
          dir,
          'still3.csv',
          type: 'still',
          ampMean: amp,
          stepS: 0.5,
          ambientCalibrationS: 1.0,
          breathingBpmRef: 12,
          subcarrierSpread: 0.0,
        );
        await writeCsiSession(
          dir,
          'absent_long.csv',
          type: 'absent',
          ampMean: steadyAmp(120, 1.0, 0.0),
          stepS: 0.5,
          subcarrierSpread: 0.0,
        );
        await writeCsiSession(
          dir,
          'fan_on.csv',
          type: 'fan-on',
          ampMean: steadyAmp(120, 1.0, 0.0),
          stepS: 0.5,
          subcarrierSpread: 0.0,
        );
        final outcome = runBreathingBench(dir);
        expect(outcome.skipped, isFalse);
        final verdict = outcome.verdicts.first;
        expect(verdict.detail, contains('1/3 windows'));
        expect(verdict.detail, contains('1 claimed'));
        expect(verdict.passed, isFalse);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
