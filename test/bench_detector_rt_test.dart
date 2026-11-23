/// B10 1-bit detector bench tests (accuracy arm only).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/services/bench_csi.dart' show kBenchPending;
import 'package:outride/services/bench_detector_rt.dart';
import 'package:outride/services/fusion_bench_harness.dart';

import 'bench_fixtures.dart';

BenchConfig _config(Directory dir) =>
    BenchConfig(sessionsDir: dir, nodes: benchFixtureNodes());

void main() {
  group('runDetectorBench', () {
    test('no input → SKIPPED with the exact pending string', () async {
      final dir =
          await Directory.systemTemp.createTemp('bench_b10_empty');
      try {
        final outcome = runDetectorBench(_config(dir));
        expect(outcome.skipped, isTrue);
        expect(outcome.skipReason, kBenchPending);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('rejected file listed with reason', () async {
      final dir = await Directory.systemTemp.createTemp('bench_b10_rej');
      try {
        await writeRfSession(dir, 'recorder.csv', kBenchRecorderCsv);
        final outcome = runDetectorBench(_config(dir));
        expect(outcome.skipped, isTrue);
        expect(outcome.rejected.keys, contains('recorder.csv'));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('no node geometry → SKIPPED with the exact pending string '
        '(kBenchPending, not a literal)', () async {
      final dir =
          await Directory.systemTemp.createTemp('bench_b10_nogeo');
      try {
        await writeRfSession(dir, 'fixture.csv', kBenchFixtureCsv);
        final config =
            BenchConfig(sessionsDir: dir, nodes: const {});
        final outcome = runDetectorBench(config);
        expect(outcome.skipped, isTrue);
        expect(outcome.skipReason, kBenchPending);
        expect(outcome.rejected.keys, contains('(nodes)'));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('runs on one minimal valid session; cost arm stays N/A',
        () async {
      final dir = await Directory.systemTemp.createTemp('bench_b10_run');
      try {
        await writeRfSession(dir, 'fixture.csv', kBenchFixtureCsv);
        final outcome = runDetectorBench(_config(dir));
        expect(outcome.skipped, isFalse);
        expect(outcome.sessionsRun, ['fixture.csv']);
        expect(outcome.verdicts.length, 3);
        // Accuracy verdicts name the documented numbers.
        expect(outcome.verdicts[0].detail, contains('mean back-projection'));
        expect(outcome.verdicts[1].detail, contains('RTI'));
        // Cost arm: QUEUED-BLOCKED, reported as N/A — never a PASS
        // on accuracy alone.
        final cost = outcome.verdicts[2];
        expect(cost.notApplicable, isTrue);
        expect(cost.passed, isFalse);
        expect(cost.bar, contains('QUEUED-BLOCKED'));
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
