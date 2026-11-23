/// B14 KLD-divergence integrity bench tests.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/services/bench_csi.dart' show kBenchPending;
import 'package:outride/services/bench_kld.dart';
import 'package:outride/services/fusion_bench.dart';
import 'package:outride/services/fusion_bench_harness.dart';

import 'bench_fixtures.dart';

BenchConfig _config(Directory dir) =>
    BenchConfig(sessionsDir: dir, nodes: benchFixtureNodes());

void main() {
  group('gaussianKld', () {
    test('identical Gaussians score ~0; distant ones score high', () {
      const g = Gaussian2(x: 0, y: 0, pxx: 1, pxy: 0, pyy: 1);
      expect(gaussianKld(g, g), closeTo(0.0, 1e-9));
      const far =
          Gaussian2(x: 10, y: 0, pxx: 1, pxy: 0, pyy: 1);
      expect(gaussianKld(g, far), greaterThan(kB14Tau));
    });
  });

  group('runKldBench', () {
    test('no input → SKIPPED with the exact pending string', () async {
      final dir =
          await Directory.systemTemp.createTemp('bench_b14_empty');
      try {
        final outcome = runKldBench(_config(dir));
        expect(outcome.skipped, isTrue);
        expect(outcome.skipReason, kBenchPending);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('rejected file listed with reason', () async {
      final dir = await Directory.systemTemp.createTemp('bench_b14_rej');
      try {
        await writeRfSession(dir, 'recorder.csv', kBenchRecorderCsv);
        final outcome = runKldBench(_config(dir));
        expect(outcome.skipped, isTrue);
        expect(outcome.rejected.keys, contains('recorder.csv'));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('runs on one minimal valid session and scores the three bars',
        () async {
      final dir = await Directory.systemTemp.createTemp('bench_b14_run');
      try {
        await writeRfSession(dir, 'fixture.csv', kBenchFixtureCsv);
        final outcome = runKldBench(_config(dir));
        expect(outcome.skipped, isFalse);
        expect(outcome.sessionsRun, ['fixture.csv']);
        expect(outcome.verdicts.length, 3);
        expect(outcome.verdicts.map((v) => v.bar), containsAll([
          contains('drift detected'),
          contains('unmoved'),
          contains('not suppressed'),
        ]));
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
