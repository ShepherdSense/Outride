/// B1 fusion bench — CI vs ICI vs naive information-form fusion.
///
/// EXPERIMENTAL — bench-only library, never wired into the live tracker
/// or the app UI. It exists to MEASURE the queued B1 bench
/// (bench-queue-2026-11-06.md) on recorded Outride track sessions:
/// which fusion rule keeps the fused track honest (NEES inside 95%
/// bounds) with the lowest RMSE, and how many consensus iterations the
/// L-rule demands for a given mesh.
///
/// Sources (full reads, lane 3):
/// - Yang et al., Drones 2026, 10, 107 — the bench's origin: CI vs ICI
///   vs naive information-form fusion, L-rule
///   L >= max(mesh diameter, ln(N-1)/ln(1/lambda)), lambda = second-
///   largest eigenvalue of the doubly-stochastic weight matrix.
/// - Tian et al., Sensors 2026, 26, 4251 — ICI recursive form (eq. 6):
///   omega chosen by minimizing tr(P_f), SPD check + diagonal
///   regularization. First REAL-data ICI datapoint in the lane.
/// - Tao et al., Appl. Sci. 2026, 16, 3159 — feature-aided association
///   arm (see fusion_bench_association.dart).
///
/// What is NOT ported (per the lane verdicts and the bench queue):
/// - Yang's distributed-consensus machinery and SRCIF (Outride's
///   tracker is centralized on the EUD; the bench's consensus driver
///   below is the bench's own explicit scheme, not Yang's).
/// - Any paper number as an expected Outride gain (Yang's 0.17 m ICI
///   RMSE, Tao's 37–54% OSPA, Tian's 98.4%/0.23 m). The bench's pass
///   bars are RELATIVE (ICI RMSE < CI RMSE, NEES in-bounds) on
///   Outride's own recorded sessions.
/// - The app tracker (lib/services/tracker.dart) keeps NO state
///   covariance, so the bench carries its own (mean, covariance)
///   estimate type [Gaussian2] — a bench-side representation, not the
///   live tracker's state.
///
/// DATA RULE (standing): the bench measurement runs ONLY on recorded
/// Outride track sessions (see fusion_bench_harness.dart). With no
/// recorded sessions present the harness reports "measurement pending —
/// no recorded data" and skips; it never runs on synthetic data.
library;

import 'dart:math' as math;

/// Fusion rule arms of the B1 bench.
enum FusionRule {
  /// Covariance Intersection: conservative, assumes unknown correlation.
  ci,

  /// Inverse Covariance Intersection: assumes a known common-information
  /// component; omega chosen by minimizing tr(P_f).
  ici,

  /// Naive information-form fusion: adds information matrices outright.
  /// Double-counts common information — the control arm, expected to
  /// go overconfident (NEES out of bounds) on correlated inputs.
  naive,
}

/// A 2-D Gaussian track estimate: position mean + 2x2 covariance.
///
/// Position-only on purpose: Outride tracks are RF link-shadow blobs
/// (position/heading/size), and the fusion question is about the
/// position estimate and its honesty. Velocity is carried by the
/// association arm (fusion_bench_association.dart), not here.
class Gaussian2 {
  const Gaussian2({
    required this.x,
    required this.y,
    required this.pxx,
    required this.pxy,
    required this.pyy,
  });

  final double x;
  final double y;

  /// Covariance [[pxx, pxy], [pxy, pyy]] (m^2).
  final double pxx;
  final double pxy;
  final double pyy;

  double get trace => pxx + pyy;

  double get determinant => pxx * pyy - pxy * pxy;

  /// Symmetric positive-definite: pxx > 0 and det > 0.
  bool get isSpd => pxx > 0 && determinant > 0;

  /// Inverse covariance (information matrix) as [yxx, yxy, yyy].
  /// Throws [StateError] when not invertible; callers must SPD-check
  /// (and regularize) first.
  List<double> get information {
    final det = determinant;
    if (det <= 0) {
      throw StateError('Gaussian2 not invertible (det=$det)');
    }
    return [pyy / det, -pxy / det, pxx / det];
  }

  /// Information vector P^-1 * [x, y].
  List<double> get informationVector {
    final yi = information;
    return [yi[0] * x + yi[1] * y, yi[1] * x + yi[2] * y];
  }

  /// This estimate with [eps] added to the covariance diagonal.
  Gaussian2 regularized(double eps) => Gaussian2(
        x: x,
        y: y,
        pxx: pxx + eps,
        pxy: pxy,
        pyy: pyy + eps,
      );

  @override
  String toString() =>
      'Gaussian2(x=${x.toStringAsFixed(2)}, y=${y.toStringAsFixed(2)}, '
      'P=[[${pxx.toStringAsFixed(2)}, ${pxy.toStringAsFixed(2)}], '
      '[${pxy.toStringAsFixed(2)}, ${pyy.toStringAsFixed(2)}]])';
}

/// Build a [Gaussian2] from an information matrix + vector.
/// Throws [StateError] when the information matrix is not SPD.
Gaussian2 gaussianFromInformation(
  List<double> infoMatrix,
  List<double> infoVector,
) {
  final a = infoMatrix[0], b = infoMatrix[1], c = infoMatrix[2];
  final det = a * c - b * b;
  if (a <= 0 || det <= 0) {
    throw StateError('information matrix not SPD (det=$det)');
  }
  final pxx = c / det, pxy = -b / det, pyy = a / det;
  final x = pxx * infoVector[0] + pxy * infoVector[1];
  final y = pxy * infoVector[0] + pyy * infoVector[1];
  return Gaussian2(x: x, y: y, pxx: pxx, pxy: pxy, pyy: pyy);
}

/// Result of a pairwise fusion: the fused estimate and the omega used
/// (NaN for the naive arm, which takes no omega).
class FusionResult {
  const FusionResult({required this.fused, required this.omega});

  final Gaussian2 fused;

  /// Weight on the first estimate (0..1); NaN when not applicable.
  final double omega;
}

/// Grid step for the omega search minimizing tr(P_f). The SDP
/// family-optimal CI arm (bench queue arm 1, Pedroso et al.) replaces
/// this grid with the principled optimum when it is built; the grid is
/// the base arm's explicit, reproducible choice, not a claim of
/// optimality.
const double omegaGridStep = 0.01;

/// Covariance Intersection of [a] and [b].
///
/// P_f^-1 = w*P_a^-1 + (1-w)*P_b^-1, x_f = P_f*(w*P_a^-1*x_a +
/// (1-w)*P_b^-1*x_b), with w chosen on a 0..1 grid to minimize
/// tr(P_f). Inputs are regularized (diagonal bump) when not SPD.
///
/// Endpoint guarantee: a convex combination of two SPD information
/// matrices is SPD, so every omega on the closed 0..1 grid yields a
/// valid candidate — at omega=0 the result is exactly [b], at
/// omega=1 exactly [a]. CI therefore always returns a numeric omega
/// and never needs a fallback.
FusionResult ciFuse(Gaussian2 a, Gaussian2 b) {
  final ra = _ensureSpd(a);
  final rb = _ensureSpd(b);
  final ya = ra.information;
  final yb = rb.information;
  final va = ra.informationVector;
  final vb = rb.informationVector;
  var bestOmega = 0.5;
  var bestTrace = double.infinity;
  Gaussian2? best;
  for (var k = 0; k <= 100; k++) {
    final w = k * omegaGridStep;
    final info = [
      w * ya[0] + (1 - w) * yb[0],
      w * ya[1] + (1 - w) * yb[1],
      w * ya[2] + (1 - w) * yb[2],
    ];
    final vec = [
      w * va[0] + (1 - w) * vb[0],
      w * va[1] + (1 - w) * vb[1],
    ];
    Gaussian2 cand;
    try {
      cand = gaussianFromInformation(info, vec);
    } on StateError {
      continue;
    }
    if (cand.trace < bestTrace) {
      bestTrace = cand.trace;
      bestOmega = w;
      best = cand;
    }
  }
  final fused = best!;
  return FusionResult(fused: fused, omega: bestOmega);
}

/// Inverse Covariance Intersection of [a] and [b] — Tian et al.
/// recursive form (eq. 6).
///
/// P_m = w*P_a + (1-w)*P_b (the common-information covariance).
/// P_f^-1 = P_a^-1 + P_b^-1 - P_m^-1,
/// x_f = P_f*(P_a^-1*x_a + P_b^-1*x_b -
///            P_m^-1*(w*x_a + (1-w)*x_b)),
/// with w chosen on a 0..1 grid to minimize tr(P_f). Candidates
/// whose information matrix is not SPD are skipped (Tian's SPD
/// check).
///
/// Endpoint guarantee (no fallback exists): at omega=0, P_m = P_b,
/// so the ICI information matrix is exactly Y_a; at omega=1 it is
/// exactly Y_b. Both inputs are SPD (regularized above), so the
/// closed 0..1 grid always contains an SPD candidate and ICI always
/// returns a numeric omega in [0,1] with an SPD result. NaN omega
/// now occurs only for the naive arm, which takes no omega.
FusionResult iciFuse(Gaussian2 a, Gaussian2 b) {
  final ra = _ensureSpd(a);
  final rb = _ensureSpd(b);
  final ya = ra.information;
  final yb = rb.information;
  final va = ra.informationVector;
  final vb = rb.informationVector;
  var bestOmega = 0.5;
  var bestTrace = double.infinity;
  Gaussian2? best;
  for (var k = 0; k <= 100; k++) {
    final w = k * omegaGridStep;
    // P_m = w*P_a + (1-w)*P_b.
    final pm = Gaussian2(
      x: 0,
      y: 0,
      pxx: w * ra.pxx + (1 - w) * rb.pxx,
      pxy: w * ra.pxy + (1 - w) * rb.pxy,
      pyy: w * ra.pyy + (1 - w) * rb.pyy,
    );
    List<double> ym;
    try {
      ym = pm.information;
    } on StateError {
      continue;
    }
    final info = [ya[0] + yb[0] - ym[0], ya[1] + yb[1] - ym[1],
      ya[2] + yb[2] - ym[2]];
    final mx = w * ra.x + (1 - w) * rb.x;
    final my = w * ra.y + (1 - w) * rb.y;
    final vec = [
      va[0] + vb[0] - (ym[0] * mx + ym[1] * my),
      va[1] + vb[1] - (ym[1] * mx + ym[2] * my),
    ];
    Gaussian2 cand;
    try {
      cand = gaussianFromInformation(info, vec);
    } on StateError {
      continue; // SPD check failed for this omega — Tian's rule.
    }
    if (cand.trace < bestTrace) {
      bestTrace = cand.trace;
      bestOmega = w;
      best = cand;
    }
  }
  // Endpoint guarantee (see docstring): omega=0 and omega=1 both
  // yield SPD candidates, so `best` is never null here.
  return FusionResult(fused: best!, omega: bestOmega);
}

/// Naive information-form fusion: adds information matrices outright.
/// Double-counts any common information — the control arm.
FusionResult naiveFuse(Gaussian2 a, Gaussian2 b) {
  final ra = _ensureSpd(a);
  final rb = _ensureSpd(b);
  final ya = ra.information;
  final yb = rb.information;
  final va = ra.informationVector;
  final vb = rb.informationVector;
  final info = [ya[0] + yb[0], ya[1] + yb[1], ya[2] + yb[2]];
  final vec = [va[0] + vb[0], va[1] + vb[1]];
  final fused = gaussianFromInformation(info, vec);
  return FusionResult(fused: fused, omega: double.nan);
}

/// Fuse one pair under [rule].
FusionResult fusePair(Gaussian2 a, Gaussian2 b, FusionRule rule) {
  switch (rule) {
    case FusionRule.ci:
      return ciFuse(a, b);
    case FusionRule.ici:
      return iciFuse(a, b);
    case FusionRule.naive:
      return naiveFuse(a, b);
  }
}

/// Ensure SPD by diagonal regularization (Tian's rule): bump the
/// diagonal by eps, growing x10, until SPD or the cap is hit.
Gaussian2 _ensureSpd(Gaussian2 g) {
  if (g.isSpd) return g;
  var eps = 1e-6 * (g.trace.abs() + 1.0);
  var cur = g;
  for (var i = 0; i < 10; i++) {
    cur = g.regularized(eps);
    if (cur.isSpd) return cur;
    eps *= 10;
  }
  return cur;
}

/// --- Weight matrices ---------------------------------------------------

/// Metropolis weights for an undirected mesh.
///
/// adjacency[i] lists the neighbors of node i. w_ij =
/// 1/(1+max(deg_i, deg_j)) for neighbors, w_ii = 1 - sum_{j!=i} w_ij.
/// Doubly stochastic by construction.
List<List<double>> metropolisWeights(List<List<int>> adjacency) {
  final n = adjacency.length;
  final w = List.generate(n, (_) => List.filled(n, 0.0));
  for (var i = 0; i < n; i++) {
    var rowSum = 0.0;
    for (final j in adjacency[i]) {
      final wij = 1.0 / (1.0 + _max(adjacency[i].length,
          adjacency[j].length));
      w[i][j] = wij;
      rowSum += wij;
    }
    w[i][i] = 1.0 - rowSum;
  }
  return w;
}

int _max(int a, int b) => a > b ? a : b;

/// Centrality-weighted variant (bench variant, B1 spec).
///
/// Start from symmetric weights s_ij = sqrt(c_i * c_j) on edges
/// (c = degree centrality, self-weight c_i), then Sinkhorn-Knopp
/// row/column normalization (50 rounds) to a doubly-stochastic
/// matrix, so the L-rule's lambda still applies. The centrality
/// weighting is the bench's own variant — no paper claims it.
List<List<double>> centralityWeights(List<List<int>> adjacency) {
  final n = adjacency.length;
  final c = [for (final nb in adjacency) nb.length.toDouble()];
  final s = List.generate(n, (_) => List.filled(n, 0.0));
  for (var i = 0; i < n; i++) {
    s[i][i] = c[i] == 0 ? 1.0 : c[i];
    for (final j in adjacency[i]) {
      final ci = c[i] == 0 ? 1.0 : c[i];
      final cj = c[j] == 0 ? 1.0 : c[j];
      s[i][j] = math.sqrt(ci * cj);
    }
  }
  // Sinkhorn-Knopp: alternate row/column normalization.
  var w = s;
  for (var round = 0; round < 50; round++) {
    for (var i = 0; i < n; i++) {
      final sum = w[i].fold(0.0, (p, e) => p + e);
      if (sum > 0) {
        for (var j = 0; j < n; j++) {
          w[i][j] /= sum;
        }
      }
    }
    for (var j = 0; j < n; j++) {
      var sum = 0.0;
      for (var i = 0; i < n; i++) {
        sum += w[i][j];
      }
      if (sum > 0) {
        for (var i = 0; i < n; i++) {
          w[i][j] /= sum;
        }
      }
    }
  }
  return w;
}

/// Mesh diameter: longest shortest-path hop count (BFS). 0 for a
/// single node, -1 when the mesh is disconnected.
int meshDiameter(List<List<int>> adjacency) {
  final n = adjacency.length;
  if (n <= 1) return 0;
  var diameter = 0;
  for (var s = 0; s < n; s++) {
    final dist = List.filled(n, -1);
    dist[s] = 0;
    final queue = <int>[s];
    var head = 0;
    while (head < queue.length) {
      final u = queue[head++];
      for (final v in adjacency[u]) {
        if (dist[v] < 0) {
          dist[v] = dist[u] + 1;
          queue.add(v);
        }
      }
    }
    for (final d in dist) {
      if (d < 0) return -1; // disconnected
      if (d > diameter) diameter = d;
    }
  }
  return diameter;
}

/// Second-largest eigenvalue magnitude of a symmetric doubly-stochastic
/// weight matrix, via power iteration on (W - J/N).
///
/// Deterministic: fixed iteration count and fixed start vectors
/// (alternating-sign, then shifted variants). Returns NaN when the
/// matrix is degenerate (N < 2).
double secondLargestEigenvalue(List<List<double>> w) {
  final n = w.length;
  if (n < 2) return double.nan;
  // A = W - (1/N) * 11^T.
  final a = List.generate(
    n,
    (i) => List.generate(
        n, (j) => w[i][j] - 1.0 / n),
  );
  var best = 0.0;
  for (var trial = 0; trial < 3; trial++) {
    var v = List.generate(
        n, (i) => ((i + trial) % 2 == 0 ? 1.0 : -1.0));
    // Orthogonalize against the all-ones vector.
    final mean = v.fold(0.0, (p, e) => p + e) / n;
    for (var i = 0; i < n; i++) {
      v[i] -= mean;
    }
    var norm = _vecNorm(v);
    if (norm < 1e-12) continue;
    for (var i = 0; i < n; i++) {
      v[i] /= norm;
    }
    for (var it = 0; it < 200; it++) {
      final av = List.generate(
        n,
        (i) {
          var s = 0.0;
          for (var j = 0; j < n; j++) {
            s += a[i][j] * v[j];
          }
          return s;
        },
      );
      final nrm = _vecNorm(av);
      if (nrm < 1e-12) break;
      for (var i = 0; i < n; i++) {
        v[i] = av[i] / nrm;
      }
    }
    // Rayleigh quotient |v^T A v|.
    var rq = 0.0;
    for (var i = 0; i < n; i++) {
      var s = 0.0;
      for (var j = 0; j < n; j++) {
        s += a[i][j] * v[j];
      }
      rq += v[i] * s;
    }
    final mag = rq.abs();
    if (mag > best) best = mag;
  }
  return best;
}

double _vecNorm(List<double> v) {
  var s = 0.0;
  for (final e in v) {
    s += e * e;
  }
  return math.sqrt(s);
}

/// Fusion iteration count per the L-rule (Yang et al.):
/// L >= max(mesh diameter, ln(N-1)/ln(1/lambda)).
///
/// Guards: N < 2 -> 1; disconnected mesh (diameter -1) -> diameter
/// term ignored, lambda term used, and the caller is told via
/// [lRuleDisconnected] on the returned record; lambda >= 1 or <= 0
/// -> the log term is undefined, so L falls back to the diameter
/// (minimum 1).
({int iterations, bool disconnected, double lambda2}) fusionIterations({
  required int nodeCount,
  required double lambda2,
  required int diameter,
}) {
  final disconnected = diameter < 0;
  var logTerm = 0.0;
  if (nodeCount > 1 && lambda2 > 0 && lambda2 < 1) {
    logTerm = math.log(nodeCount - 1) / math.log(1.0 / lambda2);
  }
  final d = disconnected ? 0 : diameter;
  final l = _max(1, _ceilInt(_maxDouble(d.toDouble(), logTerm)));
  return (iterations: l, disconnected: disconnected, lambda2: lambda2);
}

double _maxDouble(double a, double b) => a > b ? a : b;

int _ceilInt(double v) {
  final t = v.truncate();
  return (v > t) ? t + 1 : t;
}

/// --- Consensus driver --------------------------------------------------

/// One consensus round under [rule]: every node first forms the
/// weight-matrix aggregate of its neighbors' information (Y, y), then
/// combines its own estimate with that aggregate via [rule].
///
/// This is the BENCH's explicit consensus scheme (documented in
/// docs/fusion_bench_b1_spec.md) — it is NOT a port of Yang's
/// distributed-consensus machinery (excluded by the bench queue).
///
/// Returns the per-node estimates after the round.
List<Gaussian2> consensusRound(
  List<Gaussian2> estimates,
  List<List<double>> weights,
  FusionRule rule,
) {
  final n = estimates.length;
  final infos = [for (final e in estimates) e.information];
  final vecs = [for (final e in estimates) e.informationVector];
  final out = <Gaussian2>[];
  for (var i = 0; i < n; i++) {
    final aggInfo = [0.0, 0.0, 0.0];
    final aggVec = [0.0, 0.0];
    for (var j = 0; j < n; j++) {
      final wij = weights[i][j];
      if (wij == 0) continue;
      aggInfo[0] += wij * infos[j][0];
      aggInfo[1] += wij * infos[j][1];
      aggInfo[2] += wij * infos[j][2];
      aggVec[0] += wij * vecs[j][0];
      aggVec[1] += wij * vecs[j][1];
    }
    Gaussian2 agg;
    try {
      agg = gaussianFromInformation(aggInfo, aggVec);
    } on StateError {
      agg = estimates[i];
    }
    final r = fusePair(estimates[i], agg, rule);
    out.add(r.fused);
  }
  return out;
}

/// Run [iterations] consensus rounds. Returns the per-node fused
/// estimates after the final round.
List<Gaussian2> consensusFuse({
  required List<Gaussian2> estimates,
  required List<List<double>> weights,
  required int iterations,
  required FusionRule rule,
}) {
  var cur = estimates;
  for (var k = 0; k < iterations; k++) {
    cur = consensusRound(cur, weights, rule);
  }
  return cur;
}

/// --- Scoring -----------------------------------------------------------

/// Normalized Estimation Error Squared for a fused estimate against
/// ground truth (2 dof): e^T P^-1 e.
double nees(Gaussian2 fused, double truthX, double truthY) {
  final ex = fused.x - truthX;
  final ey = fused.y - truthY;
  final info = fused.information;
  return ex * ex * info[0] + 2 * ex * ey * info[1] + ey * ey * info[2];
}

/// 95% bounds for the MEAN NEES over [n] independent 2-dof samples,
/// via the Wilson–Hilferty chi-square approximation:
/// chi2_p(nu) ~= nu * (1 - 2/(9nu) + z_p*sqrt(2/(9nu)))^3.
/// Returns (low, high) for mean NEES = chi2(2n)/n.
({double low, double high}) neesMeanBounds95(int n) {
  if (n <= 0) return (low: double.nan, high: double.nan);
  final nu = 2.0 * n;
  final c = 1.0 - 2.0 / (9.0 * nu);
  final s = math.sqrt(2.0 / (9.0 * nu));
  final lo = nu * _pow3(c - 1.959964 * s) / n;
  final hi = nu * _pow3(c + 1.959964 * s) / n;
  return (low: lo, high: hi);
}

double _pow3(double v) => v * v * v;

/// Root-mean-square position error (m) of [estimates] against
/// [truths] (paired lists of (x, y)).
double rmse(
  List<(double, double)> estimates,
  List<(double, double)> truths,
) {
  if (estimates.isEmpty || estimates.length != truths.length) {
    throw ArgumentError('rmse needs non-empty paired lists');
  }
  var s = 0.0;
  for (var i = 0; i < estimates.length; i++) {
    final dx = estimates[i].$1 - truths[i].$1;
    final dy = estimates[i].$2 - truths[i].$2;
    s += dx * dx + dy * dy;
  }
  return math.sqrt(s / estimates.length);
}
