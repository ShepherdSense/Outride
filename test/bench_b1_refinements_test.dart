/// B1 refinement extensions tests (bench_b1_refinements.dart):
/// median NEES + inflation k, Gaussian log score, λ_min/λ_max of
/// the NEES matrix, block-bootstrap RMSE bars.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/services/bench_b1_refinements.dart';
import 'package:outride/services/bench_run.dart';
import 'package:outride/services/fusion_bench_harness.dart';

import 'bench_fixtures.dart';

void main() {
  group('B1 refinements', () {
    test('runs on the minimal fixture session with finite scores',
        () async {
      final dir =
          await Directory.systemTemp.createTemp('bench_b1_ref');
      try {
        await writeRfSession(dir, 'fixture.csv', kBenchFixtureCsv);
        final load = loadSessions(dir);
        expect(load.sessions.length, 1);
        final s = load.sessions.first;
        final config =
            BenchConfig(sessionsDir: dir, nodes: benchFixtureNodes());
        final polls = replaySession(s, config);
        const arm = 'ICI/metropolis';
        final errs = normalizedErrors(polls, arm);
        expect(errs.length, 5);
        final med = medianNees(errs);
        expect(med.isFinite, isTrue);
        // Inflation is median NEES over the χ²₂ median (Rønning).
        expect(inflationK(errs) * kChi2Median2Dof,
            closeTo(med, 1e-9));
        final score = gaussianLogScore(polls, arm);
        expect(score.total.isFinite, isTrue);
        expect(score.total,
            closeTo(score.neesTerm + score.logDetTerm, 1e-9));
        final eig = neesEigenvalues(errs);
        expect(eig.lambdaMax, greaterThanOrEqualTo(eig.lambdaMin));
        expect(eig.lambdaMin, greaterThanOrEqualTo(0.0));
        final boot = bootstrapRmse(polls, arm);
        expect(boot.rmse.isFinite, isTrue);
        expect(boot.low, lessThanOrEqualTo(boot.rmse));
        expect(boot.rmse, lessThanOrEqualTo(boot.high));
        expect(boot.low, greaterThanOrEqualTo(0.0));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('a too-short session is rejected at the bench loader', () async {
      final dir =
          await Directory.systemTemp.createTemp('bench_b1_short');
      try {
        await writeRfSession(dir, 'one.csv', kBenchOnePollCsv);
        // The harness loader parses it (1 poll is valid CSV); the
        // bench-level loader rejects it as too short to score.
        final load = loadSessions(dir);
        expect(load.sessions.length, 1);
        final rf = loadRfSessions(dir);
        expect(rf.rejected.keys, contains('one.csv'));
        expect(rf.sessions, isEmpty);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
