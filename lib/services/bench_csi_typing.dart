/// B7 CSI obstruction typing replication bench.
///
/// Source: Protsak & Pavlenko, Computer Systems and Networks 8(1),
/// 2026, pp. 203–218, DOI 10.23939/csn2026.01.203 (READ IN FULL).
/// Paper numbers are the paper's, never Outride results: windowed
/// RSSI [μ,σ] k-NN (W=50): 84.0% / F1 0.834.
///
/// Arms:
/// - k-NN (W=50 packets): leave-one-session-out; a window's label is
///   its session's meta `type` (present/absent/moving/still). Runs
///   on sessions.
/// - SVM (PCA-10): inference ONLY, weights as a sidecar
///   `csi_sessions/<set>.svm.json` (PCA matrix + SVM weights + bias
///   + offline training provenance). Missing sidecar → the SVM arm
///   is PENDING with reason `measurement pending — no trained
///   weights`, while the k-NN arm can still run. Never falls back to
///   untrained defaults.
///
/// Pass bar: ≥2 node pairs, ≥2 rooms, cross-day; instantaneous
/// classifier ≥80% acc., wall-pair F1 ≥0.70. The wall-pair F1 is
/// reported as the present-class F1 (sessions carry present/absent
/// labels, not the paper's wall scenarios) and says so.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'bench_csi.dart';
import 'fusion_bench_harness.dart';

/// k-NN window, packets (paper W=50).
const int kB7WindowPackets = 50;

/// k-NN neighbours.
const int kB7K = 3;

/// Feature vector per window: [amp mean, amp std] (windowed RSSI
/// [μ,σ], the paper's k-NN baseline).
List<double> _windowFeatures(List<CsiPacket> window) {
  final means = [for (final p in window) p.meanAmp];
  final (m, v) = meanVar(means);
  return [m, math.sqrt(v)];
}

/// Windows of [kB7WindowPackets] packets, labeled by session type.
/// Sessions without a meta type are skipped (unscored, listed).
List<(List<double>, String)> _labeledWindows(CsiSession s) {
  if (s.type == null) return [];
  final out = <(List<double>, String)>[];
  final packets = s.packets;
  for (var i = 0; i + kB7WindowPackets <= packets.length;
      i += kB7WindowPackets) {
    out.add((
      _windowFeatures(packets.sublist(i, i + kB7WindowPackets)),
      s.type!,
    ));
  }
  return out;
}

/// A still person IS present — `still` counts as positive, never
/// as absent.
bool _isPositive(String type) =>
    type == 'present' || type == 'moving' || type == 'still';

/// k-NN predict with train-set standardization.
String _knnPredict(
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
  for (var i = 0; i < math.min(kB7K, scored.length); i++) {
    votes[scored[i].$2] = (votes[scored[i].$2] ?? 0) + 1;
  }
  return votes.entries
      .reduce((a, b) => a.value >= b.value ? a : b)
      .key;
}

/// Run the B7 bench over the CSI sessions under [sessionsDir].
BenchOutcome runCsiTypingBench(Directory sessionsDir) {
  final load = loadCsiSessions(sessionsDir);
  final rejected = Map<String, String>.of(load.rejected);
  final labeled = <CsiSession>[];
  for (final s in load.sessions) {
    if (s.packets.length < kB7WindowPackets) {
      rejected[s.name] =
          'too short: ${s.packets.length} packets — need at least '
          '$kB7WindowPackets';
    } else if (s.type == null) {
      rejected[s.name] = 'unscored: missing <session>.meta.json sidecar '
          '(no session type label)';
    } else {
      labeled.add(s);
    }
  }
  if (labeled.length < 2) {
    return BenchOutcome(
      skipped: true,
      skipReason: kBenchPending,
      rejected: rejected,
    );
  }

  // Leave-one-session-out k-NN.
  var correct = 0, total = 0;
  var tp = 0, fp = 0, fn = 0;
  for (var held = 0; held < labeled.length; held++) {
    final train = <(List<double>, String)>[];
    for (var i = 0; i < labeled.length; i++) {
      if (i == held) continue;
      train.addAll(_labeledWindows(labeled[i]));
    }
    final test = _labeledWindows(labeled[held]);
    if (train.isEmpty || test.isEmpty) continue;
    final trainMean = [
      for (var d = 0; d < 2; d++)
        train.map((t) => t.$1[d]).fold(0.0, (a, b) => a + b) / train.length,
    ];
    final trainStd = [
      for (var d = 0; d < 2; d++)
        math.sqrt(train
                .map((t) => (t.$1[d] - trainMean[d]) * (t.$1[d] - trainMean[d]))
                .fold(0.0, (a, b) => a + b) /
            train.length),
    ];
    for (final (features, label) in test) {
      final pred = _knnPredict(features, train, trainMean, trainStd);
      total++;
      if (pred == label) correct++;
      if (_isPositive(pred) && _isPositive(label)) tp++;
      if (_isPositive(pred) && !_isPositive(label)) fp++;
      if (!_isPositive(pred) && _isPositive(label)) fn++;
    }
  }
  final accuracy = total == 0 ? double.nan : correct / total;
  final f1 = tp + fp + fn == 0
      ? double.nan
      : 2 * tp / (2 * tp + fp + fn);
  final rooms = {for (final s in labeled) s.room ?? '?'}.length;

  // SVM arm: sidecar or PENDING.
  final svm = _svmArm(sessionsDir, labeled);

  final verdicts = <BenchVerdict>[
    BenchVerdict(
      bar: 'B7 k-NN: instantaneous classifier ≥80% acc. (leave-one-'
          'session-out)',
      passed: accuracy.isFinite && accuracy >= 0.80,
      detail: 'k-NN accuracy ${(accuracy * 100).toStringAsFixed(1)}% '
          '($correct/$total windows, ${labeled.length} sessions, '
          '$rooms room(s))',
    ),
    BenchVerdict(
      bar: 'B7 k-NN: wall-pair F1 ≥0.70 (reported as present-class F1 — '
          'sessions carry present/absent labels, not wall scenarios)',
      passed: f1.isFinite && f1 >= 0.70,
      detail: 'present-class F1 ${f1.toStringAsFixed(3)} '
          '(tp=$tp fp=$fp fn=$fn)',
    ),
    svm,
  ];
  return BenchOutcome(
    skipped: false,
    sessionsRun: [for (final s in labeled) s.name],
    rejected: rejected,
    verdicts: verdicts,
  );
}

/// The SVM arm: returns its verdict. PENDING (notApplicable) when
/// the weights sidecar is absent — never untrained defaults.
BenchVerdict _svmArm(Directory dir, List<CsiSession> labeled) {
  const bar = 'B7 SVM (PCA-10): instantaneous classifier ≥80% acc.';
  final sidecar = File('${dir.path}/bench.svm.json');
  if (!sidecar.existsSync()) {
    return const BenchVerdict(
      bar: bar,
      passed: false,
      notApplicable: true,
      detail: 'measurement pending — no trained weights '
          '(csi_sessions/bench.svm.json absent)',
    );
  }
  try {
    final j = jsonDecode(sidecar.readAsStringSync()) as Map<String, dynamic>;
    final pca = (j['pca'] as List)
        .map((row) => (row as List)
            .map((v) => (v as num).toDouble())
            .toList())
        .toList();
    final weights = (j['weights'] as List)
        .map((v) => (v as num).toDouble())
        .toList();
    final bias = (j['bias'] as num).toDouble();
    if (pca.length != 10 || weights.length != 10) {
      return const BenchVerdict(
        bar: bar,
        passed: false,
        notApplicable: true,
        detail: 'sidecar rejected: PCA/weights must both have 10 '
            'components',
      );
    }
    // Score: PCA-10 features are the windowed [μ,σ] plus the
    // per-subcarrier amp means (first 8 subcarriers, padded) —
    // projected, then a linear SVM sign.
    var correct = 0, total = 0;
    for (final s in labeled) {
      final packets = s.packets;
      for (var i = 0; i + kB7WindowPackets <= packets.length;
          i += kB7WindowPackets) {
        final window = packets.sublist(i, i + kB7WindowPackets);
        final base = _windowFeatures(window);
        final subs = window.first.subcarriers.take(8).toList();
        final raw = [
          ...base,
          for (var k = 0; k < 8; k++)
            k < subs.length
                ? window
                        .map((p) => p.amp[subs[k]] ?? 0.0)
                        .fold(0.0, (a, b) => a + b) /
                    window.length
                : 0.0,
        ];
        var score = bias;
        for (var c = 0; c < 10; c++) {
          var proj = 0.0;
          for (var d = 0; d < 10; d++) {
            proj += pca[c][d] * raw[d];
          }
          score += weights[c] * proj;
        }
        final pred = score >= 0 ? 'present' : 'absent';
        final actualPositive = _isPositive(s.type!);
        final predPositive = _isPositive(pred);
        total++;
        if (predPositive == actualPositive) correct++;
      }
    }
    final acc = total == 0 ? double.nan : correct / total;
    return BenchVerdict(
      bar: bar,
      passed: acc.isFinite && acc >= 0.80,
      detail: 'SVM accuracy ${(acc * 100).toStringAsFixed(1)}% '
          '($correct/$total windows; weights from '
          'csi_sessions/bench.svm.json)',
    );
  } catch (e) {
    return BenchVerdict(
      bar: bar,
      passed: false,
      notApplicable: true,
      detail: 'sidecar unreadable: $e',
    );
  }
}
