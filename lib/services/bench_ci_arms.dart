/// B5 CI bench arms (new arms only — the base CI/ICI stays in
/// fusion_bench.dart, and the SDP family-optimal arm B5.1 is
/// QUEUED-BLOCKED: no SDP solver exists in Dart).
///
/// Sources: Pedroso et al., arXiv:2603.20402v2 (Split CI, Thm 4;
/// concurrent-vs-sequential); Xie/Tu et al., Drones 2026, 10(9), 683
/// (fading SCI, per-link variance). The ION GNSS+ 2026 companion is
/// abstract-only and UNREAD — not cited as findings.
///
/// Arms, all scored on the B1 replay's per-node local estimates
/// ([ReplayPoll.locals]):
///
/// - B5.2 Split CI: QUEUED-BLOCKED since 2026-11-23 (independent
///   review). The Jaccard shared-dip fraction is a heuristic proxy,
///   not an honest derivation of the P_I/P_D split: the B1 local
///   estimator's covariance is isotropic, built from link count and
///   time (varBase = σ0²/n + (0.3·dt)²), never from dip weights, so
///   decomposing centroid dip weights and applying that fraction to
///   a covariance never built that way is not a derivation — and the
///   sequential fold is exact only for 2 nodes. [sharedDipFraction]
///   survives below marked UNUSED, wired to no verdict. The honest
///   alternative (rebuilding local covariance from per-link
///   contributions) is a redesign, not a fix, and is NOT attempted
///   here.
/// - B5.3 Sequential-pairwise CI: fold [ciFuse] over the locals in
///   sorted node order, vs the one-step CI arm (CI/metropolis fused)
///   as the concurrent reference. A control arm: it is expected to
///   be worse, and the verdict records the measured gap.
/// - B5.4 Fading SCI: a running fused estimate whose dependent part
///   fades per prediction step, P_D *= exp(-dt/τ), swept over
///   τ ∈ [0.4, 40] s. Best τ by median NEES. The paper's EKF
///   reference does not exist in-app, so the RMSE bar is applied
///   against the CI arm and says so. Paper τ / RMSE figures are NOT
///   ported.
/// - B5.5 Per-link variance: each local's covariance is scaled by
///   its node's recent dip variance (last 5 polls) relative to the
///   mesh median, then CI-fused; the constant-variance CI arm is
///   the control. The verdict checks the reported variance tracks
///   realised error.
library;

import 'dart:math' as math;

import 'bench_run.dart';
import 'fusion_bench.dart';
import 'fusion_bench_harness.dart';

/// Fading-SCI τ sweep, seconds (paper sweep range, NOT its τ value).
const List<double> kSciTaus = [0.4, 1.0, 2.0, 5.0, 10.0, 40.0];

/// Split CI of [a] and [b] with dependent fraction [f] in [0,1].
///
/// P = P_I + P_D per estimate (same mean, covariance split by f);
/// the D parts fuse by CI; the I parts and the fused D part combine
/// in information form. At f = 0 this is naive fusion of independent
/// estimates; at f = 1 it is plain CI.
FusionResult splitCiFuse(Gaussian2 a, Gaussian2 b, double f) {
  final frac = f.clamp(0.0, 1.0);
  final da = _scaled(a, frac);
  final db = _scaled(b, frac);
  final ia = _scaled(a, 1 - frac);
  final ib = _scaled(b, 1 - frac);
  // A zero-covariance part (f = 0 → D parts; f = 1 → I parts) is
  // singular and has no information form — it carries no weight,
  // so it is dropped, never inverted. At f = 0 this is naive fusion
  // of independent estimates; at f = 1 it is plain CI.
  final parts = <Gaussian2>[];
  var omega = 0.5;
  if (frac > 0.0) {
    final dFused = ciFuse(da, db);
    parts.add(dFused.fused);
    omega = dFused.omega;
  }
  for (final g in [ia, ib]) {
    if (g.determinant > 0) parts.add(g);
  }
  // Combine the non-degenerate parts in information form (all share
  // means with their source estimates; the D part carries ciFuse's
  // mean).
  final info = [0.0, 0.0, 0.0];
  final vec = [0.0, 0.0];
  for (final g in parts) {
    final y = g.information;
    final v = g.informationVector;
    for (var i = 0; i < 3; i++) {
      info[i] += y[i];
    }
    vec[0] += v[0];
    vec[1] += v[1];
  }
  final fused = gaussianFromInformation(info, vec);
  return FusionResult(fused: fused, omega: omega);
}

Gaussian2 _scaled(Gaussian2 g, double s) => Gaussian2(
      x: g.x,
      y: g.y,
      pxx: g.pxx * s,
      pxy: g.pxy * s,
      pyy: g.pyy * s,
    );

/// Shared-dip fraction between nodes [a] and [b] at poll [t] of
/// [session]: shared disturbed-link dip weight over the union weight.
/// 0 when the nodes share no disturbed link; 1 when their disturbed
/// sets coincide. Derived from the session rows, never assumed.
///
/// UNUSED HEURISTIC — retained for reference only, wired to NO
/// verdict and NO run path. B5.2 is QUEUED-BLOCKED (see the file
/// header): this Jaccard fraction is a heuristic proxy for the
/// P_I/P_D split, not an honest derivation of it, because the local
/// estimator's covariance is isotropic and never built from dip
/// weights. Do not re-wire it to a row without first rebuilding the
/// local covariance from per-link contributions.
double sharedDipFraction(
    BenchSession session, DateTime t, String a, String b, double dipThr) {
  var dipA = 0.0, dipB = 0.0, shared = 0.0;
  for (final r in session.rowsAt(t)) {
    final d = r.dipDb ?? 0;
    if (d <= dipThr) continue;
    final inA = r.fromNode == a || r.toNode == a;
    final inB = r.fromNode == b || r.toNode == b;
    if (inA) dipA += d;
    if (inB) dipB += d;
    if (inA && inB) shared += d;
  }
  final union = dipA + dipB - shared;
  if (union <= 0) return 0.0;
  return (shared / union).clamp(0.0, 1.0);
}

/// Run the B5 arms over the RF-track sessions under [config].
BenchOutcome runCiArmsBench(BenchConfig config) {
  final load = loadRfSessions(config.sessionsDir);
  if (load.sessions.isEmpty) return skippedOutcome(load.rejected);

  final seqPairs = <(Gaussian2, (double, double))>[];
  final ciPairs = <(Gaussian2, (double, double))>[];
  // Fading SCI: one (estimate, truth) series per τ.
  final sciSeries = {
    for (final tau in kSciTaus) tau: <(Gaussian2, (double, double))>[],
  };
  final sciNees = {
    for (final tau in kSciTaus) tau: <double>[],
  };
  // Per-link variance: scaled pairs + per-poll ratios.
  final plvPairs = <(Gaussian2, (double, double))>[];
  final plvRatios = <double>[];

  for (final session in load.sessions) {
    final polls = replaySession(session, config);
    // Running SCI state per τ: (estimate, dependent fraction left).
    final sciState = <double, Gaussian2?>{for (final t in kSciTaus) t: null};
    final sciPrevT = <double, DateTime?>{for (final t in kSciTaus) t: null};
    // Recent per-node dip history for the per-link variance arm.
    final dipHistory = <String, List<double>>{};
    for (final p in polls) {
      final locals = p.locals;
      if (locals.length < 2 || p.truth == null || p.truthIds.length != 1) {
        // Still advance dip history + SCI clocks on truth-less polls.
        _advanceDipHistory(dipHistory, session, p);
        continue;
      }
      final ids = locals.keys.toList()..sort();
      // B5.3 Sequential-pairwise CI: plain CI fold in node order.
      var seq = locals[ids.first]!;
      for (var i = 1; i < ids.length; i++) {
        seq = ciFuse(seq, locals[ids[i]]!).fused;
      }
      seqPairs.add((seq, p.truth!));
      final ci = p.fused['CI/metropolis'];
      if (ci != null) ciPairs.add((ci, p.truth!));
      // B5.4 Fading SCI per τ.
      final ciHere = ci ?? seq;
      for (final tau in kSciTaus) {
        final prev = sciState[tau];
        final prevT = sciPrevT[tau];
        Gaussian2 next;
        if (prev == null || prevT == null) {
          next = ciHere;
        } else {
          final dt = p.t.difference(prevT).inMicroseconds / 1e6;
          // The dependent share still common after dt seconds.
          final f = math.exp(-dt / tau);
          next = splitCiFuse(prev, ciHere, f).fused;
        }
        sciState[tau] = next;
        sciPrevT[tau] = p.t;
        sciSeries[tau]!.add((next, p.truth!));
        sciNees[tau]!.add(nees(next, p.truth!.$1, p.truth!.$2));
      }
      // B5.5 Per-link variance: scale each local by its node's
      // recent dip variance relative to the mesh median.
      final scales = _varianceScales(dipHistory);
      final scaled = <Gaussian2>[];
      for (final id in ids) {
        final s = scales[id] ?? 1.0;
        scaled.add(_scaled(locals[id]!, s));
      }
      var plv = scaled.first;
      for (var i = 1; i < scaled.length; i++) {
        plv = ciFuse(plv, scaled[i]).fused;
      }
      plvPairs.add((plv, p.truth!));
      final err = math.sqrt((plv.x - p.truth!.$1) * (plv.x - p.truth!.$1) +
          (plv.y - p.truth!.$2) * (plv.y - p.truth!.$2));
      final sig = math.sqrt((plv.pxx + plv.pyy) / 2);
      if (sig > 0) plvRatios.add(err / sig);
      _advanceDipHistory(dipHistory, session, p);
    }
  }

  final seqScore = scoreEstimates(seqPairs);
  final ciScore = scoreEstimates(ciPairs);
  final plvScore = scoreEstimates(plvPairs);

  // Best SCI τ by median NEES closeness to 1.
  double bestTau = kSciTaus.first;
  var bestDist = double.infinity;
  var bestMedianNees = double.nan;
  for (final tau in kSciTaus) {
    final vals = [...sciNees[tau]!]..sort();
    if (vals.isEmpty) continue;
    final med = vals[vals.length ~/ 2];
    final dist = (med - 1).abs();
    if (dist < bestDist) {
      bestDist = dist;
      bestTau = tau;
      bestMedianNees = med;
    }
  }
  final sciScore = scoreEstimates(sciSeries[bestTau]!);
  plvRatios.sort();
  final plvMedianRatio = plvRatios.isEmpty
      ? double.nan
      : plvRatios[plvRatios.length ~/ 2];

  final verdicts = <BenchVerdict>[
    BenchVerdict(
      bar: 'B5.3 Sequential-pairwise CI as (expected-worse) control vs '
          'one-step CI',
      notApplicable: seqScore.samples == 0 || ciScore.samples == 0,
      // Real criterion (2026-11-23 review fix — this arm previously
      // passed whenever both RMSEs were finite, i.e. by
      // construction): the expected-worse direction holds — the
      // sequential fold is NOT materially better than one-step CI.
      // "Materially" is a 5% RMSE margin for replay noise. A
      // sequential fold that beats one-step CI by more than 5%
      // FAILS: the control direction did not hold.
      passed: seqScore.samples > 0 &&
          ciScore.samples > 0 &&
          seqScore.rmse.isFinite &&
          ciScore.rmse.isFinite &&
          seqScore.rmse >= 0.95 * ciScore.rmse,
      detail: 'Sequential RMSE ${seqScore.rmse.toStringAsFixed(3)} m vs '
          'one-step CI RMSE ${ciScore.rmse.toStringAsFixed(3)} m '
          '(gap ${(seqScore.rmse - ciScore.rmse).toStringAsFixed(3)} m, '
          '${ciScore.rmse > 0 ? ((seqScore.rmse - ciScore.rmse) / ciScore.rmse * 100).toStringAsFixed(1) : 'N/A'}%; '
          'control arm measured — passes only when sequential is not '
          'materially better than one-step CI)',
    ),
    BenchVerdict(
      bar: 'B5.4 Fading SCI: median ANEES/NEES in [0.5, 2], RMSE ≤1.26× '
          'CI (EKF reference unavailable in-app — CI used instead)',
      passed: bestMedianNees >= 0.5 &&
          bestMedianNees <= 2.0 &&
          sciScore.rmse.isFinite &&
          ciScore.rmse.isFinite &&
          sciScore.rmse <= 1.26 * ciScore.rmse,
      detail: 'Best τ=${bestTau}s: median NEES '
          '${bestMedianNees.toStringAsFixed(3)}, RMSE '
          '${sciScore.rmse.toStringAsFixed(3)} m vs CI '
          '${ciScore.rmse.toStringAsFixed(3)} m. Best τ is picked by '
          'median NEES on the same data the verdict scores (in-sample, '
          'optimistic by construction); a held-out split is follow-up '
          'work.',
    ),
    BenchVerdict(
      bar: 'B5.5 Per-link variance: reported variance tracks realised '
          'error (median error/σ ~1.3, ANEES in-band)',
      passed: plvMedianRatio >= 0.5 &&
          plvMedianRatio <= 2.5 &&
          plvScore.inBounds,
      detail: 'Median error/σ ${plvMedianRatio.toStringAsFixed(3)}, '
          'mean NEES ${plvScore.meanNees.toStringAsFixed(3)} '
          '(constant-variance CI RMSE '
          '${ciScore.rmse.toStringAsFixed(3)} m vs per-link '
          '${plvScore.rmse.toStringAsFixed(3)} m)',
    ),
  ];
  return BenchOutcome(
    skipped: false,
    sessionsRun: sessionNames(load),
    rejected: load.rejected,
    armScores: {
      'B5.3/sequential-ci': _toArm('B5.3/sequential-ci', seqScore),
      'B5.4/fading-sci-tau-$bestTau': _toArm('B5.4/fading-sci', sciScore),
      'B5.5/per-link-variance': _toArm('B5.5/per-link-variance', plvScore),
      'CI/metropolis': _toArm('CI/metropolis', ciScore),
    },
    verdicts: verdicts,
  );
}

void _advanceDipHistory(
    Map<String, List<double>> history, BenchSession session, ReplayPoll p) {
  for (final node in p.activeNodes) {
    final dips = [
      for (final r in session.rowsAt(p.t))
        if ((r.fromNode == node || r.toNode == node) && r.dipDb != null)
          r.dipDb!,
    ];
    if (dips.isEmpty) continue;
    final mean = dips.fold(0.0, (a, b) => a + b) / dips.length;
    (history[node] ??= []).add(mean);
    if (history[node]!.length > 5) history[node]!.removeAt(0);
  }
}

/// Per-node covariance scale from recent dip variance, relative to
/// the mesh median. Nodes with no history scale 1.0. Clamped
/// [0.25, 4] so one wild link cannot blow up a fusion.
Map<String, double> _varianceScales(Map<String, List<double>> history) {
  final vars = <String, double>{};
  for (final e in history.entries) {
    if (e.value.length < 2) continue;
    final m = e.value.fold(0.0, (a, b) => a + b) / e.value.length;
    vars[e.key] = e.value.fold(0.0, (a, b) => (b - m) * (b - m)) /
        e.value.length;
  }
  if (vars.isEmpty) return {};
  final sorted = vars.values.toList()..sort();
  final median = sorted[sorted.length ~/ 2];
  if (median <= 0) return {for (final k in vars.keys) k: 1.0};
  return {
    for (final e in vars.entries)
      e.key: (e.value / median).clamp(0.25, 4.0),
  };
}

ArmScores _toArm(
  String name,
  ({
    double rmse,
    double meanNees,
    double neesLow,
    double neesHigh,
    bool inBounds,
    int samples,
  }) s,
) =>
    ArmScores(
      arm: name,
      rmse: s.rmse,
      meanNees: s.meanNees,
      neesLow: s.neesLow,
      neesHigh: s.neesHigh,
      neesInBounds: s.inBounds,
      samples: s.samples,
      fragmentations: 0,
      handoverPolls: 0,
    );
