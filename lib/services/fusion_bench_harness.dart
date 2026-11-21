/// B1 bench harness — session loading, replay, scoring, verdicts.
///
/// EXPERIMENTAL — bench-only library, never wired into the live
/// tracker or the app UI. See docs/fusion_bench_b1_spec.md.
///
/// DATA RULE (standing, enforced here): the bench measurement runs
/// ONLY on recorded Outride track sessions. [runFusionBench] scans
/// [BenchConfig.sessionsDir]; when the directory is missing, empty,
/// or holds no valid session, it returns a SKIPPED outcome with
/// reason "measurement pending — no recorded data" and scores
/// nothing. It never runs on synthetic data — the Stone Soup
/// stand-ins under tools/stone_soup_bench/ are explicitly NOT
/// scanned, and no synthetic session is generated here.
///
/// SESSION FORMAT (the Stone Soup session format, already established
/// in-repo under tools/stone_soup_bench/sample_run.csv):
///   t_iso,link_key,from_node,to_node,snr_db,dip_db,truth_x,truth_y,truth_id
/// dip_db and the truth_* columns are REQUIRED for a bench session:
/// a file without them is rejected (listed in [SessionLoad.rejected])
/// because the bench cannot score fusion honesty without ground
/// truth. Node positions come from [BenchConfig.nodes] (field-local
/// meters, same frame as the truth columns); a `<session>.nodes.json`
/// sidecar is the convention for recording them with the session.
///
/// BENCH-SIDE LOCAL ESTIMATOR: the app tracker (tracker.dart) is a
/// covariance-free grid search, so the bench builds its own local
/// per-node estimates from the recorded link samples — dip-weighted
/// centroid of disturbed-link midpoints, covariance from the tracker
/// coarse-grid step (sigma0 = 2.5 m) scaled by link count, plus
/// motion-growth with time since the last poll — smoothed with a
/// constant-velocity prediction. All fusion/association arms share
/// the SAME local estimates, so estimator bias cancels in the
/// RELATIVE comparisons the pass bars state. The estimator is a
/// bench instrument, not the live tracker; a Kalman upgrade is a
/// documented future refinement, not silently substituted.
library;

import 'dart:io';
import 'dart:math' as math;

import '../models/tracking.dart';
import 'fusion_bench.dart';
import 'fusion_bench_association.dart';

/// Where recorded sessions live. Sessions copied off the device land
/// in <repo>/bench_sessions/ (one CSV per session). The directory
/// does not exist yet — that is the normal state until Draco copies
/// the Nov 2–4 capture files out of the device.
const String defaultSessionsDirName = 'bench_sessions';

/// One recorded link sample in a bench session.
class BenchSessionRow {
  const BenchSessionRow({
    required this.t,
    required this.linkKey,
    required this.fromNode,
    required this.toNode,
    required this.snrDb,
    required this.dipDb,
    required this.truthX,
    required this.truthY,
    required this.truthId,
  });

  final DateTime t;
  final String linkKey;
  final String fromNode;
  final String toNode;
  final double snrDb;
  final double? dipDb;
  final double? truthX;
  final double? truthY;
  final String? truthId;
}

/// One recorded session: rows grouped by poll time.
class BenchSession {
  BenchSession({required this.name, required List<BenchSessionRow> rows})
      : _rows = rows;

  final String name;
  final List<BenchSessionRow> _rows;

  List<BenchSessionRow> get rows => List.unmodifiable(_rows);

  /// Poll times, ascending. A poll is one distinct t_iso.
  List<DateTime> get polls {
    final seen = <DateTime>{};
    final out = <DateTime>[];
    for (final r in _rows) {
      if (seen.add(r.t)) out.add(r.t);
    }
    out.sort();
    return out;
  }

  /// Rows at one poll time.
  List<BenchSessionRow> rowsAt(DateTime t) =>
      [for (final r in _rows) if (r.t == t) r];

  /// Ground truth at one poll: the (truth_x, truth_y) of the first
  /// truth-carrying row, or null when the poll carries no truth.
  /// Multi-target polls (distinct truth_ids) are reported by
  /// [truthIdsAt]; the bench scores single-target polls for RMSE
  /// and counts multi-target polls as cardinality events.
  (double, double)? truthAt(DateTime t) {
    for (final r in rowsAt(t)) {
      if (r.truthX != null && r.truthY != null) return (r.truthX!, r.truthY!);
    }
    return null;
  }

  Set<String> truthIdsAt(DateTime t) => {
        for (final r in rowsAt(t))
          if (r.truthId != null && r.truthId!.isNotEmpty) r.truthId!,
      };
}

/// Parse one session CSV. Throws [FormatException] with the reason
/// when the file is not a bench session (missing dip_db or truth
/// columns, unparseable rows).
BenchSession parseSessionCsv(String name, String content) {
  final lines = content
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
  if (lines.isEmpty) {
    throw const FormatException('empty file');
  }
  final header = _splitCsv(lines.first);
  final idx = <String, int>{
    for (var i = 0; i < header.length; i++) header[i].trim(): i,
  };
  for (final col in [
    't_iso',
    'link_key',
    'from_node',
    'to_node',
    'snr_db',
    'dip_db',
    'truth_x',
    'truth_y',
    'truth_id',
  ]) {
    if (!idx.containsKey(col)) {
      throw FormatException('missing required column $col');
    }
  }
  final rows = <BenchSessionRow>[];
  for (var li = 1; li < lines.length; li++) {
    final f = _splitCsv(lines[li]);
    // A short row would throw RangeError on the column indexes
    // below; reject it as malformed instead so [loadSessions]
    // lists the file in `rejected` and the run continues.
    if (f.length < header.length) {
      throw FormatException(
          'short row ${li + 1}: ${f.length} fields, '
          'expected ${header.length}');
    }
    double? num(String col) {
      final v = f[idx[col]!].trim();
      if (v.isEmpty) return null;
      return double.tryParse(v);
    }

    final t = DateTime.tryParse(f[idx['t_iso']!]);
    final snr = num('snr_db');
    if (t == null || snr == null) {
      throw FormatException('unparseable row ${li + 1}');
    }
    rows.add(BenchSessionRow(
      t: t,
      linkKey: f[idx['link_key']!],
      fromNode: f[idx['from_node']!],
      toNode: f[idx['to_node']!],
      snrDb: snr,
      dipDb: num('dip_db'),
      truthX: num('truth_x'),
      truthY: num('truth_y'),
      truthId: f[idx['truth_id']!].trim().isEmpty
          ? null
          : f[idx['truth_id']!].trim(),
    ));
  }
  if (rows.isEmpty) throw const FormatException('no data rows');
  return BenchSession(name: name, rows: rows);
}

List<String> _splitCsv(String line) {
  // Minimal CSV split honoring double-quoted fields.
  final out = <String>[];
  final buf = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (ch == '"') {
      inQuotes = !inQuotes;
    } else if (ch == ',' && !inQuotes) {
      out.add(buf.toString());
      buf.clear();
    } else {
      buf.write(ch);
    }
  }
  out.add(buf.toString());
  return out;
}

/// Result of scanning a sessions directory.
class SessionLoad {
  const SessionLoad({required this.sessions, required this.rejected});

  /// Valid sessions, sorted by name.
  final List<BenchSession> sessions;

  /// File name -> rejection reason for files that looked like
  /// sessions but failed parsing.
  final Map<String, String> rejected;
}

/// Load every *.csv session under [dir]. A missing directory is not
/// an error — it is the normal "no recorded data" state.
SessionLoad loadSessions(Directory dir) {
  if (!dir.existsSync()) {
    return const SessionLoad(sessions: [], rejected: {});
  }
  final sessions = <BenchSession>[];
  final rejected = <String, String>{};
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.csv'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
    final name = f.uri.pathSegments.last;
    try {
      sessions.add(parseSessionCsv(name, f.readAsStringSync()));
    } on FormatException catch (e) {
      rejected[name] = e.message;
    } on FileSystemException catch (e) {
      rejected[name] = e.message;
    }
  }
  return SessionLoad(sessions: sessions, rejected: rejected);
}

/// Bench configuration (all tunables in one place, defaults
/// documented in docs/fusion_bench_b1_spec.md).
class BenchConfig {
  const BenchConfig({
    required this.sessionsDir,
    required this.nodes,
    this.dipThresholdDb = 6.0,
    this.sigma0M = 2.5,
    this.smoothingAlpha = 0.6,
    this.maxSpeedMps = 30.0,
    this.handoverJumpSigma = 3.0,
    this.handoverMissedPolls = 2,
    this.featureSet = FeatureSet.plusDipAndMotion,
    this.association = const AssociationParams(),
  });

  /// Directory scanned for *.csv sessions.
  final Directory sessionsDir;

  /// Node positions (field-local meters) by node id.
  final Map<String, NodePosition> nodes;

  /// Dip (dB) above which a link counts as disturbed.
  final double dipThresholdDb;

  /// Local-estimate position sigma (m) for one disturbed link —
  /// the tracker coarse-grid step.
  final double sigma0M;

  /// Exponential smoothing weight on a new centroid.
  final double smoothingAlpha;

  /// Velocity clamp for the local estimator (m/s).
  final double maxSpeedMps;

  /// Handover fragmentation: fused-position jump beyond this many
  /// fused sigmas (raw displacement vs the fused covariance scale)
  /// at a handover poll counts as a break.
  final double handoverJumpSigma;

  /// Handover fragmentation: this many consecutive missed fused
  /// polls after a handover counts as a break.
  final int handoverMissedPolls;

  /// Feature set the feature-aided arm runs (pass bar is stated on
  /// plusDip / plusDipAndMotion; see docs).
  final FeatureSet featureSet;

  final AssociationParams association;
}

/// One poll of a replayed session, after local estimation + fusion.
class ReplayPoll {
  const ReplayPoll({
    required this.t,
    required this.truth,
    required this.truthIds,
    required this.handover,
    required this.activeNodes,
    required this.fused,
    required this.rfState,
    required this.corrTracks,
  });

  final DateTime t;
  final (double, double)? truth;
  final Set<String> truthIds;

  /// True when the active-node set changed since the previous poll.
  final bool handover;

  final Set<String> activeNodes;

  /// Fused estimate per base arm key ("CI/metropolis",
  /// "CI/centrality", "ICI/metropolis", "ICI/centrality",
  /// "naive/metropolis", "naive/centrality"). Null when the arm
  /// produced no estimate at this poll.
  final Map<String, Gaussian2?> fused;

  /// RF track state for the association arm (from the ICI/metropolis
  /// fused estimate when present).
  final RfTrackState? rfState;

  /// Per-node local tracks offered as corroborators.
  final List<CorrTrack> corrTracks;
}

/// Bench-side per-node local estimator state.
class _NodeTrack {
  _NodeTrack({required this.nodeId});

  final String nodeId;
  double x = 0, y = 0, vx = 0, vy = 0;
  double varPerAxis = 0;
  double meanDipDb = 0;
  Map<String, double> dropSignature = {};
  DateTime? lastT;
  bool hasEstimate = false;
}

/// Replay one session through the local estimator + fusion arms.
List<ReplayPoll> replaySession(BenchSession session, BenchConfig config) {
  final nodes = config.nodes;
  final tracks = <String, _NodeTrack>{
    for (final id in nodes.keys) id: _NodeTrack(nodeId: id),
  };
  // Mesh adjacency from the node map: links exist between every pair
  // of nodes that share a recorded link_key in the session.
  final adjacency = _adjacencyFromSession(session, nodes.keys.toList());
  final metro = metropolisWeights(adjacency);
  final centr = centralityWeights(adjacency);
  final lambdaMetro = secondLargestEigenvalue(metro);
  final lambdaCentr = secondLargestEigenvalue(centr);
  final diameter = meshDiameter(adjacency);
  final itersMetro = fusionIterations(
    nodeCount: nodes.length,
    lambda2: lambdaMetro,
    diameter: diameter,
  ).iterations;
  final itersCentr = fusionIterations(
    nodeCount: nodes.length,
    lambda2: lambdaCentr,
    diameter: diameter,
  ).iterations;

  final polls = session.polls;
  final out = <ReplayPoll>[];
  Set<String> prevActive = {};
  Gaussian2? prevFusedIci;
  DateTime? prevT;

  for (final t in polls) {
    final rows = session.rowsAt(t);
    final truth = session.truthAt(t);
    final truthIds = session.truthIdsAt(t);
    // Disturbed rows grouped by node (incident links).
    final byNode = <String, List<BenchSessionRow>>{};
    final dipByNode = <String, List<double>>{};
    for (final r in rows) {
      if ((r.dipDb ?? 0) <= config.dipThresholdDb) continue;
      for (final n in [r.fromNode, r.toNode]) {
        if (!nodes.containsKey(n)) continue;
        (byNode[n] ??= []).add(r);
        (dipByNode[n] ??= []).add(r.dipDb!);
      }
    }
    final active = byNode.keys.toSet();
    final handover = prevActive.isNotEmpty && !_setsEqual(active, prevActive);
    // Update local estimators.
    final local = <String, Gaussian2>{};
    final corr = <CorrTrack>[];
    for (final entry in byNode.entries) {
      final nodeId = entry.key;
      final disturbed = entry.value;
      // Dip-weighted centroid of disturbed-link midpoints.
      var wx = 0.0, wy = 0.0, wsum = 0.0;
      for (final r in disturbed) {
        final a = nodes[r.fromNode];
        final b = nodes[r.toNode];
        if (a == null || b == null) continue;
        final mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2;
        final w = r.dipDb!;
        wx += w * mx;
        wy += w * my;
        wsum += w;
      }
      if (wsum <= 0) continue;
      final cx = wx / wsum, cy = wy / wsum;
      final tr = tracks[nodeId]!;
      final dt = tr.lastT == null
          ? 0.0
          : t.difference(tr.lastT!).inMicroseconds / 1e6;
      final varBase = (config.sigma0M * config.sigma0M) / disturbed.length +
          (0.3 * dt) * (0.3 * dt);
      if (!tr.hasEstimate) {
        tr.x = cx;
        tr.y = cy;
        tr.vx = 0;
        tr.vy = 0;
      } else {
        final px = tr.x + tr.vx * dt;
        final py = tr.y + tr.vy * dt;
        final nvx = dt > 0 ? (cx - tr.x) / dt : 0.0;
        final nvy = dt > 0 ? (cy - tr.y) / dt : 0.0;
        final cvx = nvx.clamp(-config.maxSpeedMps, config.maxSpeedMps);
        final cvy = nvy.clamp(-config.maxSpeedMps, config.maxSpeedMps);
        tr.x = config.smoothingAlpha * cx +
            (1 - config.smoothingAlpha) * px;
        tr.y = config.smoothingAlpha * cy +
            (1 - config.smoothingAlpha) * py;
        tr.vx = cvx;
        tr.vy = cvy;
      }
      tr.varPerAxis = varBase;
      tr.meanDipDb = dipByNode[nodeId]!
              .fold(0.0, (p, e) => p + e) /
          dipByNode[nodeId]!.length;
      // Drop signature: mean dip per incident link key.
      final sig = <String, double>{};
      for (final r in disturbed) {
        sig[r.linkKey] = r.dipDb!;
      }
      tr.dropSignature = sig;
      tr.lastT = t;
      tr.hasEstimate = true;
      local[nodeId] = Gaussian2(
        x: tr.x,
        y: tr.y,
        pxx: varBase,
        pxy: 0,
        pyy: varBase,
      );
      // Truth attribution (B2): this local track inherits the
      // truth id(s) of its own disturbed links. A single id means
      // the tracklet belongs to that target; mixed or unattributed
      // links leave it unattributed (null) — the association
      // scorer can only call a match false when both sides carry
      // a truth id.
      final nodeTruthIds = {
        for (final r in disturbed)
          if (r.truthId != null && r.truthId!.isNotEmpty) r.truthId!,
      };
      corr.add(CorrTrack(
        id: nodeId,
        x: tr.x,
        y: tr.y,
        vx: tr.vx,
        vy: tr.vy,
        meanDipDb: tr.meanDipDb,
        dropSignature: Map.of(sig),
        truthId:
            nodeTruthIds.length == 1 ? nodeTruthIds.first : null,
      ));
    }
    // Fuse per base arm (only over currently-active nodes).
    final fused = <String, Gaussian2?>{};
    RfTrackState? rfState;
    if (local.length >= 2) {
      final ids = local.keys.toList()..sort();
      // Position of each node id in the FULL node list (the weight
      // matrices are indexed in nodes.keys order, not active order).
      final allIds = nodes.keys.toList();
      final fullIdx = {
        for (var i = 0; i < allIds.length; i++) allIds[i]: i,
      };
      final estimates = [for (final id in ids) local[id]!];
      // Sub-weights for the active set only.
      List<List<double>> subWeights(List<List<double>> full) {
        return [
          for (final i in ids)
            [for (final j in ids) full[fullIdx[i]!][fullIdx[j]!]],
        ];
      }

      // Renormalize sub-weights to rows summing to 1 (active subset).
      List<List<double>> renorm(List<List<double>> w) {
        return [
          for (final row in w)
            () {
              final s = row.fold(0.0, (p, e) => p + e);
              if (s <= 0) return List.filled(row.length, 1.0 / row.length);
              return [for (final e in row) e / s];
            }(),
        ];
      }

      final arms = <String, (List<List<double>>, int, FusionRule)>{
        'CI/metropolis': (renorm(subWeights(metro)), itersMetro,
            FusionRule.ci),
        'CI/centrality': (renorm(subWeights(centr)), itersCentr,
            FusionRule.ci),
        'ICI/metropolis': (renorm(subWeights(metro)), itersMetro,
            FusionRule.ici),
        'ICI/centrality': (renorm(subWeights(centr)), itersCentr,
            FusionRule.ici),
        'naive/metropolis': (renorm(subWeights(metro)), itersMetro,
            FusionRule.naive),
        'naive/centrality': (renorm(subWeights(centr)), itersCentr,
            FusionRule.naive),
      };
      for (final e in arms.entries) {
        final (w, iters, rule) = e.value;
        final res = consensusFuse(
          estimates: estimates,
          weights: w,
          iterations: iters,
          rule: rule,
        );
        // Mesh-mean fused estimate.
        var mx = 0.0, my = 0.0;
        var vxx = 0.0, vxy = 0.0, vyy = 0.0;
        for (final g in res) {
          mx += g.x;
          my += g.y;
          vxx += g.pxx;
          vxy += g.pxy;
          vyy += g.pyy;
        }
        final n = res.length.toDouble();
        fused[e.key] = Gaussian2(
          x: mx / n,
          y: my / n,
          pxx: vxx / n,
          pxy: vxy / n,
          pyy: vyy / n,
        );
      }
      // RF state for association: ICI/metropolis fused estimate.
      final ici = fused['ICI/metropolis'];
      if (ici != null) {
        double vx = 0, vy = 0;
        final prevFused = prevFusedIci;
        final prevTime = prevT;
        if (prevFused != null && prevTime != null) {
          final dt = t.difference(prevTime).inMicroseconds / 1e6;
          if (dt > 0) {
            vx = (ici.x - prevFused.x) / dt;
            vy = (ici.y - prevFused.y) / dt;
          }
        }
        final allDips = [
          for (final r in rows) if (r.dipDb != null) r.dipDb!,
        ];
        final meanDip = allDips.isEmpty
            ? 0.0
            : allDips.fold(0.0, (p, e) => p + e) / allDips.length;
        final sig = <String, double>{
          for (final r in rows)
            if (r.dipDb != null) r.linkKey: r.dipDb!,
        };
        rfState = RfTrackState(
          estimate: ici,
          vx: vx,
          vy: vy,
          meanDipDb: meanDip,
          dropSignature: sig,
          // The RF track represents whichever target its fused
          // estimate is nearest — the single-target poll value in
          // single-target sessions, the nearest target's id in
          // multi-target ones (null when the poll carries no truth
          // positions). Without this, the false-track check in
          // _scoreAssociation could never fire in multi-target
          // sessions, where it is the only place it is measurable.
          truthId: _nearestTruthId(rows, ici),
        );
        prevFusedIci = ici;
        prevT = t;
      }
    }
    out.add(ReplayPoll(
      t: t,
      truth: truth,
      truthIds: truthIds,
      handover: handover,
      activeNodes: active,
      fused: fused,
      rfState: rfState,
      corrTracks: corr,
    ));
    prevActive = active;
  }
  return out;
}

/// Truth id of the target the fused estimate [est] represents: the
/// id whose recorded truth position at this poll is nearest the
/// estimate. Null when the poll carries no truth positions.
String? _nearestTruthId(List<BenchSessionRow> rows, Gaussian2 est) {
  final pos = <String, (double, double)>{};
  for (final r in rows) {
    final id = r.truthId;
    if (id == null || id.isEmpty) continue;
    if (r.truthX == null || r.truthY == null) continue;
    pos.putIfAbsent(id, () => (r.truthX!, r.truthY!));
  }
  String? bestId;
  var bestD2 = double.infinity;
  for (final e in pos.entries) {
    final dx = est.x - e.value.$1;
    final dy = est.y - e.value.$2;
    final d2 = dx * dx + dy * dy;
    if (d2 < bestD2) {
      bestD2 = d2;
      bestId = e.key;
    }
  }
  return bestId;
}

bool _setsEqual(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);

/// Adjacency from the session: two nodes are adjacent when a recorded
/// link_key connects them.
List<List<int>> _adjacencyFromSession(
    BenchSession session, List<String> nodeIds) {
  final idx = {for (var i = 0; i < nodeIds.length; i++) nodeIds[i]: i};
  final adj = List.generate(nodeIds.length, (_) => <int>{});
  for (final r in session.rows) {
    final a = idx[r.fromNode];
    final b = idx[r.toNode];
    if (a == null || b == null || a == b) continue;
    adj[a].add(b);
    adj[b].add(a);
  }
  return [for (final s in adj) s.toList()..sort()];
}

/// --- Scoring -----------------------------------------------------------

/// Per-arm aggregate scores over replayed polls.
class ArmScores {
  const ArmScores({
    required this.arm,
    required this.rmse,
    required this.meanNees,
    required this.neesLow,
    required this.neesHigh,
    required this.neesInBounds,
    required this.samples,
    required this.fragmentations,
    required this.handoverPolls,
  });

  final String arm;
  final double rmse;
  final double meanNees;
  final double neesLow;
  final double neesHigh;
  final bool neesInBounds;
  final int samples;
  final int fragmentations;
  final int handoverPolls;
}

/// Score the base fusion arms over [polls] (all sessions' polls
/// concatenated by the caller).
///
/// Fragmentation at handover counts two ways: (a) a jump — the fused
/// position at a handover poll displaces more than
/// [BenchConfig.handoverJumpSigma] fused sigmas from the previous
/// poll's fused position (only when the gap to that poll is under
/// 10 s — a jump after a long silence is a stale-track
/// re-acquisition, not a handover break); (b) a gap —
/// [BenchConfig.handoverMissedPolls] or more consecutive polls with
/// no fused estimate following a handover that occurred since the
/// last poll that produced a fused estimate (counted once per gap,
/// not once per missed poll).
Map<String, ArmScores> scoreBaseArms(
  List<ReplayPoll> polls,
  BenchConfig config,
) {
  const armKeys = [
    'CI/metropolis',
    'CI/centrality',
    'ICI/metropolis',
    'ICI/centrality',
    'naive/metropolis',
    'naive/centrality',
  ];
  final out = <String, ArmScores>{};
  for (final arm in armKeys) {
    final ests = <(double, double)>[];
    final truths = <(double, double)>[];
    final neesVals = <double>[];
    var frags = 0;
    var handovers = 0;
    Gaussian2? prev;
    DateTime? prevT;
    var missedRun = 0;
    var gapCounted = false;
    // S1: a missed-poll gap counts as a handover fragmentation only
    // when a handover happened SINCE the last poll that produced a
    // fused estimate. A handover from sessions earlier in the run
    // does not arm gaps that follow later fused polls.
    var handoverSinceLastFused = false;
    for (final p in polls) {
      if (p.handover) handovers++;
      final g = p.fused[arm];
      final truth = p.truth;
      if (g == null) {
        // Gap tracking: a run of missed polls after a handover
        // counts as one fragmentation once it reaches the bar.
        missedRun++;
        if (!gapCounted &&
            missedRun >= config.handoverMissedPolls &&
            handoverSinceLastFused) {
          frags++;
          gapCounted = true;
        }
      } else {
        // This poll produced a fused estimate: it breaks the
        // missed run and disarms the gap counter. A handover AT
        // this poll re-arms it (set after this block).
        missedRun = 0;
        gapCounted = false;
        handoverSinceLastFused = false;
        if (truth != null && p.truthIds.length == 1) {
          ests.add((g.x, g.y));
          truths.add(truth);
          neesVals.add(nees(g, truth.$1, truth.$2));
          // Jump fragmentation: fused position jumps beyond the gate
          // from the previous poll's fused position at a handover poll.
          final prevG = prev;
          final prevTime = prevT;
          if (p.handover && prevG != null && prevTime != null) {
            final dt = p.t.difference(prevTime).inMicroseconds / 1e6;
            if (dt > 0 && dt < 10) {
              final dx = g.x - prevG.x, dy = g.y - prevG.y;
              final sig = _sigmaOf(g);
              if (sig > 0 &&
                  (dx * dx + dy * dy) >
                      config.handoverJumpSigma *
                          config.handoverJumpSigma *
                          sig *
                          sig) {
                frags++;
              }
            }
          }
        }
        prev = g;
        prevT = p.t;
      }
      // A handover at this poll arms the gap counter for the polls
      // that follow it, until the next fused estimate disarms it.
      if (p.handover) handoverSinceLastFused = true;
    }
    final bounds = neesMeanBounds95(neesVals.length);
    final meanNees = neesVals.isEmpty
        ? double.nan
        : neesVals.fold(0.0, (a, b) => a + b) / neesVals.length;
    out[arm] = ArmScores(
      arm: arm,
      rmse: ests.isEmpty
          ? double.nan
          : rmse(ests, truths),
      meanNees: meanNees,
      neesLow: bounds.low,
      neesHigh: bounds.high,
      neesInBounds: neesVals.isNotEmpty &&
          meanNees >= bounds.low &&
          meanNees <= bounds.high,
      samples: ests.length,
      fragmentations: frags,
      handoverPolls: handovers,
    );
  }
  return out;
}

double _sigmaOf(Gaussian2 g) =>
    (g.pxx + g.pyy) / 2 <= 0 ? 0 : math.sqrt((g.pxx + g.pyy) / 2);

/// --- Verdicts ----------------------------------------------------------

/// One pass-bar verdict.
class BenchVerdict {
  const BenchVerdict({
    required this.bar,
    required this.passed,
    required this.detail,
    this.notApplicable = false,
  });

  /// Which pass bar this is (e.g. "B1 base: ICI RMSE < CI RMSE").
  final String bar;

  /// True when the bar's condition holds. Never true when
  /// [notApplicable] is set — a bar that cannot be evaluated has
  /// not passed.
  final bool passed;

  final String detail;

  /// True when the bar is not evaluable on this run: a relative
  /// bar whose baseline is zero (no handover fragmentations, no
  /// kinematics switches) cannot show a 20% improvement, so the
  /// verdict reports N/A instead of a vacuous PASS. N/A verdicts
  /// are excluded from [BenchOutcome.allPassed] (which still
  /// requires at least one applicable verdict).
  final bool notApplicable;
}

/// Outcome of a bench run: SKIPPED when no recorded data exists,
/// otherwise the scored arms + verdicts.
class BenchOutcome {
  const BenchOutcome({
    required this.skipped,
    this.skipReason,
    this.sessionsRun = const [],
    this.rejected = const {},
    this.armScores = const {},
    this.association = const {},
    this.verdicts = const [],
  });

  /// True when the bench did not measure anything.
  final bool skipped;

  /// "measurement pending — no recorded data" when skipped for the
  /// data rule; other text when skipped for another reason.
  final String? skipReason;

  final List<String> sessionsRun;
  final Map<String, String> rejected;
  final Map<String, ArmScores> armScores;

  /// Association scores per feature set ("kinematics",
  /// "plusDip", "plusDipAndMotion", "plusDipMotionAndSignature").
  final Map<String, AssociationScores> association;

  final List<BenchVerdict> verdicts;

  /// True when every EVALUABLE verdict passed (and at least one
  /// verdict was evaluable). A not-applicable verdict is neither a
  /// pass nor a fail — it is reported as N/A and excluded here.
  bool get allPassed {
    final applicable = verdicts.where((v) => !v.notApplicable);
    return !skipped &&
        applicable.isNotEmpty &&
        applicable.every((v) => v.passed);
  }

  @override
  String toString() {
    if (skipped) return 'BenchOutcome(SKIPPED: $skipReason)';
    return 'BenchOutcome(sessions=${sessionsRun.length}, '
        'verdicts=${verdicts.where((v) => v.passed).length}/'
        '${verdicts.length} passed)';
  }
}

/// Run the full B1 bench (base arms + feature-aided association arm +
/// ICI handover-smoothing arm) on the recorded sessions under
/// [config.sessionsDir].
///
/// Measurement ONLY: with no valid sessions this returns
/// [BenchOutcome.skipped] == true and measures nothing.
BenchOutcome runFusionBench(BenchConfig config) {
  final load = loadSessions(config.sessionsDir);
  if (load.sessions.isEmpty) {
    return BenchOutcome(
      skipped: true,
      skipReason: 'measurement pending — no recorded data',
      rejected: load.rejected,
    );
  }
  final allPolls = <ReplayPoll>[];
  for (final s in load.sessions) {
    allPolls.addAll(replaySession(s, config));
  }
  final armScores = scoreBaseArms(allPolls, config);

  // Association arms: run the Hungarian association per poll for
  // each feature set and score identity switches / cardinality /
  // false tracks against truth.
  final assoc = <String, AssociationScores>{};
  for (final fs in FeatureSet.values) {
    assoc[fs.name] = _scoreAssociation(allPolls, fs, config);
  }

  // Verdicts — the bench's pass bars (docs/fusion_bench_b1_spec.md).
  final verdicts = <BenchVerdict>[];
  final ci = armScores['CI/metropolis'];
  final ici = armScores['ICI/metropolis'];
  if (ci != null && ici != null) {
    verdicts.add(BenchVerdict(
      bar: 'B1 base: ICI RMSE < CI RMSE (Metropolis weights)',
      passed: ici.rmse < ci.rmse,
      detail: 'ICI RMSE ${ici.rmse.toStringAsFixed(3)} m vs CI RMSE '
          '${ci.rmse.toStringAsFixed(3)} m (${ici.samples} samples)',
    ));
    verdicts.add(BenchVerdict(
      bar: 'B1 base: ICI mean NEES inside 95% bounds',
      passed: ici.neesInBounds,
      detail: 'mean NEES ${ici.meanNees.toStringAsFixed(3)} in '
          '[${ici.neesLow.toStringAsFixed(3)}, '
          '${ici.neesHigh.toStringAsFixed(3)}]',
    ));
    verdicts.add(BenchVerdict(
      bar: 'B1 base: CI mean NEES inside 95% bounds',
      passed: ci.neesInBounds,
      detail: 'mean NEES ${ci.meanNees.toStringAsFixed(3)} in '
          '[${ci.neesLow.toStringAsFixed(3)}, '
          '${ci.neesHigh.toStringAsFixed(3)}]',
    ));
    verdicts.add(BenchVerdict(
      bar: 'ICI handover: >=20% fewer fragmentations/ID-switches '
          'at handover vs CI, NEES in bounds',
      // S2: a relative bar needs a non-zero baseline. With zero CI
      // fragmentations (or no handover polls at all) the bar is
      // not evaluable — 0 <= 0 would PASS vacuously.
      notApplicable:
          ci.fragmentations == 0 || ici.handoverPolls == 0,
      passed: ci.fragmentations > 0 &&
          ici.handoverPolls > 0 &&
          ici.fragmentations <= 0.8 * ci.fragmentations &&
          ici.neesInBounds,
      detail: ci.fragmentations == 0 || ici.handoverPolls == 0
          ? 'NOT EVALUABLE: CI has ${ci.fragmentations} '
              'fragmentations over ${ici.handoverPolls} handover '
              'polls — no baseline for a 20% reduction'
          : 'ICI ${ici.fragmentations} fragmentations vs CI '
              '${ci.fragmentations} over ${ici.handoverPolls} handover '
              'polls; ICI NEES in bounds: ${ici.neesInBounds}',
    ));
  }
  final kin = assoc[FeatureSet.kinematics.name];
  final plus1 = assoc[FeatureSet.plusDip.name];
  final plus2 = assoc[FeatureSet.plusDipAndMotion.name];
  if (kin != null && plus1 != null && plus2 != null) {
    final baseSwitches = kin.identitySwitches + kin.cardinalityError;
    final p1Switches = plus1.identitySwitches + plus1.cardinalityError;
    final p2Switches = plus2.identitySwitches + plus2.cardinalityError;
    // S2: the 20%-fewer bar needs a non-zero kinematics baseline.
    // With zero baseline switches the bar is not evaluable — 0 <= 0
    // would PASS vacuously.
    verdicts.add(BenchVerdict(
      bar: 'Feature arm (+1 dip): >=20% fewer identity switches + '
          'cardinality error vs kinematics-only, no false-track '
          'increase, <5 ms added latency/association',
      notApplicable: baseSwitches == 0,
      passed: baseSwitches > 0 &&
          p1Switches <= 0.8 * baseSwitches &&
          plus1.falseTracks <= kin.falseTracks &&
          plus1.meanLatencyMs < 5.0,
      detail: baseSwitches == 0
          ? 'NOT EVALUABLE: kinematics baseline has 0 switches+'
              'cardErr — no baseline for a 20% reduction'
          : '+1 switches+cardErr $p1Switches vs kinematics '
              '$baseSwitches; false ${plus1.falseTracks} vs ${kin.falseTracks}; '
              'latency ${plus1.meanLatencyMs.toStringAsFixed(2)} ms',
    ));
    verdicts.add(BenchVerdict(
      bar: 'Feature arm (+2 dip+motion): >=20% fewer identity '
          'switches + cardinality error vs kinematics-only, no '
          'false-track increase, <5 ms added latency/association',
      notApplicable: baseSwitches == 0,
      passed: baseSwitches > 0 &&
          p2Switches <= 0.8 * baseSwitches &&
          plus2.falseTracks <= kin.falseTracks &&
          plus2.meanLatencyMs < 5.0,
      detail: baseSwitches == 0
          ? 'NOT EVALUABLE: kinematics baseline has 0 switches+'
              'cardErr — no baseline for a 20% reduction'
          : '+2 switches+cardErr $p2Switches vs kinematics '
              '$baseSwitches; false ${plus2.falseTracks} vs ${kin.falseTracks}; '
              'latency ${plus2.meanLatencyMs.toStringAsFixed(2)} ms',
    ));
  }

  return BenchOutcome(
    skipped: false,
    sessionsRun: [for (final s in load.sessions) s.name],
    rejected: load.rejected,
    armScores: armScores,
    association: assoc,
    verdicts: verdicts,
  );
}

/// Render a [BenchOutcome] as a human-readable report.
///
/// For a skipped outcome this is the whole story: the bench measured
/// nothing and says so. For a measured outcome it lists the arm
/// scores, association scores, and verdicts — never the paper numbers.
String benchReport(BenchOutcome outcome) {
  final b = StringBuffer()..writeln('B1 fusion bench');
  if (outcome.skipped) {
    b.writeln('SKIPPED: ${outcome.skipReason}');
    return b.toString();
  }
  b.writeln('Sessions: ${outcome.sessionsRun.join(', ')}');
  for (final s in outcome.armScores.values) {
    b.writeln('  ${s.arm}: RMSE ${s.rmse.toStringAsFixed(2)} m, '
        'mean NEES ${s.meanNees.toStringAsFixed(2)} '
        '(95% ${s.neesLow.toStringAsFixed(2)}–'
        '${s.neesHigh.toStringAsFixed(2)}), '
        'frag ${s.fragmentations}/${s.handoverPolls} handover polls, '
        'n=${s.samples}');
  }
  for (final e in outcome.association.entries) {
    final a = e.value;
    b.writeln('  assoc/${e.key}: switches ${a.identitySwitches}, '
        'cardErr ${a.cardinalityError}, false ${a.falseTracks}, '
        'latency ${a.meanLatencyMs.toStringAsFixed(2)} ms/step');
  }
  for (final v in outcome.verdicts) {
    b.writeln('  ${v.bar}: ${v.notApplicable ? 'N/A' : v.passed ? 'PASS' : 'FAIL'} — ${v.detail}');
  }
  b.writeln('Overall: ${outcome.allPassed ? 'ALL PASS' : 'NOT ALL PASS'}');
  return b.toString();
}

AssociationScores _scoreAssociation(
  List<ReplayPoll> polls,
  FeatureSet features,
  BenchConfig config,
) {
  var switches = 0;
  var cardErr = 0;
  var falseTracks = 0;
  var total = 0;
  var latencyMs = 0.0;
  var latencyN = 0;
  // Identity is the matched tracklet's TRUTH id (B2/S4), not the
  // node id: in single-target sessions every corroborator is the
  // same target, so a node-id change is a coverage handover, not a
  // wrong-track match. A switch counts only when the matched
  // tracklet's truth id changes between consecutive polls — the
  // RF track's match flipped to a different target's tracklet.
  // Polls where either side is unattributed (null) don't count.
  String? prevCorrTruthId;
  for (final p in polls) {
    final rf = p.rfState;
    if (rf == null) {
      prevCorrTruthId = null;
      continue;
    }
    final sw = Stopwatch()..start();
    final assocs = associate(
      rfTracks: [rf],
      corrTracks: p.corrTracks,
      features: features,
      params: config.association,
    );
    sw.stop();    latencyMs += sw.elapsedMicroseconds / 1000.0;
    latencyN++;
    cardErr += (assocs.length - p.truthIds.length).abs();
    if (assocs.isEmpty) {
      prevCorrTruthId = null;
      continue;
    }
    total += assocs.length;
    final corr = p.corrTracks[assocs.first.corrIndex];
    if (rf.truthId != null &&
        corr.truthId != null &&
        corr.truthId != rf.truthId) {
      falseTracks++;
    }
    if (prevCorrTruthId != null &&
        corr.truthId != null &&
        prevCorrTruthId != corr.truthId) {
      switches++;
    }
    prevCorrTruthId = corr.truthId;
  }
  return AssociationScores(
    identitySwitches: switches,
    cardinalityError: cardErr,
    falseTracks: falseTracks,
    totalAssociations: total,
    meanLatencyMs: latencyN == 0 ? 0.0 : latencyMs / latencyN,
  );
}
