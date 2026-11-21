import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/models/tracking.dart';
import 'package:outride/services/fusion_bench.dart';
import 'package:outride/services/fusion_bench_association.dart';
import 'package:outride/services/fusion_bench_harness.dart';

/// MECHANICS-ONLY fixture (hand-constructed, 3 nodes, 5 polls).
/// It verifies that the harness RUNS — parsing, local estimation,
/// fusion, association, scoring — and produces finite, structurally
/// consistent output. Its numbers are NEVER bench results and are
/// never reported as such; the bench measures only recorded sessions.
const _fixtureCsv = '''
t_iso,link_key,from_node,to_node,snr_db,dip_db,truth_x,truth_y,truth_id
2026-11-21T00:00:00Z,n0>n1,n0,n1,20.0,12.0,10.0,10.0,A
2026-11-21T00:00:00Z,n1>n2,n1,n2,20.0,4.0,10.0,10.0,A
2026-11-21T00:00:00Z,n2>n0,n2,n0,20.0,8.0,10.0,10.0,A
2026-11-21T00:00:01Z,n0>n1,n0,n1,20.0,13.0,15.0,10.0,A
2026-11-21T00:00:01Z,n1>n2,n1,n2,20.0,5.0,15.0,10.0,A
2026-11-21T00:00:01Z,n2>n0,n2,n0,20.0,7.0,15.0,10.0,A
2026-11-21T00:00:02Z,n0>n1,n0,n1,20.0,12.0,20.0,10.0,A
2026-11-21T00:00:02Z,n1>n2,n1,n2,20.0,7.0,20.0,10.0,A
2026-11-21T00:00:02Z,n2>n0,n2,n0,20.0,6.5,20.0,10.0,A
2026-11-21T00:00:03Z,n0>n1,n0,n1,20.0,10.0,25.0,10.0,A
2026-11-21T00:00:03Z,n1>n2,n1,n2,20.0,9.0,25.0,10.0,A
2026-11-21T00:00:03Z,n2>n0,n2,n0,20.0,5.0,25.0,10.0,A
2026-11-21T00:00:04Z,n0>n1,n0,n1,20.0,8.0,30.0,10.0,A
2026-11-21T00:00:04Z,n1>n2,n1,n2,20.0,3.0,30.0,10.0,A
2026-11-21T00:00:04Z,n2>n0,n2,n0,20.0,4.0,30.0,10.0,A
''';

/// Recorder-format CSV (no dip_db / truth columns): NOT a bench
/// session — must be rejected, never scored.
const _recorderCsv = '''
t_iso,link_key,from_node,to_node,snr_db
2026-11-21T00:00:00Z,n0>n1,n0,n1,20.0
''';

/// A session with a truncated data row (second row stops after
/// snr_db). Must be rejected as malformed, never crash the run.
const _truncatedCsv = '''
t_iso,link_key,from_node,to_node,snr_db,dip_db,truth_x,truth_y,truth_id
2026-11-21T00:00:00Z,n0>n1,n0,n1,20.0,12.0,10.0,10.0,A
2026-11-21T00:00:01Z,n0>n1,n0,n1,20.0,13.0
''';

/// Multi-target fixture (B2): two targets, disjoint link sets.
/// Target A (5, 0) disturbs the n0-n1 and n2-n3 links; target B
/// (6, 10) disturbs the n4-n5 link, whose midpoint (6, 1) sits
/// nearest the fused estimate even though the estimate itself is
/// nearest truth A — so the kinematics match is a real false track.
/// Poll 2 drops B: the match flips back to A (a truth-id switch).
const _multiTargetCsv = '''
t_iso,link_key,from_node,to_node,snr_db,dip_db,truth_x,truth_y,truth_id
2026-11-21T00:00:00Z,n0>n1,n0,n1,20.0,12.0,5.0,0.0,A
2026-11-21T00:00:00Z,n2>n3,n2,n3,20.0,12.0,5.0,0.0,A
2026-11-21T00:00:00Z,n4>n5,n4,n5,20.0,12.0,6.0,10.0,B
2026-11-21T00:00:01Z,n0>n1,n0,n1,20.0,12.0,5.0,0.0,A
2026-11-21T00:00:01Z,n2>n3,n2,n3,20.0,12.0,5.0,0.0,A
''';

/// Zero-baseline fixture (S2): one target at the crossing of two
/// links whose midpoints coincide at (0, 0), so every local estimate
/// is (0, 0), every poll associates, and nothing ever switches.
/// The last poll drops the n2-n3 link — a handover that does not
/// move the fused estimate, so CI fragments nothing over 1 handover
/// poll. Both relative bars therefore have a zero baseline.
const _zeroBaselineCsv = '''
t_iso,link_key,from_node,to_node,snr_db,dip_db,truth_x,truth_y,truth_id
2026-11-21T00:00:00Z,n0>n1,n0,n1,20.0,12.0,0.0,0.0,A
2026-11-21T00:00:00Z,n2>n3,n2,n3,20.0,12.0,0.0,0.0,A
2026-11-21T00:00:01Z,n0>n1,n0,n1,20.0,12.0,0.0,0.0,A
2026-11-21T00:00:01Z,n2>n3,n2,n3,20.0,12.0,0.0,0.0,A
2026-11-21T00:00:02Z,n0>n1,n0,n1,20.0,12.0,0.0,0.0,A
2026-11-21T00:00:02Z,n2>n3,n2,n3,20.0,12.0,0.0,0.0,A
2026-11-21T00:00:03Z,n0>n1,n0,n1,20.0,12.0,0.0,0.0,A
''';

Map<String, NodePosition> _nodes() => {
      'n0': NodePosition(nodeId: 'n0', x: 0, y: 0),
      'n1': NodePosition(nodeId: 'n1', x: 40, y: 0),
      'n2': NodePosition(nodeId: 'n2', x: 20, y: 35),
    };

void main() {
  group('parseSessionCsv', () {
    test('parses the session format', () {
      final s = parseSessionCsv('fixture.csv', _fixtureCsv);
      expect(s.polls.length, 5);
      expect(s.rows.length, 15);
      expect(s.truthAt(s.polls.first), (10.0, 10.0));
      expect(s.truthIdsAt(s.polls.first), {'A'});
    });

    test('rejects recorder-format CSVs without dip/truth columns', () {
      expect(
        () => parseSessionCsv('recording.csv', _recorderCsv),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('dip_db'),
        )),
      );
    });

    test('rejects empty files', () {
      expect(
        () => parseSessionCsv('empty.csv', ''),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects a truncated data row as malformed (S3)', () {
      // Before the fix this threw RangeError on the column index
      // and loadSessions did not catch it, so one short row killed
      // the whole run. It must be a FormatException so the file
      // lands in `rejected` and the run continues.
      expect(
        () => parseSessionCsv('short.csv', _truncatedCsv),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('short row'),
        )),
      );
    });
  });

  group('loadSessions', () {
    test('missing directory is the normal no-data state', () {
      final load = loadSessions(
          Directory('/tmp/outride-bench-no-such-dir-20261121'));
      expect(load.sessions, isEmpty);
      expect(load.rejected, isEmpty);
    });

    test('empty directory loads nothing', () async {
      final dir = await Directory.systemTemp
          .createTemp('outride-bench-empty-');
      try {
        final load = loadSessions(dir);
        expect(load.sessions, isEmpty);
        expect(load.rejected, isEmpty);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('recorder-format files are listed as rejected', () async {
      final dir =
          await Directory.systemTemp.createTemp('outride-bench-rej-');
      try {
        await File('${dir.path}/recording.csv').writeAsString(_recorderCsv);
        final load = loadSessions(dir);
        expect(load.sessions, isEmpty);
        expect(load.rejected.keys, ['recording.csv']);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('a truncated file is rejected; other sessions still load (S3)',
        () async {
      final dir =
          await Directory.systemTemp.createTemp('outride-bench-short-');
      try {
        await File('${dir.path}/good.csv').writeAsString(_fixtureCsv);
        await File('${dir.path}/short.csv').writeAsString(_truncatedCsv);
        final load = loadSessions(dir);
        expect(load.sessions.length, 1);
        expect(load.sessions.first.name, 'good.csv');
        expect(load.rejected.keys, ['short.csv']);
        final outcome = runFusionBench(BenchConfig(
          sessionsDir: dir,
          nodes: _nodes(),
        ));
        expect(outcome.skipped, isFalse);
        expect(outcome.sessionsRun, ['good.csv']);
        expect(outcome.rejected.keys, ['short.csv']);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('runFusionBench — data rule', () {
    test('skips with the exact message when no sessions exist', () {
      final outcome = runFusionBench(BenchConfig(
        sessionsDir: Directory('/tmp/outride-bench-no-such-dir-20261121'),
        nodes: _nodes(),
      ));
      expect(outcome.skipped, isTrue);
      expect(outcome.skipReason, 'measurement pending — no recorded data');
      expect(outcome.armScores, isEmpty);
      expect(outcome.verdicts, isEmpty);
      expect(outcome.allPassed, isFalse);
    });

    test('benchReport states the skip plainly', () {
      final outcome = runFusionBench(BenchConfig(
        sessionsDir: Directory('/tmp/outride-bench-no-such-dir-20261121'),
        nodes: _nodes(),
      ));
      final report = benchReport(outcome);
      expect(report, contains('SKIPPED: measurement pending — no recorded data'));
      expect(report, contains('B1 fusion bench'));
    });

    test('skips on an empty sessions directory', () async {
      final dir = await Directory.systemTemp
          .createTemp('outride-bench-empty2-');
      try {
        final outcome = runFusionBench(BenchConfig(
          sessionsDir: dir,
          nodes: _nodes(),
        ));
        expect(outcome.skipped, isTrue);
        expect(outcome.skipReason, 'measurement pending — no recorded data');
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('reports the default sessions dir as skipped in this workspace',
        () {
      // The repo has no bench_sessions/ directory yet — the bench
      // must say so plainly instead of inventing a result.
      final outcome = runFusionBench(BenchConfig(
        sessionsDir: Directory('bench_sessions'),
        nodes: _nodes(),
      ));
      expect(outcome.skipped, isTrue);
      expect(outcome.skipReason, 'measurement pending — no recorded data');
    });
  });

  group('replay mechanics (fixture only — never bench results)', () {
    late Directory dir;
    late BenchConfig config;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('outride-bench-fix-');
      await File('${dir.path}/fixture.csv').writeAsString(_fixtureCsv);
      config = BenchConfig(sessionsDir: dir, nodes: _nodes());
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    test('replay produces one poll per timestamp with fused arms', () {
      final load = loadSessions(dir);
      expect(load.sessions.length, 1);
      final polls = replaySession(load.sessions.first, config);
      expect(polls.length, 5);
      // First polls have >= 2 active nodes, so fusion ran.
      expect(polls.first.fused['CI/metropolis'], isNotNull);
      expect(polls.first.fused['ICI/metropolis'], isNotNull);
      expect(polls.first.fused['naive/metropolis'], isNotNull);
      expect(polls.first.rfState, isNotNull);
      expect(polls.first.corrTracks.length, 3);
      // Last poll drops node n2 (no disturbed incident links) —
      // a handover poll.
      expect(polls.last.handover, isTrue);
      expect(polls.last.activeNodes, {'n0', 'n1'});
    });

    test('runFusionBench on the fixture completes structurally', () {
      final outcome = runFusionBench(config);
      expect(outcome.skipped, isFalse);
      expect(outcome.sessionsRun, ['fixture.csv']);
      expect(outcome.armScores.keys, containsAll([
        'CI/metropolis',
        'CI/centrality',
        'ICI/metropolis',
        'ICI/centrality',
        'naive/metropolis',
        'naive/centrality',
      ]));
      for (final scores in outcome.armScores.values) {
        expect(scores.samples, greaterThan(0));
        expect(scores.rmse.isFinite, isTrue);
        expect(scores.meanNees.isFinite, isTrue);
      }
      // Association ran for every feature set.
      expect(outcome.association.keys, containsAll([
        FeatureSet.kinematics.name,
        FeatureSet.plusDip.name,
        FeatureSet.plusDipAndMotion.name,
        FeatureSet.plusDipMotionAndSignature.name,
      ]));
      for (final a in outcome.association.values) {
        expect(a.totalAssociations, greaterThan(0));
        expect(a.meanLatencyMs, greaterThanOrEqualTo(0.0));
      }
      // Verdicts exist (pass/fail on fixture data is MECHANICS
      // ONLY — the fixture is 5 polls of hand-written numbers, not
      // a measurement; no verdict value is asserted here).
      expect(outcome.verdicts.length, 6);
    });

  });

  group('relative-count verdicts are N/A on zero baselines (S2)', () {
    late Directory dir;
    late BenchConfig config;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('outride-bench-na-');
      await File('${dir.path}/zero.csv').writeAsString(_zeroBaselineCsv);
      config = BenchConfig(
        sessionsDir: dir,
        nodes: {
          'n0': NodePosition(nodeId: 'n0', x: 0, y: -10),
          'n1': NodePosition(nodeId: 'n1', x: 0, y: 10),
          'n2': NodePosition(nodeId: 'n2', x: -10, y: 0),
          'n3': NodePosition(nodeId: 'n3', x: 10, y: 0),
        },
      );
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    test('zero baselines report N/A, not a vacuous PASS', () {
      final outcome = runFusionBench(config);
      // Preconditions: every poll associates (all local estimates
      // coincide at the truth, so the gate always passes), and the
      // one handover poll does not move the fused estimate — so
      // both relative bars have a zero baseline.
      final kin = outcome.association[FeatureSet.kinematics.name]!;
      expect(kin.identitySwitches + kin.cardinalityError, 0);
      final ci = outcome.armScores['CI/metropolis']!;
      expect(ci.fragmentations, 0);
      expect(ci.handoverPolls, 1);
      // The handover bar must be N/A (0 <= 0 would PASS vacuously).
      final handover = outcome.verdicts
          .firstWhere((v) => v.bar.startsWith('ICI handover'));
      expect(handover.notApplicable, isTrue);
      expect(handover.passed, isFalse);
      // Same for both feature bars.
      for (final prefix in [
        'Feature arm (+1 dip)',
        'Feature arm (+2 dip+motion)',
      ]) {
        final v = outcome.verdicts
            .firstWhere((v) => v.bar.startsWith(prefix));
        expect(v.notApplicable, isTrue);
        expect(v.passed, isFalse);
      }
      // The report says N/A, not PASS, for those bars.
      expect(benchReport(outcome), contains('N/A'));
    });
  });

  group('scoreBaseArms handover gaps (S1)', () {
    late BenchConfig config;

    setUp(() {
      config = BenchConfig(
        sessionsDir: Directory('/tmp/outride-bench-no-such-dir-20261121'),
        nodes: _nodes(),
      );
    });

    ReplayPoll poll(DateTime t, bool handover, Gaussian2? fusedCi) {
      return ReplayPoll(
        t: t,
        truth: (10.0, 10.0),
        truthIds: const {'A'},
        handover: handover,
        activeNodes: const {'n0', 'n1'},
        fused: fusedCi == null
            ? const <String, Gaussian2?>{}
            : {'CI/metropolis': fusedCi},
        rfState: null,
        corrTracks: const [],
      );
    }

    const g = Gaussian2(x: 10, y: 10, pxx: 1, pxy: 0, pyy: 1);
    final t0 = DateTime.utc(2026, 11, 21);

    test('a gap after a handover counts once; a later gap without a handover does not', () {
      final polls = [
        poll(t0, false, g), // fused baseline
        poll(t0.add(const Duration(seconds: 1)), true, g),
        // handover WITH a fused estimate: arms the counter
        poll(t0.add(const Duration(seconds: 2)), false, null),
        poll(t0.add(const Duration(seconds: 3)), false, null),
        // 2 missed polls after the handover: one fragmentation
        poll(t0.add(const Duration(seconds: 4)), false, g),
        // fused again: disarms
        poll(t0.add(const Duration(seconds: 5)), false, null),
        poll(t0.add(const Duration(seconds: 6)), false, null),
        // 2 missed polls, no handover since t+4: NOT counted.
        // (Before the fix this counted too — any earlier handover
        // in the run armed it — for 2 fragmentations.)
      ];
      final scores = scoreBaseArms(polls, config);
      expect(scores['CI/metropolis']!.fragmentations, 1);
      expect(scores['CI/metropolis']!.handoverPolls, 1);
    });

    test('a handover poll with no fused estimate arms the counter too', () {
      final polls = [
        poll(t0, false, g),
        // handover AT a missed poll: arms for the polls after it
        poll(t0.add(const Duration(seconds: 1)), true, null),
        poll(t0.add(const Duration(seconds: 2)), false, null),
        // 2 missed polls after the handover: one fragmentation
        poll(t0.add(const Duration(seconds: 3)), false, g),
      ];
      final scores = scoreBaseArms(polls, config);
      expect(scores['CI/metropolis']!.fragmentations, 1);
    });
  });

  group('multi-target truth attribution (B2)', () {
    late Directory dir;
    late BenchConfig config;

    Map<String, NodePosition> multiNodes() => {
          'n0': NodePosition(nodeId: 'n0', x: 0, y: -10),
          'n1': NodePosition(nodeId: 'n1', x: 0, y: 10),
          'n2': NodePosition(nodeId: 'n2', x: 10, y: -10),
          'n3': NodePosition(nodeId: 'n3', x: 10, y: 10),
          'n4': NodePosition(nodeId: 'n4', x: 6, y: -9),
          'n5': NodePosition(nodeId: 'n5', x: 6, y: 11),
        };

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('outride-bench-multi-');
      await File('${dir.path}/multi.csv').writeAsString(_multiTargetCsv);
      config = BenchConfig(sessionsDir: dir, nodes: multiNodes());
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    test('corroborators inherit their links\' truth ids; the RF track takes the nearest truth', () {
      final load = loadSessions(dir);
      final polls = replaySession(load.sessions.first, config);
      expect(polls.length, 2);
      final p1 = polls.first;
      // The fused estimate is nearest truth A...
      expect(p1.rfState, isNotNull);
      expect(p1.rfState!.truthId, 'A');
      // ...while the per-node attribution separates the tracklets.
      expect(
        p1.corrTracks.where((c) => c.truthId == 'A').length,
        4,
      );
      expect(
        p1.corrTracks.where((c) => c.truthId == 'B').length,
        2,
      );
      expect(
        p1.corrTracks.where((c) => c.truthId == null).length,
        0,
      );
    });

    test('a match to another target\'s tracklet is a false track; the flip back is an identity switch', () {
      // Before the fix both scores were structurally zero: every
      // corroborator inherited the poll's single truth id (or null
      // in multi-target polls), so corr.truthId could never differ
      // from rf.truthId, and switches counted node-id changes.
      final outcome = runFusionBench(config);
      for (final fs in FeatureSet.values) {
        final a = outcome.association[fs.name]!;
        // Poll 1 matches a B tracklet to the A RF track; poll 2
        // matches A again — one false track, one truth-id switch.
        expect(a.falseTracks, 1, reason: fs.name);
        expect(a.identitySwitches, 1, reason: fs.name);
      }
    });
  });
}
