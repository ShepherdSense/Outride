/// Bench recorder end-to-end tests (bench_record.dart):
/// record → export → re-import through the harness loader →
/// the B1 harness RUNS (never a format rejection).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/models/link_sample.dart';
import 'package:outride/services/bench_record.dart';
import 'package:outride/services/fusion_bench_harness.dart';

import 'bench_fixtures.dart';

BenchRecordConfig _config() => const BenchRecordConfig(
      label: 'e2e',
      template: BenchSessionTemplate.movingCrossings,
      waypointA: (10.0, 10.0),
      waypointB: (30.0, 10.0),
      baselineSeconds: 5,
    );

LinkSample _sample(String from, String to, double snr) => LinkSample(
      timestamp: DateTime.now(),
      fromNode: from,
      toNode: to,
      snr: snr,
    );

Directory _sessionsDir(Directory docs) =>
    Directory('${docs.path}/bench_sessions');

void main() {
  group('BenchRecorder validation', () {
    test('moving template without waypoints is refused', () async {
      final dir = await Directory.systemTemp.createTemp('bench_rec_v');
      try {
        final rec = BenchRecorder();
        final path = await rec.start(
          const BenchRecordConfig(
            label: 'bad',
            template: BenchSessionTemplate.movingCrossings,
          ),
          benchFixtureNodes(),
          dir,
        );
        expect(path, isEmpty);
        expect(rec.lastError, contains('waypoints'));
        expect(rec.isRecording, isFalse);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('empty label starts with a fallback file name', () async {
      final dir = await Directory.systemTemp.createTemp('bench_rec_l');
      try {
        final rec = BenchRecorder();
        final path = await rec.start(
          const BenchRecordConfig(
            label: ' ',
            template: BenchSessionTemplate.emptyBaseline,
          ),
          benchFixtureNodes(),
          dir,
        );
        // Empty label is not a validation error in the recorder;
        // the file name falls back to the template + timestamp.
        // What matters: it starts and writes a file.
        expect(path, isNotEmpty);
        await rec.stop();
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('BenchRecorder end-to-end', () {
    test('empty recording exports a file the harness rejects, '
        'with a reason', () async {
      final dir = await Directory.systemTemp.createTemp('bench_rec_e');
      try {
        final rec = BenchRecorder();
        final path =
            await rec.start(_config(), benchFixtureNodes(), dir);
        expect(path, isNotEmpty);
        final summary = await rec.stop();
        expect(summary, isNotEmpty);
        final files = await BenchRecorder.listBenchSessions(dir);
        expect(files.length, 1);
        final load = loadSessions(_sessionsDir(dir));
        expect(load.sessions, isEmpty);
        expect(load.rejected.length, 1);
        expect(load.rejected.values.first, isNotEmpty);
        // The rejection carries the recorder summary (rows +
        // duration) from the meta sidecar, not just "no data rows".
        expect(load.rejected.values.first, contains('recorder summary'));
        expect(load.rejected.values.first, contains('0 rows'));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test(
        'record → export → re-import → B1 harness RUNS on the file',
        () async {
      final dir = await Directory.systemTemp.createTemp('bench_rec_e2e');
      try {
        final rec = BenchRecorder();
        final path =
            await rec.start(_config(), benchFixtureNodes(), dir);
        expect(path, isNotEmpty);
        // Vacant baseline window (snr 20 on all three links).
        for (var i = 0; i < 3; i++) {
          rec.recordLink(_sample('n0', 'n1', 20.0));
          rec.recordLink(_sample('n1', 'n2', 20.0));
          rec.recordLink(_sample('n2', 'n0', 20.0));
        }
        // Wait out the 5 s baseline window in wall time.
        await Future<void>.delayed(const Duration(seconds: 6));
        // Disturbed window (snr 8 — deep dips vs the baseline).
        for (var i = 0; i < 5; i++) {
          rec.recordLink(_sample('n0', 'n1', 8.0));
          rec.recordLink(_sample('n1', 'n2', 8.0));
          rec.recordLink(_sample('n2', 'n0', 8.0));
        }
        final summary = await rec.stop();
        expect(summary, isNotEmpty);
        final files = await BenchRecorder.listBenchSessions(dir);
        expect(files.length, 1);
        final csv = await files.first.readAsString();
        expect(csv, contains('dip_db'));
        expect(csv, contains('truth_x'));
        expect(csv, contains('# SECTION backhaul'));

        // Re-import through the harness loader.
        final sessionsDir = _sessionsDir(dir);
        final load = loadSessions(sessionsDir);
        expect(load.rejected, isEmpty);
        expect(load.sessions.length, 1);
        final s = load.sessions.first;
        expect(s.rows.length, greaterThan(5));
        expect(s.rows.last.dipDb, greaterThan(0.0));
        expect(s.truthAt(s.polls.last), isNotNull);

        // Nodes sidecar round-trips.
        final nodes =
            BenchRecorder.loadBenchNodes(sessionsDir, s.name);
        expect(nodes.keys, containsAll(['n0', 'n1', 'n2']));

        // The B1 harness RUNS on the recorded file — never a
        // format rejection.
        final config =
            BenchConfig(sessionsDir: sessionsDir, nodes: nodes);
        final outcome = runFusionBench(config);
        expect(outcome.skipped, isFalse);
        expect(outcome.sessionsRun, contains(s.name));
      } finally {
        await dir.delete(recursive: true);
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
