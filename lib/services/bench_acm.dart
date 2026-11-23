/// B11 ACM path-splitting bench (LBP-based; Tikhonov deferred).
///
/// Source: Abdullah et al., "Radio Tomography Imaging using Adjacent
/// Criterion Method to determine the Localization Error," ECTI Trans.
/// EEC 22(2), June 2024 (READ IN FULL). Hardware is ESP-class (8
/// NodeMCU ESP8266 nodes, 28 links, 2×2 m). The paper's MSE figures
/// are internally inconsistent — never used.
///
/// Method: linear back-projection (LBP) reconstructor built in this
/// harness — each disturbed link votes dip weight onto the grid cells
/// along its path (midpoint Gaussian splat, σ=1.5 m), the peak cell
/// is the localisation. ACM split: the link set is split into two
/// paths (A/B) by link orientation (links whose midpoint angle falls
/// in the first half of the circle vs the second), each half is
/// reconstructed separately, and the two images are averaged. The
/// baseline is the UNSPLIT LBP reconstructor from the same harness
/// (R7: stated explicitly — no live Outride reconstructor exists).
/// Image quality is scored by MSSIM-equivalent: normalized
/// cross-correlation between the reconstructed image and a truth
/// image (Gaussian blob at the truth position, same σ).
///
/// A Tikhonov arm needs a Dart Tikhonov solver that does not exist;
/// do not silently substitute the grid-search tracker as "the
/// reconstructor".
///
/// Pass bar: ≥10% MSSIM-equivalent improvement AND no worse
/// localisation (m) vs baseline.
library;

import 'dart:math' as math;

import 'bench_csi.dart' show kBenchPending;
import 'bench_run.dart';
import 'fusion_bench_harness.dart';

/// Reconstruction grid step, metres.
const double kB11GridStepM = 1.0;

/// Splat sigma, metres.
const double kB11SplatSigmaM = 1.5;

/// Field margin beyond node positions, metres.
const double kB11MarginM = 5.0;

/// LBP image: grid votes from disturbed links at one poll.
List<List<double>> _lbpImage(
  BenchSession session,
  DateTime t,
  BenchConfig config,
  List<String>? onlyLinks,
  int nx,
  int ny,
  double minX,
  double minY,
) {
  final grid = List.generate(nx, (_) => List.filled(ny, 0.0));
  for (final r in session.rowsAt(t)) {
    final d = r.dipDb ?? 0;
    if (d <= config.dipThresholdDb) continue;
    if (onlyLinks != null && !onlyLinks.contains(r.linkKey)) continue;
    final a = config.nodes[r.fromNode];
    final b = config.nodes[r.toNode];
    if (a == null || b == null) continue;
    final mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2;
    final gx0 = ((mx - minX) / kB11GridStepM).round();
    final gy0 = ((my - minY) / kB11GridStepM).round();
    const radius = 3;
    for (var dx = -radius; dx <= radius; dx++) {
      for (var dy = -radius; dy <= radius; dy++) {
        final gx = gx0 + dx, gy = gy0 + dy;
        if (gx < 0 || gy < 0 || gx >= nx || gy >= ny) continue;
        final dist2 = dx * dx + dy * dy;
        grid[gx][gy] += d *
            math.exp(
                -dist2 / (2 * kB11SplatSigmaM * kB11SplatSigmaM));
      }
    }
  }
  return grid;
}

/// Truth image: Gaussian blob at the truth position.
List<List<double>> _truthImage(
  (double, double) truth,
  int nx,
  int ny,
  double minX,
  double minY,
) {
  final grid = List.generate(nx, (_) => List.filled(ny, 0.0));
  final gx0 = ((truth.$1 - minX) / kB11GridStepM).round();
  final gy0 = ((truth.$2 - minY) / kB11GridStepM).round();
  const radius = 4;
  for (var dx = -radius; dx <= radius; dx++) {
    for (var dy = -radius; dy <= radius; dy++) {
      final gx = gx0 + dx, gy = gy0 + dy;
      if (gx < 0 || gy < 0 || gx >= nx || gy >= ny) continue;
      final dist2 = dx * dx + dy * dy;
      grid[gx][gy] = math.exp(
          -dist2 / (2 * kB11SplatSigmaM * kB11SplatSigmaM));
    }
  }
  return grid;
}

/// MSSIM-equivalent: normalized cross-correlation of two images
/// (0..1 for non-negative images; 1 = identical up to scale).
double _ncc(List<List<double>> a, List<List<double>> b) {
  var num = 0.0, da = 0.0, db = 0.0;
  for (var i = 0; i < a.length; i++) {
    for (var j = 0; j < a[i].length; j++) {
      num += a[i][j] * b[i][j];
      da += a[i][j] * a[i][j];
      db += b[i][j] * b[i][j];
    }
  }
  if (da <= 0 || db <= 0) return double.nan;
  return num / math.sqrt(da * db);
}

(double, double) _peak(List<List<double>> grid, double minX, double minY) {
  var bx = 0, by = 0, bv = -1.0;
  for (var i = 0; i < grid.length; i++) {
    for (var j = 0; j < grid[i].length; j++) {
      if (grid[i][j] > bv) {
        bv = grid[i][j];
        bx = i;
        by = j;
      }
    }
  }
  return (minX + bx * kB11GridStepM, minY + by * kB11GridStepM);
}

/// Run the B11 bench over the RF-track sessions under [config].
BenchOutcome runAcmBench(BenchConfig config) {
  final load = loadRfSessions(config.sessionsDir);
  if (load.sessions.isEmpty) return skippedOutcome(load.rejected);

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
  final minX = xs.reduce(math.min) - kB11MarginM;
  final maxX = xs.reduce(math.max) + kB11MarginM;
  final minY = ys.reduce(math.min) - kB11MarginM;
  final maxY = ys.reduce(math.max) + kB11MarginM;
  final nx = ((maxX - minX) / kB11GridStepM).ceil() + 1;
  final ny = ((maxY - minY) / kB11GridStepM).ceil() + 1;

  final baseNcc = <double>[];
  final acmNcc = <double>[];
  final baseErr = <double>[];
  final acmErr = <double>[];
  for (final session in load.sessions) {
    final polls = replaySession(session, config);
    for (final p in polls) {
      if (p.truth == null || p.truthIds.length != 1) continue;
      final truth = p.truth!;
      final truthImg = _truthImage(truth, nx, ny, minX, minY);
      // Baseline: unsplit LBP.
      final base = _lbpImage(
          session, p.t, config, null, nx, ny, minX, minY);
      // ACM split: links by midpoint angle, two paths, averaged.
      final links = <String>{};
      for (final r in session.rowsAt(p.t)) {
        if ((r.dipDb ?? 0) > config.dipThresholdDb) {
          links.add(r.linkKey);
        }
      }
      final pathA = <String>[], pathB = <String>[];
      for (final key in links) {
        // Link keys are `a>b` in capture CSVs and `a → b` from
        // LinkSample.linkKey (the recorder) — accept both.
        final parts = key.contains('>')
            ? key.split('>')
            : key.split('→');
        if (parts.length != 2) {
          pathA.add(key);
          continue;
        }
        final a = config.nodes[parts[0].trim()];
        final b = config.nodes[parts[1].trim()];
        if (a == null || b == null) {
          pathA.add(key);
          continue;
        }
        final angle = math.atan2(
            (a.y + b.y) / 2, (a.x + b.x) / 2);
        (angle >= 0 ? pathA : pathB).add(key);
      }
      final imgA = _lbpImage(
          session, p.t, config, pathA, nx, ny, minX, minY);
      final imgB = _lbpImage(
          session, p.t, config, pathB, nx, ny, minX, minY);
      final acm = List.generate(
          nx,
          (i) => List.generate(
              ny, (j) => (imgA[i][j] + imgB[i][j]) / 2));
      final bNcc = _ncc(base, truthImg);
      final aNcc = _ncc(acm, truthImg);
      if (!bNcc.isFinite || !aNcc.isFinite) continue;
      baseNcc.add(bNcc);
      acmNcc.add(aNcc);
      final (bx, by) = _peak(base, minX, minY);
      final (ax, ay) = _peak(acm, minX, minY);
      baseErr.add(math.sqrt(
          (bx - truth.$1) * (bx - truth.$1) +
              (by - truth.$2) * (by - truth.$2)));
      acmErr.add(math.sqrt(
          (ax - truth.$1) * (ax - truth.$1) +
              (ay - truth.$2) * (ay - truth.$2)));
    }
  }

  double mean(List<double> v) =>
      v.isEmpty ? double.nan : v.fold(0.0, (a, b) => a + b) / v.length;
  final baseM = mean(baseNcc), acmM = mean(acmNcc);
  final baseE = mean(baseErr), acmE = mean(acmErr);
  final improvement =
      baseM.isFinite && baseM > 0 ? (acmM - baseM) / baseM : double.nan;
  return BenchOutcome(
    skipped: false,
    sessionsRun: sessionNames(load),
    rejected: load.rejected,
    verdicts: [
      BenchVerdict(
        bar: 'B11: ≥10% MSSIM-equivalent improvement vs baseline '
            '(baseline = unsplit LBP reconstructor built in this harness)',
        passed: improvement.isFinite && improvement >= 0.10,
        detail: 'MSSIM-equivalent (NCC) baseline '
            '${baseM.toStringAsFixed(3)} vs ACM ${acmM.toStringAsFixed(3)} '
            '(${(improvement * 100).toStringAsFixed(1)}% over '
            '${baseNcc.length} polls)',
      ),
      BenchVerdict(
        bar: 'B11: no worse localisation (m) vs baseline',
        passed: acmE.isFinite && baseE.isFinite && acmE <= baseE,
        detail: 'localisation error baseline ${baseE.toStringAsFixed(3)} m '
            'vs ACM ${acmE.toStringAsFixed(3)} m',
      ),
    ],
  );
}
