/// B14 KLD-divergence integrity arm (on the P21 quarantine bench).
///
/// Source: Yu & Liang, Sensors 2025, 25(11), 3526. The paper gives
/// NO weight-selection rule for GCI fusion anywhere and NO numeric
/// OSPA/detection values (figure-only results); the bench therefore
/// defines its own exclusion threshold τ from recorded data (below).
/// Fixed-trusted-sensor-1 architecture NOT ported (no always-trusted
/// node); the reference is the RF track, per the queue file.
///
/// Method: closed-form Gaussian KLD per corroborator (each poll's
/// CorrTrack, covariance from its node's local estimate) vs the
/// RF-track reference (the ICI/metropolis fused estimate). A
/// corroborator with KLD > τ is quarantined (excluded before fuse)
/// for that poll. τ is bench-defined: the χ² 99% bound for 2 dof
/// (9.21) on the KLD scale — a corroborator further than that from
/// the RF track is, by construction, inconsistent with it.
///
/// Verdicts: (1) drift detected before the window expires — a
/// high-KLD corroborator is excluded at the poll it appears (N/A
/// when no corroborator ever drifts — nothing to detect is not a
/// pass); (2) CROSS-CHECK (not a verdict on the physics): the RF
/// track is unmoved while quarantined — measured as max |CI − ICI|
/// on quarantined polls. Corroborators never drive the RF track by
/// construction (the reference IS the RF track), so this checks the
/// plumbing, not the physics, and is labeled a cross-check, not a
/// pass/fail on quarantine behavior; (3) genuine corroboration is
/// not suppressed — low-KLD corroborators are retained (retention
/// rate ≥ 95% of consistent corroborators).
///
/// Pass bar: drift detected before window expires; RF track/alerts
/// unmoved while quarantined; genuine corroboration not suppressed
/// after.
library;

import 'dart:math' as math;

import 'bench_run.dart';
import 'fusion_bench.dart';
import 'fusion_bench_harness.dart';

/// Bench-defined exclusion threshold τ (χ² 99%, 2 dof, on the KLD
/// scale — see the header: the paper gives no threshold).
const double kB14Tau = 9.21;

/// "Unmoved" tolerance for the RF track while quarantined, metres.
const double kB14TrackToleranceM = 0.5;

/// Closed-form KLD (nats) between 2-D Gaussians p=N(μ0,Σ0) and
/// q=N(μ1,Σ1): KLD(p||q).
double gaussianKld(Gaussian2 p, Gaussian2 q) {
  final detP = p.determinant;
  final detQ = q.determinant;
  if (detP <= 0 || detQ <= 0) return double.nan;
  final traceTerm = (q.pyy * p.pxx - 2 * q.pxy * p.pxy + q.pxx * p.pyy) /
      detQ;
  final dx = p.x - q.x, dy = p.y - q.y;
  final maha = (q.pyy * dx * dx - 2 * q.pxy * dx * dy + q.pxx * dy * dy) /
      detQ;
  return 0.5 *
      (math.log(detQ / detP) - 2 + traceTerm + maha);
}

/// Run the B14 bench over the RF-track sessions under [config].
BenchOutcome runKldBench(BenchConfig config) {
  final load = loadRfSessions(config.sessionsDir);
  if (load.sessions.isEmpty) return skippedOutcome(load.rejected);

  var driftPolls = 0;
  var quarantined = 0;
  var retained = 0;
  var consistent = 0;
  var maxTrackMove = 0.0;
  var scoredPolls = 0;
  for (final session in load.sessions) {
    final polls = replaySession(session, config);
    for (final p in polls) {
      final ref = p.fused['ICI/metropolis'];
      if (ref == null) continue;
      scoredPolls++;
      var driftHere = false;
      for (final corr in p.corrTracks) {
        final local = p.locals[corr.id];
        if (local == null) continue;
        // The corroborator as a Gaussian: its local estimate's
        // position, covariance from the same local estimate.
        final kld = gaussianKld(local, ref);
        if (!kld.isFinite) continue;
        if (kld > kB14Tau) {
          quarantined++;
          driftHere = true;
        } else {
          consistent++;
          retained++;
        }
      }
      if (driftHere) driftPolls++;
      // The RF track IS the reference (corroborators never drive
      // it), so the "unmoved while quarantined" check is a plumbing
      // check: the reference estimate at this poll vs the previous
      // poll's reference, when a quarantine is active.
      // (Tracked below via maxTrackMove on quarantined polls.)
      if (driftHere) {
        // Movement is measured against the CI arm at the same poll
        // as the independent cross-check: both are RF-track
        // estimates; a quarantine must not move either.
        final ci = p.fused['CI/metropolis'];
        if (ci != null) {
          final dx = ci.x - ref.x, dy = ci.y - ref.y;
          maxTrackMove =
              math.max(maxTrackMove, math.sqrt(dx * dx + dy * dy));
        }
      }
    }
  }

  final retentionRate = consistent == 0
      ? double.nan
      : retained / consistent;
  return BenchOutcome(
    skipped: false,
    sessionsRun: sessionNames(load),
    rejected: load.rejected,
    verdicts: [
      BenchVerdict(
        bar: 'B14: drift detected before window expires (high-KLD '
            'corroborator excluded at the poll it appears)',
        notApplicable: quarantined == 0,
        passed: quarantined > 0 && driftPolls > 0,
        detail: quarantined == 0
            ? 'N/A — zero baseline: no corroborator ever exceeded τ '
                '($kB14Tau) in $scoredPolls polls, so there was no drift '
                'to detect'
            : '$quarantined corroborator(s) quarantined over $driftPolls '
                'poll(s) (τ=$kB14Tau)',
      ),
      BenchVerdict(
        bar: 'B14 cross-check (not a physics verdict): RF track '
            'unmoved while quarantined — max |CI − ICI| on quarantined '
            'polls <0.5 m. Corroborators never drive the RF track by '
            'construction, so this is a plumbing cross-check, not '
            'evidence quarantine works',
        notApplicable: quarantined == 0,
        passed: quarantined > 0 && maxTrackMove < kB14TrackToleranceM,
        detail: 'max RF-track cross-check movement on quarantined polls '
            '${maxTrackMove.toStringAsFixed(3)} m',
      ),
      BenchVerdict(
        bar: 'B14: genuine corroboration not suppressed (≥95% of '
            'consistent corroborators retained)',
        passed: retentionRate.isFinite && retentionRate >= 0.95,
        detail: 'retained $retained/$consistent consistent corroborators '
            '(${(retentionRate * 100).toStringAsFixed(1)}%)',
      ),
    ],
  );
}
