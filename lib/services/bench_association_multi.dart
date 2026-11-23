/// B9 multi-target association bench.
///
/// Source: Bocca, Kaltiokallio, Patwari & Venkatasubramanian,
/// "Multiple Target Tracking with RF Sensor Networks,"
/// arXiv:1302.4720v1 (READ IN FULL). MHT rejected for real-time
/// (paper's own numbers) — HAC + gated GNN/SNN + per-track KF only,
/// on top of the association machinery that already exists
/// (fusion_bench_association.dart: Hungarian + Mahalanobis gating).
///
/// Method per poll: HAC single-linkage clustering of the poll's
/// corroborator tracklets (CorrTrack positions, 1.5 m cut — the
/// mesh's own coarse-grid step scale), one constant-velocity KF per
/// cluster (predict/update on the cluster centroid), Hungarian
/// matching of clusters to the poll's truth positions, scored as
/// OMAT (mean matched distance), Q95, cardinality error, and
/// wall-clock time per poll.
///
/// Pass bar: OMAT ≤0.75 m, Q95 ≤1.5 m, cardinality error ≤0.05,
/// <100 ms/image.
library;

import 'dart:math' as math;

import 'bench_run.dart';
import 'fusion_bench_association.dart';
import 'fusion_bench_harness.dart';

/// HAC single-linkage cut, metres.
const double kB9ClusterCutM = 1.5;

/// Wall-clock budget per poll ("image"), milliseconds.
const double kB9DeadlineMs = 100.0;

/// One per-cluster constant-velocity KF (position + velocity, 2-D).
class _ClusterKf {
  _ClusterKf(double x, double y, DateTime t)
      : _x = x,
        _y = y,
        _vx = 0,
        _vy = 0,
        _lastT = t;

  double _x, _y, _vx, _vy;
  DateTime _lastT;

  (double, double) get pos => (_x, _y);

  void predict(DateTime t) {
    final dt = t.difference(_lastT).inMicroseconds / 1e6;
    if (dt <= 0) return;
    _x += _vx * dt;
    _y += _vy * dt;
    _lastT = t;
  }

  void update(double x, double y, DateTime t) {
    final dt = t.difference(_lastT).inMicroseconds / 1e6;
    // Fixed-gain update (α=0.6 position, β on velocity) — a bench
    // tracker, not the live tracker; gains are stated, not tuned.
    const alpha = 0.6;
    if (dt > 0) {
      final nvx = (x - _x) / dt;
      final nvy = (y - _y) / dt;
      _vx = 0.6 * _vx + 0.4 * nvx.clamp(-30.0, 30.0);
      _vy = 0.6 * _vy + 0.4 * nvy.clamp(-30.0, 30.0);
    }
    _x = _x + alpha * (x - _x);
    _y = _y + alpha * (y - _y);
    _lastT = t;
  }
}

/// HAC single-linkage clusters of [corrs] at [cutM].
List<List<CorrTrack>> _hac(List<CorrTrack> corrs, double cutM) {
  final clusters = <List<CorrTrack>>[
    for (final c in corrs) [c],
  ];
  var merged = true;
  while (merged) {
    merged = false;
    outer:
    for (var i = 0; i < clusters.length; i++) {
      for (var j = i + 1; j < clusters.length; j++) {
        var minD = double.infinity;
        for (final a in clusters[i]) {
          for (final b in clusters[j]) {
            final dx = a.x - b.x, dy = a.y - b.y;
            minD = math.min(minD, math.sqrt(dx * dx + dy * dy));
          }
        }
        if (minD <= cutM) {
          clusters[i].addAll(clusters[j]);
          clusters.removeAt(j);
          merged = true;
          break outer;
        }
      }
    }
  }
  return clusters;
}

/// Run the B9 bench over the RF-track sessions under [config].
BenchOutcome runAssociationMultiBench(BenchConfig config) {
  final load = loadRfSessions(config.sessionsDir);
  if (load.sessions.isEmpty) return skippedOutcome(load.rejected);

  final matchedErrors = <double>[];
  final cardErrors = <double>[];
  var maxPollMs = 0.0;
  var scoredPolls = 0;
  final tracks = <_ClusterKf>[];
  var multiPolls = 0;

  for (final session in load.sessions) {
    final polls = replaySession(session, config);
    for (final p in polls) {
      final sw = Stopwatch()..start();
      final truths = _truthPositions(session, p.t);
      if (truths.length > 1) multiPolls++;
      final clusters = _hac(p.corrTracks, kB9ClusterCutM);
      // Predict all tracks, then nearest-cluster update (gated at
      // the HAC cut — a cluster beyond the cut starts a new track).
      for (final tr in tracks) {
        tr.predict(p.t);
      }
      final used = <int>{};
      for (final cluster in clusters) {
        var cx = 0.0, cy = 0.0;
        for (final c in cluster) {
          cx += c.x;
          cy += c.y;
        }
        cx /= cluster.length;
        cy /= cluster.length;
        var best = -1;
        var bestD = double.infinity;
        for (var i = 0; i < tracks.length; i++) {
          if (used.contains(i)) continue;
          final (tx, ty) = tracks[i].pos;
          final d = math.sqrt((tx - cx) * (tx - cx) + (ty - cy) * (ty - cy));
          if (d < bestD) {
            bestD = d;
            best = i;
          }
        }
        if (best >= 0 && bestD <= kB9ClusterCutM) {
          tracks[best].update(cx, cy, p.t);
          used.add(best);
        } else {
          tracks.add(_ClusterKf(cx, cy, p.t));
        }
      }
      sw.stop();
      maxPollMs = math.max(
          maxPollMs, sw.elapsedMicroseconds / 1000.0);
      if (truths.isEmpty || clusters.isEmpty) continue;
      scoredPolls++;
      // Hungarian match of cluster centroids to truth positions.
      final centroids = <(double, double)>[];
      for (final cluster in clusters) {
        var cx = 0.0, cy = 0.0;
        for (final c in cluster) {
          cx += c.x;
          cy += c.y;
        }
        centroids.add((cx / cluster.length, cy / cluster.length));
      }
      final cost = [
        for (final c in centroids)
          [
            for (final t in truths)
              math.sqrt((c.$1 - t.$1) * (c.$1 - t.$1) +
                  (c.$2 - t.$2) * (c.$2 - t.$2)),
          ],
      ];
      final pairs = hungarian(cost);
      for (final (i, j) in pairs) {
        matchedErrors.add(cost[i][j]);
      }
      final denom = math.max(1, truths.length);
      cardErrors.add(
          (clusters.length - truths.length).abs() / denom);
    }
  }

  matchedErrors.sort();
  final omat = matchedErrors.isEmpty
      ? double.nan
      : matchedErrors.fold(0.0, (a, b) => a + b) / matchedErrors.length;
  final q95 = matchedErrors.isEmpty
      ? double.nan
      : matchedErrors[((matchedErrors.length - 1) * 0.95).round()];
  final cardErr = cardErrors.isEmpty
      ? double.nan
      : cardErrors.fold(0.0, (a, b) => a + b) / cardErrors.length;
  return BenchOutcome(
    skipped: false,
    sessionsRun: sessionNames(load),
    rejected: load.rejected,
    verdicts: [
      BenchVerdict(
        bar: 'B9: OMAT ≤0.75 m',
        passed: omat.isFinite && omat <= 0.75,
        detail: 'OMAT ${omat.toStringAsFixed(3)} m over '
            '${matchedErrors.length} matched pairs, $scoredPolls scored '
            'polls ($multiPolls multi-target polls)',
      ),
      BenchVerdict(
        bar: 'B9: Q95 ≤1.5 m',
        passed: q95.isFinite && q95 <= 1.5,
        detail: 'Q95 ${q95.toStringAsFixed(3)} m',
      ),
      BenchVerdict(
        bar: 'B9: cardinality error ≤0.05',
        passed: cardErr.isFinite && cardErr <= 0.05,
        detail: 'mean cardinality error ${cardErr.toStringAsFixed(3)}',
      ),
      BenchVerdict(
        bar: 'B9: <100 ms/image (wall-clock per poll on this phone)',
        passed: maxPollMs < kB9DeadlineMs,
        detail: 'max per-poll ${maxPollMs.toStringAsFixed(1)} ms',
      ),
    ],
  );
}

/// Distinct truth positions at poll [t] (one per truth_id).
List<(double, double)> _truthPositions(BenchSession session, DateTime t) {
  final out = <(double, double)>[];
  final seen = <String>{};
  for (final r in session.rowsAt(t)) {
    if (r.truthX == null || r.truthY == null || r.truthId == null) {
      continue;
    }
    if (seen.add(r.truthId!)) out.add((r.truthX!, r.truthY!));
  }
  return out;
}
