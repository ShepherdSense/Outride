/// B7 CSI activity-typing tests (k-NN runs; SVM PENDING).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/services/bench_csi.dart' show kBenchPending;
import 'package:outride/services/bench_csi_typing.dart';

import 'bench_fixtures.dart';

/// Two present + two absent sessions, 100 packets each at 10 Hz
/// (10 s). Present sessions carry a step disturbance; absent ones
/// are steady. Windows of 50 → two windows per session.
Future<void> _writeSet(Directory dir) async {
  for (var i = 0; i < 2; i++) {
    await writeCsiSession(
      dir,
      'present$i.csv',
      type: 'present',
      ampMean: steppedAmp(100, 1.0, 0.5, 20 + i * 5),
    );
    await writeCsiSession(
      dir,
      'absent$i.csv',
      type: 'absent',
      ampMean: steadyAmp(100, 1.0),
    );
  }
}

void main() {
  group('runCsiTypingBench', () {
    test('no input → SKIPPED with the exact pending string', () async {
      final dir =
          await Directory.systemTemp.createTemp('bench_b7_empty');
      try {
        final outcome = runCsiTypingBench(dir);
        expect(outcome.skipped, isTrue);
        expect(outcome.skipReason, kBenchPending);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('rejected file listed with reason', () async {
      final dir = await Directory.systemTemp.createTemp('bench_b7_rej');
      try {
        await File('${dir.path}/bad.csv')
            .writeAsString('t_iso,link_id\n2026-11-21T00:00:00Z,x\n');
        final outcome = runCsiTypingBench(dir);
        expect(outcome.skipped, isTrue);
        expect(outcome.rejected.keys, contains('bad.csv'));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('runs on four minimal sessions; k-NN scores, SVM stays N/A',
        () async {
      final dir = await Directory.systemTemp.createTemp('bench_b7_run');
      try {
        await _writeSet(dir);
        final outcome = runCsiTypingBench(dir);
        expect(outcome.skipped, isFalse);
        expect(outcome.sessionsRun.length, 4);
        expect(outcome.verdicts.length, 3);
        final knn = outcome.verdicts[0];
        expect(knn.detail, contains('k-NN'));
        expect(knn.detail, contains('accuracy'));
        expect(knn.bar, contains('80%'));
        // SVM: no weights sidecar — N/A, never an untrained default.
        final svm = outcome.verdicts[2];
        expect(svm.notApplicable, isTrue);
        expect(svm.bar, contains('B7 SVM'));
        expect(svm.detail, contains('bench.svm.json'));
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
