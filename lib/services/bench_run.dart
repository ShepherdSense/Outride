/// Shared run plumbing for the RF-track benches (B1, B4, B5, B9,
/// B10, B11, B14).
///
/// Every harness follows the B1 pattern: scan the input directory;
/// missing / empty / no valid session → SKIPPED with the exact
/// literal "measurement pending — no recorded data", scoring nothing.
/// Rejected files are listed with reasons, never hidden. A recorded
/// session that is empty or too short (< 2 polls) is rejected with
/// that reason — it says so, it never silently passes and never
/// scores a single poll as a measurement.
library;

import 'dart:io';

import 'bench_csi.dart' show kBenchPending;
import 'fusion_bench.dart';
import 'fusion_bench_harness.dart';

/// A session that is too short to score: fewer than 2 polls.
const int kMinSessionPolls = 2;

/// Loaded RF-track sessions, with rejections folded in.
class RfLoad {
  const RfLoad({required this.sessions, required this.rejected});

  final List<BenchSession> sessions;

  /// File name -> rejection reason (parse failures + too-short).
  final Map<String, String> rejected;
}

/// Load RF-track sessions from [dir], moving too-short sessions
/// into [RfLoad.rejected] with the reason stated.
RfLoad loadRfSessions(Directory dir) {
  final load = loadSessions(dir);
  final sessions = <BenchSession>[];
  final rejected = Map<String, String>.of(load.rejected);
  for (final s in load.sessions) {
    if (s.polls.length < kMinSessionPolls) {
      rejected[s.name] =
          'too short: ${s.polls.length} poll(s) — need at least '
          '$kMinSessionPolls';
    } else {
      sessions.add(s);
    }
  }
  return RfLoad(sessions: sessions, rejected: rejected);
}

/// The SKIPPED outcome every harness returns with no usable input.
BenchOutcome skippedOutcome(Map<String, String> rejected) =>
    BenchOutcome(
      skipped: true,
      skipReason: kBenchPending,
      rejected: rejected,
    );

/// RMSE + mean NEES (+ 95% bounds) for fused estimates against
/// single-target truth polls. Polls without truth are skipped, never
/// scored as zero error.
({double rmse, double meanNees, double neesLow, double neesHigh,
    bool inBounds, int samples}) scoreEstimates(
  List<(Gaussian2, (double, double))> pairs,
) {
  if (pairs.isEmpty) {
    return (
      rmse: double.nan,
      meanNees: double.nan,
      neesLow: double.nan,
      neesHigh: double.nan,
      inBounds: false,
      samples: 0,
    );
  }
  final ests = [for (final p in pairs) (p.$1.x, p.$1.y)];
  final truths = [for (final p in pairs) p.$2];
  final neesVals = [
    for (final p in pairs) nees(p.$1, p.$2.$1, p.$2.$2),
  ];
  final bounds = neesMeanBounds95(neesVals.length);
  final meanNees =
      neesVals.fold(0.0, (a, b) => a + b) / neesVals.length;
  return (
    rmse: rmse(ests, truths),
    meanNees: meanNees,
    neesLow: bounds.low,
    neesHigh: bounds.high,
    inBounds: meanNees >= bounds.low && meanNees <= bounds.high,
    samples: pairs.length,
  );
}

/// Replay every session in [load] through the B1 local estimator +
/// fusion, concatenated in session order (the same replay the B1
/// bench scores).
List<ReplayPoll> replayAll(RfLoad load, BenchConfig config) {
  final polls = <ReplayPoll>[];
  for (final s in load.sessions) {
    polls.addAll(replaySession(s, config));
  }
  return polls;
}

/// Session names, for the run-provenance line.
List<String> sessionNames(RfLoad load) =>
    [for (final s in load.sessions) s.name];
