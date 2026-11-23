/// B10 1-bit detector back-projection bench (accuracy arm ONLY).
///
/// Source: Yiğitler, Jäntti, Kaltiokallio & Patwari, "Detector Based
/// Radio Tomographic Imaging," arXiv:1604.03083v1 (READ IN FULL).
/// Paper numbers are the paper's, never Outride results: per-link
/// binary detector + back-projection, zero floating-point
/// multiplications by construction.
///
/// Method: per link, a 1-bit detector fires when dip_db exceeds the
/// link's own running median dip (the paper's per-link detector, in
/// the bench's own terms — no threshold is ported from the paper).
/// The median is computed from the link's dip history BEFORE the
/// current sample is added (the first poll for a link therefore
/// cannot fire — there is no median yet — instead of a median that
/// includes the sample it is testing). Firing links back-project
/// onto a 1 m field grid: each firing link votes for the grid cells
/// nearest its midpoint (Gaussian splat, σ=1.5 m). The peak cell is
/// the estimate. Scored against truth and against the current RTI
/// error — the B1 CI/metropolis fused RMSE on the same data.
///
/// "Zero floating-point multiplications" is the PAPER's property of
/// its detector, not this bench's: the Dart back-projection uses
/// exp splats and float multiplications, so this is an
/// accuracy-arm approximation of the paper's construction, and the
/// result says so.
///
/// The on-ESP32-S3 cycle-count/RAM arm is QUEUED-BLOCKED (firmware
/// work with no firmware path in this build) — the row shows PARTIAL
/// when the accuracy arm runs, never PASS on accuracy alone.
///
/// Pass bar: mean error ≤0.5 m AND ≤1.5× current RTI error on same
/// data.
library;

import 'dart:math' as math;

import 'bench_csi.dart' show kBenchPending;
import 'bench_run.dart';
import 'fusion_bench_harness.dart';

/// Back-projection grid step, metres.
const double kB10GridStepM = 1.0;

/// Back-projection splat sigma, metres.
const double kB10SplatSigmaM = 1.5;

/// Field extent for the back-projection grid, metres (from node
/// positions + margin).
const double kB10MarginM = 5.0;

/// Run the B10 accuracy arm over the RF-track sessions under [config].
BenchOutcome runDetectorBench(BenchConfig config) {
  final load = loadRfSessions(config.sessionsDir);
  if (load.sessions.isEmpty) return skippedOutcome(load.rejected);

  // Field bounds from node positions.
  final xs = [for (final n in config.nodes.values) n.x];
  final ys = [for (final n in config.nodes.values) n.y];
  if (xs.isEmpty) {
    return BenchOutcome(
      skipped: true,
      skipReason: kBenchPending,
      rejected: {
        ...load.rejected,
        '(nodes)': 'no node geometry — <session>.meta.json missing',
      },
    );
  }
  final minX = xs.reduce(math.min) - kB10MarginM;
  final maxX = xs.reduce(math.max) + kB10MarginM;
  final minY = ys.reduce(math.min) - kB10MarginM;
  final maxY = ys.reduce(math.max) + kB10MarginM;
  final nx = ((maxX - minX) / kB10GridStepM).ceil() + 1;
  final ny = ((maxY - minY) / kB10GridStepM).ceil() + 1;

  // Per-link running dip history for the 1-bit detector threshold.
  final dipHistory = <String, List<double>>{};
  final errors = <double>[];
  final rtiPairs = <(double, double, double, double)>[];
  for (final session in load.sessions) {
    final polls = replaySession(session, config);
    for (final p in polls) {
      // Update dip history from this poll's rows, then detect.
      // The median is taken from history BEFORE the current sample
      // is added: a median that includes the sample under test can
      // never fire on the first poll for a link (the sample IS the
      // median). A link with no history yet cannot fire.
      final fired = <(double, double)>[];
      for (final r in session.rowsAt(p.t)) {
        final d = r.dipDb ?? 0;
        final hist = [...(dipHistory[r.linkKey] ?? [])]..sort();
        (dipHistory[r.linkKey] ??= []).add(d);
        if (hist.isEmpty) continue;
        final median = hist[hist.length ~/ 2];
        if (d > median && d > config.dipThresholdDb) {
          final a = config.nodes[r.fromNode];
          final b = config.nodes[r.toNode];
          if (a == null || b == null) continue;
          fired.add(((a.x + b.x) / 2, (a.y + b.y) / 2));
        }
      }
      if (fired.isEmpty || p.truth == null || p.truthIds.length != 1) {
        continue;
      }
      // Back-project: vote grid, peak cell wins.
      final grid = List.generate(nx, (_) => List.filled(ny, 0.0));
      for (final (mx, my) in fired) {
        final gx0 = ((mx - minX) / kB10GridStepM).round();
        final gy0 = ((my - minY) / kB10GridStepM).round();
        const radius = 3;
        for (var dx = -radius; dx <= radius; dx++) {
          for (var dy = -radius; dy <= radius; dy++) {
            final gx = gx0 + dx, gy = gy0 + dy;
            if (gx < 0 || gy < 0 || gx >= nx || gy >= ny) continue;
            final dist2 = dx * dx + dy * dy;
            grid[gx][gy] += math.exp(
                -dist2 / (2 * kB10SplatSigmaM * kB10SplatSigmaM));
          }
        }
      }
      var bestX = 0.0, bestY = 0.0, bestV = -1.0;
      for (var gx = 0; gx < nx; gx++) {
        for (var gy = 0; gy < ny; gy++) {
          if (grid[gx][gy] > bestV) {
            bestV = grid[gx][gy];
            bestX = minX + gx * kB10GridStepM;
            bestY = minY + gy * kB10GridStepM;
          }
        }
      }
      final dx = bestX - p.truth!.$1, dy = bestY - p.truth!.$2;
      errors.add(math.sqrt(dx * dx + dy * dy));
      final ci = p.fused['CI/metropolis'];
      if (ci != null) {
        rtiPairs.add((ci.x, ci.y, p.truth!.$1, p.truth!.$2));
      }
    }
  }

  final meanErr = errors.isEmpty
      ? double.nan
      : errors.fold(0.0, (a, b) => a + b) / errors.length;
  var rtiRmse = double.nan;
  if (rtiPairs.isNotEmpty) {
    var s = 0.0;
    for (final (x, y, tx, ty) in rtiPairs) {
      s += (x - tx) * (x - tx) + (y - ty) * (y - ty);
    }
    rtiRmse = math.sqrt(s / rtiPairs.length);
  }
  return BenchOutcome(
    skipped: false,
    sessionsRun: sessionNames(load),
    rejected: load.rejected,
    verdicts: [
      BenchVerdict(
        bar: 'B10 accuracy: mean error ≤0.5 m',
        passed: meanErr.isFinite && meanErr <= 0.5,
        detail: 'mean back-projection error ${meanErr.toStringAsFixed(3)} m '
            'over ${errors.length} scored polls',
      ),
      BenchVerdict(
        bar: 'B10 accuracy: mean error ≤1.5× current RTI error on same '
            'data',
        passed: meanErr.isFinite &&
            rtiRmse.isFinite &&
            meanErr <= 1.5 * rtiRmse,
        detail: 'detector ${meanErr.toStringAsFixed(3)} m vs RTI '
            '(CI/metropolis) ${rtiRmse.toStringAsFixed(3)} m',
      ),
      const BenchVerdict(
        bar: 'B10 cost arm (on-ESP32-S3 cycles/RAM): QUEUED-BLOCKED — '
            'firmware work, no firmware path in this build',
        passed: false,
        notApplicable: true,
        detail: 'Accuracy arm only in this build; the row is PARTIAL, '
            'never PASS on accuracy alone.',
      ),
    ],
  );
}
