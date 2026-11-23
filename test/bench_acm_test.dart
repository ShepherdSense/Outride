/// B11 ACM path-splitting bench tests (LBP-based).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/services/bench_acm.dart';
import 'package:outride/services/bench_csi.dart' show kBenchPending;
import 'package:outride/services/fusion_bench_harness.dart';

import 'bench_fixtures.dart';

BenchConfig _config(Directory dir) =>
    BenchConfig(sessionsDir: dir, nodes: benchFixtureNodes());

void main() {
  group('runAcmBench', () {
    test('no input → SKIPPED with the exact pending string', () async {
      final dir =
          await Directory.systemTemp.createTemp('bench_b11_empty');
      try {
        final outcome = runAcmBench(_config(dir));
        expect(outcome.skipped, isTrue);
        expect(outcome.skipReason, kBenchPending);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('rejected file listed with reason', () async {
      final dir = await Directory.systemTemp.createTemp('bench_b11_rej');
      try {
        await writeRfSession(dir, 'recorder.csv', kBenchRecorderCsv);
        final outcome = runAcmBench(_config(dir));
        expect(outcome.skipped, isTrue);
        expect(outcome.rejected.keys, contains('recorder.csv'));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('runs on one minimal valid session and states its baseline',
        () async {
      final dir = await Directory.systemTemp.createTemp('bench_b11_run');
      try {
        await writeRfSession(dir, 'fixture.csv', kBenchFixtureCsv);
        final outcome = runAcmBench(_config(dir));
        expect(outcome.skipped, isFalse);
        expect(outcome.sessionsRun, ['fixture.csv']);
        expect(outcome.verdicts.length, 2);
        expect(outcome.verdicts[0].detail,
            contains('MSSIM-equivalent (NCC)'));
        expect(outcome.verdicts[1].detail,
            contains('localisation error'));
        // Baseline is the harness LBP reconstructor (R7).
        expect(outcome.verdicts[0].bar, contains('baseline'));
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
