/// B4 bounded-replay bench (async corroborator handling).
///
/// Source: Tsai et al., IEEE Access 2026, 14, 117754–117774 (full
/// text read). Constants pinned: L=300, τ ≤1.5 s acoustic / ≤200 ms
/// visual, RK4, p99 2.5/4.12 ms. Stone Soup itself is NOT ported.
///
/// What this harness measures, honestly:
/// 1. Late-evidence handling: the same replay is run twice — once in
///    time order, once with a deterministic late-arrival pattern
///    (every 5th poll held to the midpoint between its own timestamp
///    and the next poll's, capped at 1.0 s — inside the τ ≤1.5 s
///    acoustic window, then re-sorted). The hold timestamp is
///    guaranteed distinct from every poll timestamp: a 1.0 s hold
///    landed exactly on the next poll at ≤1 s spacing and merged two
///    polls' rows (mixing truths). The replay itself is re-run (not
///    just re-sorted) so the estimator sees the late order. The late
///    pattern is a stated bench procedure, not a simulation of Tsai's
///    async arrivals. Timestamp-shifting only — there is NO replay
///    buffer/rollback here; the header says so honestly.
/// 2. Deadlines: wall-clock time to process each poll on THIS phone
///    (Stopwatch around the replay loop), p99 and max against a
///    250 ms per-poll wall-clock budget. R4: these are wall-clock
///    phone measurements, NOT the paper's 200 Hz MCU budgets — the
///    result block says so, or a reader will compare them directly.
///
/// Pass bar: late-evidence handling removes timing bias, no
/// deadline misses.
library;


import 'bench_run.dart';
import 'fusion_bench.dart';
import 'fusion_bench_harness.dart';

/// Wall-clock budget per poll, milliseconds. Phone-side bench
/// deadline — NOT the paper's 200 Hz MCU tick (see R4).
const double kB4DeadlineMs = 250.0;

/// Relative RMSE tolerance for "timing bias removed".
const double kB4LateTolerance = 0.10;

/// Late-arrival hold cap, seconds (inside the paper's τ ≤1.5 s
/// window). The actual hold per poll is the midpoint to the next
/// poll, capped at this value — see [_lateSession].
const double kB4LateHoldS = 1.0;

/// Run the B4 bench over the RF-track sessions under [config].
BenchOutcome runReplayBench(BenchConfig config) {
  final load = loadRfSessions(config.sessionsDir);
  if (load.sessions.isEmpty) return skippedOutcome(load.rejected);

  // In-order replay, timed per poll.
  final inOrder = <ReplayPoll>[];
  final perPollMs = <double>[];
  for (final s in load.sessions) {
    final sw = Stopwatch()..start();
    final polls = replaySession(s, config);
    sw.stop();
    inOrder.addAll(polls);
    final perPoll = polls.isEmpty
        ? 0.0
        : sw.elapsedMicroseconds / 1000.0 / polls.length;
    perPollMs.add(perPoll);
  }
  // Late-arrival replay: same polls, every 5th held to the
  // midpoint before the next poll (capped at 1.0 s), re-sorted.
  // The replay itself is re-run (not just re-sorted) so the estimator
  // sees the late order — re-sorting the fused output would prove
  // nothing.
  final lateSessions = [
    for (final s in load.sessions) _lateSession(s),
  ];
  final latePolls = <ReplayPoll>[];
  for (final s in lateSessions) {
    latePolls.addAll(replaySession(s, config));
  }

  final inScore = _ciScore(inOrder);
  final lateScore = _ciScore(latePolls);
  perPollMs.sort();
  final p99Ms = perPollMs.isEmpty
      ? 0.0
      : perPollMs[((perPollMs.length - 1) * 0.99).round()];
  final maxMs = perPollMs.isEmpty ? 0.0 : perPollMs.last;
  final misses = perPollMs.where((m) => m > kB4DeadlineMs).length;

  final lateOk = inScore.rmse.isFinite &&
      lateScore.rmse.isFinite &&
      inScore.rmse > 0 &&
      (lateScore.rmse - inScore.rmse).abs() / inScore.rmse <=
          kB4LateTolerance;
  final verdicts = <BenchVerdict>[
    BenchVerdict(
      bar: 'B4: late-evidence handling removes timing bias '
          '(late RMSE within 10% of in-order RMSE)',
      passed: lateOk,
      detail: 'in-order CI RMSE ${inScore.rmse.toStringAsFixed(3)} m vs '
          'late-arrival CI RMSE ${lateScore.rmse.toStringAsFixed(3)} m',
    ),
    BenchVerdict(
      bar: 'B4: no deadline misses (wall-clock phone measurement, '
          '250 ms per-poll budget — NOT the paper\'s 200 Hz MCU budget)',
      passed: misses == 0,
      detail: 'p99 ${p99Ms.toStringAsFixed(1)} ms, max '
          '${maxMs.toStringAsFixed(1)} ms, $misses miss(es) over '
          '${inOrder.length} polls',
    ),
  ];
  return BenchOutcome(
    skipped: false,
    sessionsRun: sessionNames(load),
    rejected: load.rejected,
    armScores: {
      'CI/metropolis:in-order': inScore,
      'CI/metropolis:late': lateScore,
    },
    verdicts: verdicts,
  );
}

/// CI/metropolis fused estimates vs truth, as an [ArmScores] row.
ArmScores _ciScore(List<ReplayPoll> polls) {
  final pairs = <(Gaussian2, (double, double))>[];
  for (final p in polls) {
    final g = p.fused['CI/metropolis'];
    if (g != null && p.truth != null && p.truthIds.length == 1) {
      pairs.add((g, p.truth!));
    }
  }
  final s = scoreEstimates(pairs);
  return ArmScores(
    arm: 'CI/metropolis',
    rmse: s.rmse,
    meanNees: s.meanNees,
    neesLow: s.neesLow,
    neesHigh: s.neesHigh,
    neesInBounds: s.inBounds,
    samples: s.samples,
    fragmentations: 0,
    handoverPolls: 0,
  );
}

/// A copy of [session] with every 5th poll's rows held late.
/// Deterministic: the same input always produces the same late run.
/// The hold lands at the midpoint between the held poll and the
/// next poll (capped at [kB4LateHoldS]; 0.5 s for the last poll, which
/// has no next poll) — a timestamp guaranteed distinct from every
/// poll timestamp, so no two polls' rows ever merge.
BenchSession _lateSession(BenchSession session) {
  final polls = session.polls;
  final rows = <BenchSessionRow>[];
  for (var i = 0; i < polls.length; i++) {
    var delay = Duration.zero;
    if (i % 5 == 4) {
      final holdS = i + 1 < polls.length
          ? (polls[i + 1].difference(polls[i]).inMicroseconds / 1e6 / 2)
              .clamp(0.0, kB4LateHoldS)
          : 0.5;
      delay = Duration(microseconds: (holdS * 1e6).round());
    }
    for (final r in session.rowsAt(polls[i])) {
      rows.add(BenchSessionRow(
        t: r.t.add(delay),
        linkKey: r.linkKey,
        fromNode: r.fromNode,
        toNode: r.toNode,
        snrDb: r.snrDb,
        dipDb: r.dipDb,
        truthX: r.truthX,
        truthY: r.truthY,
        truthId: r.truthId,
      ));
    }
  }
  rows.sort((a, b) => a.t.compareTo(b.t));
  return BenchSession(name: session.name, rows: rows);
}
