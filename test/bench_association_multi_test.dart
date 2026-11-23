/// B9 multi-target association bench tests.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/services/bench_association_multi.dart';
import 'package:outride/services/bench_csi.dart' show kBenchPending;
import 'package:outride/services/fusion_bench_harness.dart';

import 'bench_fixtures.dart';

BenchConfig _config(Directory dir) =>
    BenchConfig(sessionsDir: dir, nodes: benchFixtureNodes());

void main() {
  group('runAssociationMultiBench', () {
    test('no input → SKIPPED with the exact pending string', () async {
      final dir =
          await Directory.systemTemp.createTemp('bench_b9_empty');
      try {
        final outcome = runAssociationMultiBench(_config(dir));
        expect(outcome.skipped, isTrue);
        expect(outcome.skipReason, kBenchPending);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('rejected file listed with reason', () async {
      final dir = await Directory.systemTemp.createTemp('bench_b9_rej');
      try {
        await writeRfSession(dir, 'recorder.csv', kBenchRecorderCsv);
        final outcome = runAssociationMultiBench(_config(dir));
        expect(outcome.skipped, isTrue);
        expect(outcome.rejected.keys, contains('recorder.csv'));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('runs on one minimal valid session and scores the pass bars',
        () async {
      final dir = await Directory.systemTemp.createTemp('bench_b9_run');
      try {
        await writeRfSession(dir, 'fixture.csv', kBenchFixtureCsv);
        final outcome = runAssociationMultiBench(_config(dir));
        expect(outcome.skipped, isFalse);
        expect(outcome.sessionsRun, ['fixture.csv']);
        expect(outcome.verdicts.length, 4);
        expect(outcome.verdicts.map((v) => v.bar), containsAll([
          contains('OMAT'),
          contains('Q95'),
          contains('cardinality'),
          contains('100 ms'),
        ]));
        for (final v in outcome.verdicts) {
          expect(v.detail, isNotEmpty);
        }
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
