/// Hungarian algorithm (Kuhn–Munkres, O(n^3) potentials method) for
/// a rectangular cost matrix, minimizing total cost.
///
/// Shared production home for the solver. Extracted verbatim from
/// the B1 bench (`lib/services/fusion_bench_association.dart`),
/// where it lived as a bench-only helper; the bench now imports it
/// from here, and the live tracker (`TrackStitcher.checkHandoffs`)
/// uses it for globally-optimal batch handoff association.
///
/// Reference: https://cp-algorithms.com/assignment/hungarian.html
/// (e-maxx style 1-indexed potentials implementation: row potentials
/// `u`, column potentials `v`, per-column minimum slack `minv`,
/// predecessor `way`, matching `p`, with a sentinel column 0).
library;

/// Hungarian algorithm (Kuhn–Munkres, O(n^3) potentials method) for a
/// rectangular cost matrix, minimizing total cost.
///
/// [cost] is rows x cols (rows <= cols; transposed internally when
/// rows > cols). Returns the assigned (row, col) pairs. All costs
/// must be finite; use a prohibitive cost (not infinity) for gated
/// pairs.
List<(int, int)> hungarian(List<List<double>> cost) {
  final n = cost.length;
  if (n == 0) return const [];
  final m = cost[0].length;
  if (m == 0) return const [];
  if (n > m) {
    // Transpose so rows <= cols, then swap the pairs back.
    final t = List.generate(
        m, (j) => List.generate(n, (i) => cost[i][j]));
    return [for (final (j, i) in hungarian(t)) (i, j)];
  }
  // 1-indexed potentials implementation (e-maxx style).
  final u = List.filled(n + 1, 0.0);
  final v = List.filled(m + 1, 0.0);
  final p = List.filled(m + 1, 0);
  final way = List.filled(m + 1, 0);
  for (var i = 1; i <= n; i++) {
    p[0] = i;
    var j0 = 0;
    final minv = List.filled(m + 1, double.infinity);
    final used = List.filled(m + 1, false);
    do {
      used[j0] = true;
      final i0 = p[j0];
      var delta = double.infinity;
      var j1 = 0;
      for (var j = 1; j <= m; j++) {
        if (used[j]) continue;
        final cur = cost[i0 - 1][j - 1] - u[i0] - v[j];
        if (cur < minv[j]) {
          minv[j] = cur;
          way[j] = j0;
        }
        if (minv[j] < delta) {
          delta = minv[j];
          j1 = j;
        }
      }
      for (var j = 0; j <= m; j++) {
        if (used[j]) {
          u[p[j]] += delta;
          v[j] -= delta;
        } else {
          minv[j] -= delta;
        }
      }
      j0 = j1;
    } while (p[j0] != 0);
    do {
      final j1 = way[j0];
      p[j0] = p[j1];
      j0 = j1;
    } while (j0 != 0);
  }
  final out = <(int, int)>[];
  for (var j = 1; j <= m; j++) {
    if (p[j] != 0) out.add((p[j] - 1, j - 1));
  }
  return out;
}
