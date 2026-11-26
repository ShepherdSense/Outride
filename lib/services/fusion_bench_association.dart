/// Feature-aided association arm (Tao et al.) + CATS-style
/// trajectory-similarity matching (Tian et al.) for the B1 bench.
///
/// EXPERIMENTAL — bench-only library, never wired into the live
/// tracker or the app UI. See docs/fusion_bench_b1_spec.md.
///
/// Tao et al., Appl. Sci. 2026, 16, 3159 (full read): tracks are
/// associated across sensors with a multi-feature factor — Mahalanobis
/// distance plus |Doppler| and |SNR| terms, optimal assignment,
/// existence/association gates — then fused. The Outride analogs of
/// Doppler/SNR are: dip depth / link-shadow magnitude, speed/heading
/// consistency, and the per-node RSSI-drop signature. The bench tests
/// kinematics-only (Mahalanobis) vs kinematics + one cheap feature vs
/// kinematics + two, under the SAME Hungarian + gating structure, with
/// Outride-tuned thresholds.
///
/// What is NOT ported (per the lane verdict):
/// - The LMB filter, the GCI fusion step, equal fusion weights,
///   Radar-1-as-reference, or the paper's numeric thresholds
///   (0.85 existence gate, 10^-3 association gate, 0.3 feature
///   weights). The bench's gates/weights below are Outride-tuned
///   bench parameters, documented as such.
/// - The 37–54% OSPA gains (simulation-only, cardinality-driven) as
///   expected Outride gains. The bench's pass bar is RELATIVE:
///   >=20% fewer identity switches + cardinality error vs
///   kinematics-only, no false-track increase, <5 ms added latency
///   per association step.
///
/// Tian et al., Sensors 2026, 26, 4251 (full read): cross-domain
/// association by clue-aware trajectory similarity (CATS — spatial +
/// temporal similarity of trajectories in the overlap zone,
/// bidirectional argmax matching). The bench's CATS arm is that
/// pattern applied to corroborator tracks vs RF tracks. What is NOT
/// ported: Deep-SORT/OTTC vision machinery, GMCSC road-geometry
/// calibration, or the 98.4%/0.23 m figures as Outride expectations.
///
/// UPGRADE-ONLY RULE (standing, intact): association features only
/// decide WHICH corroborating track matches WHICH RF track. They
/// never create a detection — the RF track stays detection authority.
/// A corroborator track with no RF match is ignored, never promoted.
library;

import 'dart:math' as math;

import 'fusion_bench.dart';
import 'hungarian.dart';

/// Re-exported so existing bench callers and tests keep resolving
/// `hungarian` from this file; the implementation now lives in
/// `hungarian.dart`, the shared production home.
export 'hungarian.dart';

/// Which cheap features join the Mahalanobis kinematics cost.
enum FeatureSet {
  /// Mahalanobis distance only.
  kinematics,

  /// + dip-depth / link-shadow magnitude difference.
  plusDip,

  /// + dip depth and speed/heading consistency.
  plusDipAndMotion,

  /// + dip depth, motion, and per-node RSSI-drop signature.
  /// Exploratory variant; the bench's pass bar is stated on
  /// [plusDip] and [plusDipAndMotion].
  plusDipMotionAndSignature,
}

/// Bench-tuned association parameters (NOT the papers' numbers).
class AssociationParams {
  const AssociationParams({
    this.mahaGate = 9.21,
    this.costGate = 3.0,
    this.dipScaleDb = 5.0,
    this.speedScaleMps = 2.0,
    this.weightDip = 1.0,
    this.weightMotion = 1.0,
    this.weightSignature = 1.0,
  });

  /// Squared-Mahalanobis gate (chi2 2-dof 95% = 9.21). A pair beyond
  /// this is never associated, whatever the features say.
  final double mahaGate;

  /// Total-cost gate after features are added.
  final double costGate;

  /// Dip-difference normalization (dB).
  final double dipScaleDb;

  /// Speed-difference normalization (m/s).
  final double speedScaleMps;

  /// Feature weights in the COST only. These are not fusion weights
  /// and must never be confused with Tao's equal fusion weights.
  final double weightDip;
  final double weightMotion;
  final double weightSignature;
}

/// One corroborator tracklet offered for association to an RF track.
///
/// Carries everything the cheap features need: recent kinematics,
/// mean dip depth, and the per-node RSSI-drop signature (dip per
/// incident link, keyed by node id).
class CorrTrack {
  const CorrTrack({
    required this.id,
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.meanDipDb,
    required this.dropSignature,
    this.truthId,
  });

  /// Bench-local id (e.g. the node that produced this tracklet).
  final String id;

  final double x;
  final double y;
  final double vx;
  final double vy;

  /// Mean dip depth (dB) over the tracklet's disturbed links.
  final double meanDipDb;

  /// Per-node dip signature: node id -> dip (dB) on that node's
  /// incident links. Empty when unknown (signature term skipped).
  final Map<String, double> dropSignature;

  /// Ground-truth identity when known (bench scoring only); null
  /// in production-shaped data.
  final String? truthId;
}

/// One RF track state offered for association (the fused track's
/// position + covariance, plus the motion/dip context the features
/// need). The covariance is the fused estimate's — association
/// never invents a covariance for the RF track.
class RfTrackState {
  const RfTrackState({
    required this.estimate,
    required this.vx,
    required this.vy,
    required this.meanDipDb,
    required this.dropSignature,
    this.truthId,
  });

  final Gaussian2 estimate;
  final double vx;
  final double vy;
  final double meanDipDb;
  final Map<String, double> dropSignature;
  final String? truthId;
}

/// Squared Mahalanobis distance from [estimate] to point (x, y).
double mahalanobis2(Gaussian2 estimate, double x, double y) {
  final ex = x - estimate.x;
  final ey = y - estimate.y;
  final info = estimate.information;
  return ex * ex * info[0] + 2 * ex * ey * info[1] + ey * ey * info[2];
}

/// Cosine similarity of two per-node drop signatures (0 when either
/// side is empty or a zero vector). 1 = identical drop pattern.
double dropSignatureSimilarity(
  Map<String, double> a,
  Map<String, double> b,
) {
  if (a.isEmpty || b.isEmpty) return 0.0;
  final keys = {...a.keys, ...b.keys};
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (final k in keys) {
    final va = a[k] ?? 0.0;
    final vb = b[k] ?? 0.0;
    dot += va * vb;
    na += va * va;
    nb += vb * vb;
  }
  if (na <= 0 || nb <= 0) return 0.0;
  return dot / (math.sqrt(na) * math.sqrt(nb));
}

/// Association cost between an RF track and a corroborator tracklet.
///
/// cost = maha2/mahaGate + wDip*|dDip|/dipScale
///        + wMotion*(|dSpeed|/speedScale + (1-cos(dHeading))/2)
///        + wSig*(1 - signatureSimilarity)
/// under [features]. Lower is a better match.
double associationCost({
  required RfTrackState rf,
  required CorrTrack corr,
  required FeatureSet features,
  AssociationParams params = const AssociationParams(),
}) {
  final maha2 = mahalanobis2(rf.estimate, corr.x, corr.y);
  var cost = maha2 / params.mahaGate;
  if (features == FeatureSet.kinematics) return cost;
  final dDip = (rf.meanDipDb - corr.meanDipDb).abs() / params.dipScaleDb;
  cost += params.weightDip * dDip;
  if (features == FeatureSet.plusDip) return cost;
  final dSpeed = (math.sqrt(rf.vx * rf.vx + rf.vy * rf.vy) -
          math.sqrt(corr.vx * corr.vx + corr.vy * corr.vy))
      .abs() /
      params.speedScaleMps;
  final cosDh = _cosHeadingDiff(rf.vx, rf.vy, corr.vx, corr.vy);
  cost += params.weightMotion * (dSpeed + (1.0 - cosDh) / 2.0);
  if (features == FeatureSet.plusDipAndMotion) return cost;
  final sim = dropSignatureSimilarity(rf.dropSignature, corr.dropSignature);
  cost += params.weightSignature * (1.0 - sim);
  return cost;
}

double _cosHeadingDiff(double vx1, double vy1, double vx2, double vy2) {
  final n1 = math.sqrt(vx1 * vx1 + vy1 * vy1);
  final n2 = math.sqrt(vx2 * vx2 + vy2 * vy2);
  if (n1 < 1e-9 || n2 < 1e-9) return 1.0; // no heading evidence: neutral
  return ((vx1 * vx2 + vy1 * vy2) / (n1 * n2)).clamp(-1.0, 1.0);
}

/// One accepted association: RF row [rfIndex] <-> corroborator column
/// [corrIndex] at [cost].
class Association {
  const Association({
    required this.rfIndex,
    required this.corrIndex,
    required this.cost,
  });

  final int rfIndex;
  final int corrIndex;
  final double cost;
}

/// Associate RF tracks to corroborator tracklets with the Hungarian
/// algorithm (minimum total cost) under [params] gates.
///
/// Pairs failing the Mahalanobis gate or the total-cost gate are
/// rejected (the corroborator stays unassociated — upgrade-only: it
/// never becomes a detection on its own).
List<Association> associate({
  required List<RfTrackState> rfTracks,
  required List<CorrTrack> corrTracks,
  required FeatureSet features,
  AssociationParams params = const AssociationParams(),
}) {
  if (rfTracks.isEmpty || corrTracks.isEmpty) return const [];
  final rows = rfTracks.length;
  final cols = corrTracks.length;
  // Cost matrix with gating applied up front: gated pairs get a
  // prohibitive cost so the Hungarian never picks them.
  const big = 1e9;
  final cost = List.generate(rows, (i) {
    return List.generate(cols, (j) {
      final rf = rfTracks[i];
      final corr = corrTracks[j];
      final maha2 = mahalanobis2(rf.estimate, corr.x, corr.y);
      if (maha2 > params.mahaGate) return big;
      final c = associationCost(
          rf: rf, corr: corr, features: features, params: params);
      if (c > params.costGate) return big;
      return c;
    });
  });
  final pairs = hungarian(cost);
  return [
    for (final (i, j) in pairs)
      if (cost[i][j] < big)
        Association(rfIndex: i, corrIndex: j, cost: cost[i][j]),
  ];
}

/// --- CATS-style trajectory similarity (Tian et al.) -------------------

/// One point of a tracklet for trajectory-similarity matching.
class TrackPoint {
  const TrackPoint({
    required this.t,
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
  });

  /// Seconds since the tracklet's start (monotonic).
  final double t;
  final double x;
  final double y;
  final double vx;
  final double vy;
}

/// Spatial + temporal similarity of two tracklets over their
/// overlapping time window (CATS pattern).
///
/// spatial = 1 / (1 + meanDistance / spatialScale); temporal =
/// (1 + mean velocity-cosine) / 2; similarity =
/// 0.5 * spatial + 0.5 * temporal. Returns 0 when the tracklets do
/// not overlap in time or either is empty. The 0.5/0.5 split is the
/// bench's own weighting — Tian's paper does not publish its weights.
double trajectorySimilarity(
  List<TrackPoint> a,
  List<TrackPoint> b, {
  double spatialScaleM = 5.0,
}) {
  if (a.isEmpty || b.isEmpty) return 0.0;
  final t0 = math.max(a.first.t, b.first.t);
  final t1 = math.min(a.last.t, b.last.t);
  if (t1 <= t0) return 0.0;
  // Sample both tracklets at the union of their timestamps inside
  // the overlap, linearly interpolating positions/velocities.
  final times = <double>{
    for (final p in a)
      if (p.t >= t0 && p.t <= t1) p.t,
    for (final p in b)
      if (p.t >= t0 && p.t <= t1) p.t,
  }.toList()
    ..sort();
  if (times.isEmpty) return 0.0;
  var distSum = 0.0;
  var cosSum = 0.0;
  var count = 0;
  for (final t in times) {
    final pa = _interp(a, t);
    final pb = _interp(b, t);
    if (pa == null || pb == null) continue;
    distSum += math.sqrt(
        (pa.x - pb.x) * (pa.x - pb.x) + (pa.y - pb.y) * (pa.y - pb.y));
    final n1 = math.sqrt(pa.vx * pa.vx + pa.vy * pa.vy);
    final n2 = math.sqrt(pb.vx * pb.vx + pb.vy * pb.vy);
    if (n1 > 1e-9 && n2 > 1e-9) {
      cosSum += ((pa.vx * pb.vx + pa.vy * pb.vy) / (n1 * n2))
          .clamp(-1.0, 1.0);
    } else {
      cosSum += 1.0; // no motion evidence either side: neutral
    }
    count++;
  }
  if (count == 0) return 0.0;
  final spatial = 1.0 / (1.0 + (distSum / count) / spatialScaleM);
  final temporal = (1.0 + (cosSum / count)) / 2.0;
  return 0.5 * spatial + 0.5 * temporal;
}

TrackPoint? _interp(List<TrackPoint> pts, double t) {
  if (pts.isEmpty) return null;
  if (t <= pts.first.t) return pts.first;
  if (t >= pts.last.t) return pts.last;
  for (var i = 0; i + 1 < pts.length; i++) {
    final p0 = pts[i], p1 = pts[i + 1];
    if (t >= p0.t && t <= p1.t) {
      final f = (t - p0.t) / (p1.t - p0.t);
      return TrackPoint(
        t: t,
        x: p0.x + (p1.x - p0.x) * f,
        y: p0.y + (p1.y - p0.y) * f,
        vx: p0.vx + (p1.vx - p0.vx) * f,
        vy: p0.vy + (p1.vy - p0.vy) * f,
      );
    }
  }
  return pts.last;
}

/// CATS bidirectional argmax matching: tracklet a[i] matches b[j]
/// only when j is a[i]'s best match AND i is b[j]'s best match.
/// [similarity] is the pairwise similarity matrix (rows = set A,
/// cols = set B). Pairs below [threshold] are rejected.
List<(int, int)> catsMatch(
  List<List<double>> similarity, {
  double threshold = 0.5,
}) {
  final rows = similarity.length;
  if (rows == 0) return const [];
  final cols = similarity[0].length;
  final out = <(int, int)>[];
  for (var i = 0; i < rows; i++) {
    var bestJ = -1;
    var best = threshold;
    for (var j = 0; j < cols; j++) {
      if (similarity[i][j] > best) {
        best = similarity[i][j];
        bestJ = j;
      }
    }
    if (bestJ < 0) continue;
    // Bidirectional: is i also b[bestJ]'s best match?
    var bestI = -1;
    var best2 = threshold;
    for (var k = 0; k < rows; k++) {
      if (similarity[k][bestJ] > best2) {
        best2 = similarity[k][bestJ];
        bestI = k;
      }
    }
    if (bestI == i) out.add((i, bestJ));
  }
  return out;
}

/// --- Scoring -----------------------------------------------------------

/// Association scores for one bench run over a session.
class AssociationScores {
  const AssociationScores({
    required this.identitySwitches,
    required this.cardinalityError,
    required this.falseTracks,
    required this.totalAssociations,
    required this.meanLatencyMs,
  });

  /// Times the RF track's matched corroborator TRUTH id changed
  /// between consecutive polls — the match flipped to a different
  /// target's tracklet. (A node-id change is NOT a switch: in a
  /// single-target session every corroborator is the same target,
  /// so a node change is a coverage handover, not a wrong-track
  /// match. Polls where either side's truth id is unattributed
  /// don't count.)
  final int identitySwitches;

  /// Sum over polls of |#associated - #true tracks|.
  final int cardinalityError;

  /// Associations to a corroborator carrying a different truth id
  /// than the RF track's — a match to another target's tracklet.
  /// Zero by construction in single-target sessions (every
  /// attributed corroborator carries the one truth id); measurable
  /// only in multi-target sessions.
  final int falseTracks;

  final int totalAssociations;

  /// Mean wall-clock ms per association step (Stopwatch-measured;
  /// the <5 ms pass bar is evaluated on EUD hardware — sandbox
  /// numbers are indicative only).
  final double meanLatencyMs;

  @override
  String toString() =>
      'AssociationScores(switches=$identitySwitches, '
      'cardErr=$cardinalityError, false=$falseTracks, '
      'n=$totalAssociations, latency=${meanLatencyMs.toStringAsFixed(2)}ms)';
}
