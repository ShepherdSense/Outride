/// B12 + B-W1–B-W4 CSI presence benches (one file, four harness
/// entry points — they share the CSI loader and the ambient-baseline
/// machinery in bench_csi.dart).
///
/// Sources: B12 — Chaudhari, Preprints.org 202601.2378/v1, Jan 2026
/// (100-packet windows, ~100 Hz); B-W1–B-W4 — dual-WiFi note §6.
/// Phase-based arms carry the R6 caveat (expected weak on S3 SISO);
/// fingerprinting stays REJECTED — detection scoring only.
///
/// Session labels come from the `<session>.meta.json` sidecar
/// (`type`: present/absent/moving/still/fan-on). A session without a
/// sidecar is unscored, listed with the reason — never assumed.
library;

import 'dart:io';
import 'dart:math' as math;

import 'bench_csi.dart';
import 'fusion_bench_harness.dart';

/// Loaded CSI sessions, partitioned for scoring.
class _CsiLoad {
  _CsiLoad(this.labeled, this.rejected);

  /// Sessions with a meta type label and enough packets.
  final List<CsiSession> labeled;

  /// File name -> reason (parse failures, too-short, unlabeled).
  final Map<String, String> rejected;
}

_CsiLoad _load(Directory dir, {int minPackets = 10}) {
  final load = loadCsiSessions(dir);
  final rejected = Map<String, String>.of(load.rejected);
  final labeled = <CsiSession>[];
  for (final s in load.sessions) {
    if (s.packets.length < minPackets) {
      rejected[s.name] =
          'too short: ${s.packets.length} packets — need at least '
          '$minPackets';
    } else if (s.type == null) {
      rejected[s.name] = 'unscored: missing <session>.meta.json sidecar '
          '(no session type label)';
    } else {
      labeled.add(s);
    }
  }
  return _CsiLoad(labeled, rejected);
}

BenchOutcome _skipped(_CsiLoad load) => BenchOutcome(
      skipped: true,
      skipReason: kBenchPending,
      rejected: load.rejected,
    );

bool _isPositive(CsiSession s) =>
    s.type == 'present' || s.type == 'moving' || s.type == 'still';

// --- B12: CSI features vs RSS-only -------------------------------------

/// 100-packet windows (paper), features [amp mean, amp var,
/// detrended phase var] for the CSI arm, [amp mean] only for the
/// RSS-only arm. Leave-one-session-out k-NN (k=3) on both.
BenchOutcome runCsiFeatureBench(Directory sessionsDir) {
  const windowPackets = 100;
  final load = _load(sessionsDir, minPackets: windowPackets);
  if (load.labeled.length < 2) return _skipped(load);

  double accuracy(bool useCsi) {
    var correct = 0, total = 0;
    for (var held = 0; held < load.labeled.length; held++) {
      final train = <(List<double>, String)>[];
      for (var i = 0; i < load.labeled.length; i++) {
        if (i == held) continue;
        train.addAll(_b12Windows(load.labeled[i], useCsi));
      }
      final test = _b12Windows(load.labeled[held], useCsi);
      if (train.isEmpty || test.isEmpty) continue;
      // Standardize like B7: the features [amp mean, amp var,
      // detrended phase var] span wildly different scales, and an
      // unstandardized Euclidean k-NN is dominated by the largest.
      final dims = train.first.$1.length;
      final trainMean = [
        for (var d = 0; d < dims; d++)
          train.map((t) => t.$1[d]).fold(0.0, (a, b) => a + b) /
              train.length,
      ];
      final trainStd = [
        for (var d = 0; d < dims; d++)
          math.sqrt(train
                  .map((t) =>
                      (t.$1[d] - trainMean[d]) * (t.$1[d] - trainMean[d]))
                  .fold(0.0, (a, b) => a + b) /
              train.length),
      ];
      for (final (features, _) in test) {
        final pred = _knn3(features, train, trainMean, trainStd);
        total++;
        if ((pred == 'present') == _isPositive(load.labeled[held])) {
          correct++;
        }
      }
    }
    return total == 0 ? double.nan : correct / total;
  }

  final csiAcc = accuracy(true);
  final rssAcc = accuracy(false);
  return BenchOutcome(
    skipped: false,
    sessionsRun: [for (final s in load.labeled) s.name],
    rejected: load.rejected,
    verdicts: [
      BenchVerdict(
        bar: 'B12: CSI features (amp mean/var + detrended phase, '
            '100-packet windows) vs RSS-only, scored on detection',
        passed: csiAcc.isFinite &&
            rssAcc.isFinite &&
            csiAcc >= rssAcc,
        detail: 'CSI accuracy ${(csiAcc * 100).toStringAsFixed(1)}% vs '
            'RSS-only ${(rssAcc * 100).toStringAsFixed(1)}% '
            '(${load.labeled.length} sessions, leave-one-session-out)',
      ),
    ],
  );
}

List<(List<double>, String)> _b12Windows(CsiSession s, bool useCsi) {
  const windowPackets = 100;
  final out = <(List<double>, String)>[];
  final packets = s.packets;
  for (var i = 0; i + windowPackets <= packets.length;
      i += windowPackets) {
    final window = packets.sublist(i, i + windowPackets);
    final means = [for (final p in window) p.meanAmp];
    final (m, v) = meanVar(means);
    final label = _isPositive(s) ? 'present' : 'absent';
    out.add((
      useCsi ? [m, v, detrendedPhaseVar(window)] : [m],
      label,
    ));
  }
  return out;
}

/// k-NN (k=3) with train-set standardization (see [runCsiFeatureBench]).
String _knn3(
  List<double> x,
  List<(List<double>, String)> train,
  List<double> trainMean,
  List<double> trainStd,
) {
  final scored = <(double, String)>[];
  for (final (features, label) in train) {
    var d2 = 0.0;
    for (var i = 0; i < x.length; i++) {
      final std = trainStd[i] > 0 ? trainStd[i] : 1.0;
      final dx = (x[i] - trainMean[i]) / std -
          (features[i] - trainMean[i]) / std;
      d2 += dx * dx;
    }
    scored.add((d2, label));
  }
  scored.sort((a, b) => a.$1.compareTo(b.$1));
  final votes = <String, int>{};
  for (var i = 0; i < math.min(3, scored.length); i++) {
    votes[scored[i].$2] = (votes[scored[i].$2] ?? 0) + 1;
  }
  return votes.entries
      .reduce((a, b) => a.value >= b.value ? a : b)
      .key;
}

// --- B-W1: split-node ambient-link presence ----------------------------

/// Windowed amplitude disturbance vs the 60 s ambient baseline:
/// a window detects when its z-score ≥ 3. Detection rate over
/// present/moving sessions, FAR over absent sessions.
BenchOutcome runSplitNodePresenceBench(Directory sessionsDir) {
  const windowS = 1.0;
  const zThr = 3.0;
  final load = _load(sessionsDir);
  final positives = load.labeled.where(_isPositive).toList();
  final negatives =
      load.labeled.where((s) => s.type == 'absent').toList();
  if (positives.isEmpty || negatives.isEmpty) return _skipped(load);

  var detWindows = 0, detTotal = 0;
  for (final s in positives) {
    final z = disturbanceZ(s, windowS, ambientBaseline(s));
    detTotal += z.length;
    detWindows += z.where((v) => v >= zThr).length;
  }
  var farWindows = 0, farTotal = 0;
  for (final s in negatives) {
    final z = disturbanceZ(s, windowS, ambientBaseline(s));
    farTotal += z.length;
    farWindows += z.where((v) => v >= zThr).length;
  }
  final detection = detTotal == 0 ? double.nan : detWindows / detTotal;
  final far = farTotal == 0 ? double.nan : farWindows / farTotal;
  return BenchOutcome(
    skipped: false,
    sessionsRun: [for (final s in load.labeled) s.name],
    rejected: load.rejected,
    verdicts: [
      BenchVerdict(
        bar: 'B-W1: detection ≥90% on moving-person crossings of a 3 m '
            'link',
        passed: detection.isFinite && detection >= 0.90,
        detail: 'detection ${(detection * 100).toStringAsFixed(1)}% '
            '($detWindows/$detTotal 1 s windows, z ≥ 3 vs 60 s ambient)',
      ),
      BenchVerdict(
        bar: 'B-W1: FAR ≤5% on empty-room sessions',
        passed: far.isFinite && far <= 0.05,
        detail: 'FAR ${(far * 100).toStringAsFixed(1)}% '
            '($farWindows/$farTotal windows)',
      ),
    ],
  );
}

// --- B-W2: single-board motion confirm, fenced -------------------------

/// Walking person at 1 m: window amplitude variance swing ≥1%
/// above baseline variance; drift over 60 s <1% on absent sessions.
/// Sessions carry no person-distance label, so the 1 m bar is
/// applied to all moving sessions and the 2 m/3 m report-only split
/// is unavailable — the result says so.
BenchOutcome runSingleBoardMotionBench(Directory sessionsDir) {
  const windowS = 1.0;
  final load = _load(sessionsDir);
  final positives = load.labeled.where(_isPositive).toList();
  final negatives =
      load.labeled.where((s) => s.type == 'absent').toList();
  if (positives.isEmpty || negatives.isEmpty) return _skipped(load);

  var swings = <double>[];
  for (final s in positives) {
    final base = ambientBaseline(s);
    if (!base.valid) continue;
    for (final (_, v) in ampMeanVarWindows(s.packets, windowS)) {
      swings.add((v - base.std * base.std) / (base.std * base.std));
    }
  }
  swings.sort();
  final medianSwing = swings.isEmpty
      ? double.nan
      : swings[swings.length ~/ 2];
  // Drift: absent-session baseline variance, first half vs last half.
  var drifts = <double>[];
  for (final s in negatives) {
    final packets = s.packets;
    if (packets.length < 4) continue;
    final half = packets.length ~/ 2;
    final (_, v1) = meanVar(
        [for (final p in packets.sublist(0, half)) p.meanAmp]);
    final (_, v2) = meanVar(
        [for (final p in packets.sublist(half)) p.meanAmp]);
    if (v1 > 0) drifts.add((v2 - v1).abs() / v1);
  }
  final maxDrift = drifts.isEmpty
      ? double.nan
      : drifts.reduce(math.max);
  return BenchOutcome(
    skipped: false,
    sessionsRun: [for (final s in load.labeled) s.name],
    rejected: load.rejected,
    verdicts: [
      BenchVerdict(
        bar: 'B-W2: walking person at 1 m — swing ≥1% above baseline '
            'variance (median window swing)',
        passed: medianSwing.isFinite && medianSwing >= 0.01,
        detail: 'median swing ${(medianSwing * 100).toStringAsFixed(2)}% '
            'over baseline variance (${swings.length} windows; sessions '
            'carry no person-distance label, so the 2 m/3 m report-only '
            'split is unavailable)',
      ),
      BenchVerdict(
        bar: 'B-W2: drift over 60 s <1% on absent sessions',
        passed: maxDrift.isFinite && maxDrift < 0.01,
        detail: 'max drift ${(maxDrift * 100).toStringAsFixed(2)}% '
            '(${drifts.length} absent session(s))',
      ),
    ],
  );
}

// --- B-W3: RuView phase-variance presence fallback ----------------------

/// Phase variance per 5 s window vs the ambient windows' phase
/// variance: presence when phaseVar > 2× ambient phaseVar.
BenchOutcome runPhaseVarianceBench(Directory sessionsDir) {
  const windowS = 5.0;
  final load = _load(sessionsDir);
  final positives = load.labeled.where(_isPositive).toList();
  final negatives =
      load.labeled.where((s) => s.type == 'absent').toList();
  if (positives.isEmpty || negatives.isEmpty) return _skipped(load);

  double detectionRate(List<CsiSession> sessions) {
    var hits = 0, total = 0;
    for (final s in sessions) {
      final windows = windowPackets(s.packets, windowS);
      if (windows.length < 2) continue;
      // Ambient phase variance from the leading calibration windows.
      final calibS = s.ambientCalibrationS > 0
          ? s.ambientCalibrationS
          : 60.0;
      // Non-finite phase variances are EXCLUDED from the ambient
      // mean — never silently replaced with 0.0 (which would drag
      // the threshold down). A window whose own phase variance is
      // non-finite is skipped below, not counted either way.
      final calib = [
        for (final w in windows)
          if (w.start
                  .difference(s.packets.first.t)
                  .inMicroseconds /
              1e6 <
              calibS)
            detrendedPhaseVar(w.packets),
      ].where((v) => v.isFinite).toList();
      final (ambMean, _) = meanVar(calib);
      final thr = ambMean * 2;
      for (final w in windows) {
        final v = detrendedPhaseVar(w.packets);
        if (!v.isFinite) continue;
        total++;
        if (v > thr) hits++;
      }
    }
    return total == 0 ? double.nan : hits / total;
  }

  final detection = detectionRate(positives);
  final far = detectionRate(negatives);
  return BenchOutcome(
    skipped: false,
    sessionsRun: [for (final s in load.labeled) s.name],
    rejected: load.rejected,
    verdicts: [
      BenchVerdict(
        bar: 'B-W3/RuView: presence/absence ≥90%',
        passed: detection.isFinite && detection >= 0.90,
        detail: 'presence detection ${(detection * 100).toStringAsFixed(1)}% '
            '(phase variance > 2× ambient, 5 s windows)',
      ),
      BenchVerdict(
        bar: 'B-W3/RuView: FAR ≤5%',
        passed: far.isFinite && far <= 0.05,
        detail: 'FAR ${(far * 100).toStringAsFixed(1)}% on absent sessions',
      ),
    ],
  );
}

// --- B-W4: split-node breathing attempt ---------------------------------

/// FFT in 0.1–0.5 Hz over 60 s windows of the mean-amplitude series
/// (naive DFT, 0.005 Hz steps). A window claims breathing when its
/// peak power exceeds 3× the median spectral power. Pass when the
/// claimed rate is within ±2 breaths/min of the counted reference
/// (meta `breathing_bpm_ref`) in ≥80% of 60 s windows at 1 m, with
/// FAR ≤10% on empty-room + fan-on sessions.
BenchOutcome runBreathingBench(Directory sessionsDir) {
  const windowS = 60.0;
  final load = _load(sessionsDir, minPackets: 30);
  final still = load.labeled.where((s) => s.type == 'still').toList();
  final controls = load.labeled
      .where((s) => s.type == 'absent' || s.type == 'fan-on')
      .toList();
  if (still.isEmpty || controls.isEmpty) return _skipped(load);

  var withinTol = 0, claimed = 0, total = 0;
  var missingRef = false;
  for (final s in still) {
    final ref = s.breathingBpmRef;
    if (ref == null) {
      missingRef = true;
      continue;
    }
    for (final (bpm, claims) in _breathingWindows(s, windowS)) {
      total++;
      if (!claims) continue;
      claimed++;
      if ((bpm - ref).abs() <= 2.0) withinTol++;
    }
  }
  var farClaims = 0, farTotal = 0;
  for (final s in controls) {
    for (final (_, claims) in _breathingWindows(s, windowS)) {
      farTotal++;
      if (claims) farClaims++;
    }
  }
  // Hit rate is over ALL 60 s windows (the pass bar says "≥80% of
  // 60 s windows"), NOT over windows that claimed breathing — a
  // session where 1 of 10 windows claims (and is right) scores
  // 1/10, not 100%. Claimed/total is reported separately.
  final hitRate = total == 0 ? double.nan : withinTol / total;
  final far = farTotal == 0 ? double.nan : farClaims / farTotal;
  return BenchOutcome(
    skipped: false,
    sessionsRun: [for (final s in load.labeled) s.name],
    rejected: load.rejected,
    verdicts: [
      BenchVerdict(
        bar: 'B-W4: breathing within ±2 breaths/min of counted reference '
            'at 1 m, ≥80% of 60 s windows',
        notApplicable: missingRef && total == 0,
        passed: hitRate.isFinite && hitRate >= 0.80,
        detail: missingRef
            ? 'no counted breathing reference in meta sidecar '
                '(breathing_bpm_ref) for some still session(s)'
            : 'within tolerance ${(hitRate * 100).toStringAsFixed(1)}% '
                '($withinTol/$total windows; $claimed claimed)',
      ),
      BenchVerdict(
        bar: 'B-W4: FAR ≤10% empty-room + fan-on',
        passed: far.isFinite && far <= 0.10,
        detail: 'FAR ${(far * 100).toStringAsFixed(1)}% '
            '($farClaims/$farTotal windows; fan-on negative control '
            'included)',
      ),
    ],
  );
}

/// (breaths/min at spectral peak, claimsBreathing) per 60 s window.
List<(double, bool)> _breathingWindows(CsiSession s, double windowS) {
  final out = <(double, bool)>[];
  for (final w in windowPackets(s.packets, windowS)) {
    if (w.packets.length < 30) continue;
    final t0 = w.packets.first.t;
    final xs = <double>[];
    final ts = <double>[];
    for (final p in w.packets) {
      xs.add(p.meanAmp);
      ts.add(p.t.difference(t0).inMicroseconds / 1e6);
    }
    final (mean, _) = meanVar(xs);
    final centered = [for (final x in xs) x - mean];
    // Naive DFT over 0.1–0.5 Hz.
    var bestF = 0.0, bestP = 0.0;
    final powers = <double>[];
    for (var f = 0.1; f <= 0.5001; f += 0.005) {
      var re = 0.0, im = 0.0;
      for (var i = 0; i < centered.length; i++) {
        final ph = 2 * math.pi * f * ts[i];
        re += centered[i] * math.cos(ph);
        im -= centered[i] * math.sin(ph);
      }
      final p = re * re + im * im;
      powers.add(p);
      if (p > bestP) {
        bestP = p;
        bestF = f;
      }
    }
    powers.sort();
    final medianP =
        powers.isEmpty ? 0.0 : powers[powers.length ~/ 2];
    out.add((bestF * 60.0, medianP > 0 && bestP > 3 * medianP));
  }
  return out;
}
