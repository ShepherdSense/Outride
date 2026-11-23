/// B4 bounded-replay bench tests (bench_replay.dart).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/services/bench_csi.dart' show kBenchPending;
import 'package:outride/services/bench_replay.dart';
import 'package:outride/services/fusion_bench_harness.dart';

import 'bench_fixtures.dart';

BenchConfig _config(Directory dir) =>
    BenchConfig(sessionsDir: dir, nodes: benchFixtureNodes());

void main() {
  group('runReplayBench', () {
    test('no input → SKIPPED with the exact pending string', () async {
      final dir =
          await Directory.systemTemp.createTemp('bench_b4_empty');
      try {
        final outcome = runReplayBench(_config(dir));
        expect(outcome.skipped, isTrue);
        expect(outcome.skipReason, kBenchPending);
        expect(outcome.armScores, isEmpty);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('rejected file listed with reason', () async {
      final dir =
          await Directory.systemTemp.createTemp('bench_b4_rej');
      try {
        await writeRfSession(dir, 'recorder.csv', kBenchRecorderCsv);
        final outcome = runReplayBench(_config(dir));
        expect(outcome.skipped, isTrue);
        expect(outcome.skipReason, kBenchPending);
        expect(outcome.rejected.keys, contains('recorder.csv'));
        expect(outcome.rejected['recorder.csv'], contains('dip_db'));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('too-short session rejected with reason, not scored', () async {
      final dir =
          await Directory.systemTemp.createTemp('bench_b4_short');
      try {
        await writeRfSession(dir, 'one.csv', kBenchOnePollCsv);
        final outcome = runReplayBench(_config(dir));
        expect(outcome.skipped, isTrue);
        expect(outcome.rejected['one.csv'], contains('too short'));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('runs on one minimal valid session and scores', () async {
      final dir =
          await Directory.systemTemp.createTemp('bench_b4_run');
      try {
        await writeRfSession(dir, 'fixture.csv', kBenchFixtureCsv);
        final outcome = runReplayBench(_config(dir));
        expect(outcome.skipped, isFalse);
        expect(outcome.sessionsRun, ['fixture.csv']);
        expect(outcome.verdicts.length, 2);
        expect(outcome.armScores.keys,
            containsAll(['CI/metropolis:in-order', 'CI/metropolis:late']));
        final late = outcome.verdicts.first;
        expect(late.bar, contains('timing bias'));
        // Deadline verdict names the wall-clock nature (R4).
        expect(outcome.verdicts.last.bar, contains('wall-clock'));
        // The late run preserves poll count: the midpoint hold never
        // merges two polls' rows (a 1.0 s hold at ≤1 s spacing did).
        final inOrder =
            outcome.armScores['CI/metropolis:in-order']!;
        final lateArm = outcome.armScores['CI/metropolis:late']!;
        expect(lateArm.samples, inOrder.samples);
        expect(inOrder.samples, greaterThan(0));
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
