/// B1-harness refinements (filed 2026-11-18, lane 3 P42/P43):
/// Rønning k_pair + Forsling λ_min/λ_max, as B1-harness extensions.
///
/// Sources: Rønning et al., arXiv:2609.25900 (median NEES / median
/// χ² inflation k, Gaussian log score, block-bootstrap error bars);
/// Forsling et al., IEEE TAES 2025 (λ_min/λ_max of the NEES matrix
/// offline/MC and the NIS matrix online — scalar NEES alone certified
/// a bad estimator as good).
///
/// What is computed here, on the B1 replay's fused estimates vs
/// truth:
/// - median NEES + median-χ² inflation k (k = median NEES / median
///   of χ²₂ — a consistency inflation factor; k_pair cross-check
///   needs Stone Soup reference output as a CSV input and reports
///   PENDING when that file is absent).
/// - Gaussian log score (NEES consistency + log-det sharpness split).
/// - λ_min/λ_max of the NEES matrix Ξ̂ = mean(e eᵀ) over normalized
///   errors e = P^{-1/2}(x − truth) — closed-form 2×2 eigenvalues.
///   NO Wishart bound is computed or applied — the eigenvalues are
///   reported raw, and the result says so. (A Wishart bound would
///   have to be recomputed for Outride's state dimension — never
///   ported, and not computed in this fix pass.)
/// - Block-bootstrap error bars on RMSE (blocks of 5 polls, 200
///   resamples, deterministic seed).
///
/// Do NOT port any k value from Rønning (odometry domain). Do NOT
/// adopt Largest-Ellipsoid fusion.
library;

import 'dart:math' as math;

import 'fusion_bench.dart';
import 'fusion_bench_harness.dart';

/// Median of χ² with 2 degrees of freedom (2 ln 2).
const double kChi2Median2Dof = 1.3862943611198906;

/// Block size for the block bootstrap, polls.
const int kBootstrapBlock = 5;

/// Bootstrap resamples (deterministic seed — same input, same bars).
const int kBootstrapResamples = 200;

/// Normalized errors e = P^{-1/2}(x − truth) per scored poll.
List<(double, double)> normalizedErrors(
    List<ReplayPoll> polls, String armKey) {
  final out = <(double, double)>[];
  for (final p in polls) {
    final g = p.fused[armKey];
    if (g == null || p.truth == null || p.truthIds.length != 1) continue;
    // P^{-1/2} via the 2x2 symmetric eigendecomposition (closed form).
    final a = g.pxx, b = g.pxy, c = g.pyy;
    final trace = a + c;
    final disc = math.sqrt(math.max(0.0, (a - c) * (a - c) + 4 * b * b));
    final l1 = (trace + disc) / 2, l2 = (trace - disc) / 2;
    if (l1 <= 0 || l2 <= 0) continue;
    final dx = g.x - p.truth!.$1, dy = g.y - p.truth!.$2;
    // Rotate into the eigenbasis, scale, rotate back.
    final theta = 0.5 * math.atan2(2 * b, a - c);
    final ct = math.cos(theta), st = math.sin(theta);
    final u = ct * dx + st * dy;
    final v = -st * dx + ct * dy;
    final eu = u / math.sqrt(l1), ev = v / math.sqrt(l2);
    out.add((
      ct * eu - st * ev,
      st * eu + ct * ev,
    ));
  }
  return out;
}

/// Median NEES over the normalized errors.
double medianNees(List<(double, double)> errs) {
  if (errs.isEmpty) return double.nan;
  final vals = [for (final e in errs) e.$1 * e.$1 + e.$2 * e.$2]..sort();
  return vals[vals.length ~/ 2];
}

/// Median-χ² inflation k: median NEES / median χ²₂. k ≈ 1 is
/// consistent; k > 1 is overconfident.
double inflationK(List<(double, double)> errs) =>
    medianNees(errs) / kChi2Median2Dof;

/// Gaussian log score, split: mean over polls of
/// (NEES + log det P)/2 — the NEES term is consistency, the log-det
/// term is sharpness. Lower is better; the split is reported, not
/// just the total.
({double total, double neesTerm, double logDetTerm}) gaussianLogScore(
    List<ReplayPoll> polls, String armKey) {
  var neesSum = 0.0, logDetSum = 0.0, n = 0;
  for (final p in polls) {
    final g = p.fused[armKey];
    if (g == null || p.truth == null || p.truthIds.length != 1) continue;
    if (g.determinant <= 0) continue;
    neesSum += nees(g, p.truth!.$1, p.truth!.$2);
    logDetSum += math.log(g.determinant);
    n++;
  }
  if (n == 0) {
    return (total: double.nan, neesTerm: double.nan, logDetTerm: double.nan);
  }
  final neesTerm = neesSum / n / 2;
  final logDetTerm = logDetSum / n / 2;
  return (
    total: neesTerm + logDetTerm,
    neesTerm: neesTerm,
    logDetTerm: logDetTerm,
  );
}

/// λ_min/λ_max of the NEES matrix Ξ̂ = mean(e eᵀ) (closed-form 2×2
/// eigenvalues). A fusion rule passing scalar NEES but failing λ_max
/// is shown as FAIL — per Forsling, scalar NEES alone certified a
/// bad estimator as good.
({double lambdaMin, double lambdaMax}) neesEigenvalues(
    List<(double, double)> errs) {
  if (errs.isEmpty) {
    return (lambdaMin: double.nan, lambdaMax: double.nan);
  }
  var sxx = 0.0, sxy = 0.0, syy = 0.0;
  for (final e in errs) {
    sxx += e.$1 * e.$1;
    sxy += e.$1 * e.$2;
    syy += e.$2 * e.$2;
  }
  final n = errs.length.toDouble();
  final a = sxx / n, b = sxy / n, c = syy / n;
  final trace = a + c;
  final disc = math.sqrt(math.max(0.0, (a - c) * (a - c) + 4 * b * b));
  return (
    lambdaMin: (trace - disc) / 2,
    lambdaMax: (trace + disc) / 2,
  );
}

/// Block-bootstrap RMSE error bars: resample the polls in blocks of
/// [kBootstrapBlock] (deterministic seed 20261123), 200 resamples;
/// returns (rmse, low, high) as the 2.5/97.5 percentiles.
({double rmse, double low, double high}) bootstrapRmse(
    List<ReplayPoll> polls, String armKey) {
  final pairs = <(Gaussian2, (double, double))>[];
  for (final p in polls) {
    final g = p.fused[armKey];
    if (g != null && p.truth != null && p.truthIds.length == 1) {
      pairs.add((g, p.truth!));
    }
  }
  if (pairs.isEmpty) {
    return (rmse: double.nan, low: double.nan, high: double.nan);
  }
  double rmseOf(List<(Gaussian2, (double, double))> ps) {
    var s = 0.0;
    for (final (g, t) in ps) {
      s += (g.x - t.$1) * (g.x - t.$1) + (g.y - t.$2) * (g.y - t.$2);
    }
    return math.sqrt(s / ps.length);
  }

  final base = rmseOf(pairs);
  final blocks = <List<(Gaussian2, (double, double))>>[];
  for (var i = 0; i < pairs.length; i += kBootstrapBlock) {
    blocks.add(pairs.sublist(
        i, math.min(i + kBootstrapBlock, pairs.length)));
  }
  final rng = math.Random(20261123);
  final samples = <double>[];
  for (var r = 0; r < kBootstrapResamples; r++) {
    final resampled = <(Gaussian2, (double, double))>[];
    while (resampled.length < pairs.length) {
      resampled.addAll(blocks[rng.nextInt(blocks.length)]);
    }
    samples.add(rmseOf(resampled.sublist(0, pairs.length)));
  }
  samples.sort();
  return (
    rmse: base,
    low: samples[(samples.length * 0.025).floor()],
    high: samples[(samples.length * 0.975).floor()],
  );
}
