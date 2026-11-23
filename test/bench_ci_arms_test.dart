/// B5 CI-arms bench tests (bench_ci_arms.dart).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/services/bench_ci_arms.dart';
import 'package:outride/services/bench_csi.dart' show kBenchPending;
import 'package:outride/services/fusion_bench.dart';
import 'package:outride/services/fusion_bench_harness.dart';

import 'bench_fixtures.dart';

BenchConfig _config(Directory dir) =>
    BenchConfig(sessionsDir: dir, nodes: benchFixtureNodes());

void main() {
  group('splitCiFuse', () {
    test('f=0 fuses independent parts; f=1 equals plain CI', () {
      const a = Gaussian2(x: 0, y: 0, pxx: 1, pxy: 0, pyy: 1);
      const b = Gaussian2(x: 2, y: 0, pxx: 1, pxy: 0, pyy: 1);
      final split1 = splitCiFuse(a, b, 1.0);
      final ci = ciFuse(a, b);
      expect(split1.fused.x, closeTo(ci.fused.x, 1e-9));
      expect(split1.fused.pxx, closeTo(ci.fused.pxx, 1e-9));
      final split0 = splitCiFuse(a, b, 0.0);
      expect(split0.fused.x, closeTo(1.0, 1e-9));
      expect(split0.fused.pxx, lessThan(1.0));
    });

    test('shared-dip fraction is 0 with no shared disturbed link '
        '(unused heuristic — B5.2 is QUEUED-BLOCKED, wired to no row)',
        () {
      final s = parseSessionCsv('f.csv', kBenchFixtureCsv);
      final f = sharedDipFraction(s, s.polls.first, 'n0', 'n1', 6.0);
      expect(f, greaterThanOrEqualTo(0.0));
      expect(f, lessThanOrEqualTo(1.0));
    });
  });

  group('runCiArmsBench', () {
    test('no input → SKIPPED with the exact pending string', () async {
      final dir =
          await Directory.systemTemp.createTemp('bench_b5_empty');
      try {
        final outcome = runCiArmsBench(_config(dir));
        expect(outcome.skipped, isTrue);
        expect(outcome.skipReason, kBenchPending);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('rejected file listed with reason', () async {
      final dir = await Directory.systemTemp.createTemp('bench_b5_rej');
      try {
        await writeRfSession(dir, 'recorder.csv', kBenchRecorderCsv);
        final outcome = runCiArmsBench(_config(dir));
        expect(outcome.skipped, isTrue);
        expect(outcome.rejected.keys, contains('recorder.csv'));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('runs on one minimal valid session, three arms scored '
        '(B5.2 demoted — no split-ci verdict or arm score)', () async {
      final dir = await Directory.systemTemp.createTemp('bench_b5_run');
      try {
        await writeRfSession(dir, 'fixture.csv', kBenchFixtureCsv);
        final outcome = runCiArmsBench(_config(dir));
        expect(outcome.skipped, isFalse);
        expect(outcome.sessionsRun, ['fixture.csv']);
        expect(outcome.verdicts.length, 3);
        expect(outcome.verdicts.map((v) => v.bar),
            containsAll([contains('B5.3'), contains('B5.4'), contains('B5.5')]));
        expect(outcome.armScores.keys, containsAll([
          'B5.3/sequential-ci',
          'B5.5/per-link-variance',
        ]));
        expect(outcome.armScores.keys, isNot(contains('B5.2/split-ci')));
        expect(
            outcome.armScores.keys.any((k) => k.startsWith('B5.4/')),
            isTrue);
        for (final a in outcome.armScores.values) {
          expect(a.samples, greaterThan(0));
        }
        // B5.3 now has a real criterion: the detail reports the gap.
        final b53 = outcome.verdicts
            .firstWhere((v) => v.bar.contains('B5.3'));
        expect(b53.detail, contains('gap'));
        // B5.4 states its best-τ selection is in-sample.
        final b54 = outcome.verdicts
            .firstWhere((v) => v.bar.contains('B5.4'));
        expect(b54.detail, contains('in-sample'));
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
