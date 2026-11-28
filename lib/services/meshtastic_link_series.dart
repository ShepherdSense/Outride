/// Per-edge Meshtastic link time series (improvement #1).
///
/// The driver used to keep only last-heard SNR per node — one number,
/// no history, no RSSI. The protocol already delivers `rx_snr` +
/// `rx_rssi` on every packet, and ~89% of mesh traffic is routine
/// NodeInfo/Position/Telemetry, so the mesh is already a continuous
/// probe source at zero extra airtime. This store keeps that stream.
///
/// Node numbers are raw Meshtastic node numbers (uint32). The value
/// [MeshLinkSeries.localNode] (0) stands for "our local node, number
/// not yet learned" — the driver replaces it with the real number
/// once `FromRadio.my_info` arrives. Edges are directed: `from` is
/// the node that transmitted, `to` is the node that heard it.
///
/// HONESTY: a step change in this series is CONSISTENT WITH a link
/// disturbance (a body shadowing the link, a node moving); it is
/// never proof of one, and Meshtastic is NOT tripwire-grade — it is
/// a link-health / presence layer. These samples must never delete
/// or downgrade a detection on their own (never-subtractive rule).
library;

import 'dart:collection';

/// One received-packet observation on one directed edge.
class MeshLinkSample {
  const MeshLinkSample({
    required this.timestamp,
    required this.fromNode,
    required this.toNode,
    this.snr,
    this.rssi,
    this.hopCount,
    this.portnum,
    this.chUtil,
    this.airUtil,
  });

  /// Wall-clock time the packet was received (local clock).
  final DateTime timestamp;

  /// Node number that transmitted (0 = unknown).
  final int fromNode;

  /// Node number that heard it ([MeshLinkSeries.localNode] = our
  /// local node when its number is not yet known).
  final int toNode;

  /// Received SNR in dB, as reported by the receiving radio.
  final double? snr;

  /// Received RSSI in dBm (field 12, int32 varint — NOT field 9).
  final double? rssi;

  /// Hops already travelled (`hop_start - hop_limit`), or null when
  /// the packet carried no usable hop_start.
  final int? hopCount;

  /// Decoded payload portnum (e.g. 67 telemetry, 71 neighbor-info,
  /// 300 Outride probe), when the packet carried a decoded payload.
  final int? portnum;

  /// Channel utilization (0..100, %) reported by the sender's
  /// telemetry `DeviceMetrics.channel_utilization`, when this sample
  /// came from a telemetry packet. Null otherwise.
  final double? chUtil;

  /// Airtime utilization (0..100, %) reported by the sender's
  /// telemetry `DeviceMetrics.air_util_tx`, when this sample came
  /// from a telemetry packet. Null otherwise.
  final double? airUtil;

  /// True when this sample carries any link-quality measurement.
  bool get hasLinkQuality => snr != null || rssi != null;
}

/// Bounded per-edge ring-buffer store for [MeshLinkSample]s.
///
/// Caps: 512 samples per edge, 256 edges. When the edge cap is hit,
/// the edge whose newest sample is oldest is dropped whole (it is
/// the stalest edge, not the busiest). Samples older than
/// [pruneOlderThan] can be dropped on demand; the store never grows
/// without bound.
class MeshLinkSeries {
  /// Node-number sentinel for "our local node, number unknown yet".
  static const int localNode = 0;

  /// Max samples kept per edge.
  static const int maxSamplesPerEdge = 512;

  /// Max distinct edges kept.
  static const int maxEdges = 256;

  final Map<String, Queue<MeshLinkSample>> _edges = {};

  static String edgeKey(int from, int to) => '$from>$to';

  /// Record one sample. Silently drops samples with no measurement
  /// at all (no SNR, no RSSI, no telemetry utilization) — they
  /// carry no link information.
  void record(MeshLinkSample sample) {
    if (!sample.hasLinkQuality &&
        sample.chUtil == null &&
        sample.airUtil == null) {
      return;
    }
    // Non-finite measurements (NaN/±Inf) carry no information and
    // would poison medians (a NaN window makes detectStep return
    // NaN, not null). Drop them at the boundary; a sample whose
    // only measurement is non-finite is dropped whole, and a
    // sample with a finite measurement keeps only the finite ones.
    final snr = sample.snr?.isFinite == true ? sample.snr : null;
    final rssi = sample.rssi?.isFinite == true ? sample.rssi : null;
    final chUtil =
        sample.chUtil?.isFinite == true ? sample.chUtil : null;
    final airUtil =
        sample.airUtil?.isFinite == true ? sample.airUtil : null;
    if (snr == null && rssi == null && chUtil == null && airUtil == null) {
      return;
    }
    final clean = (snr == sample.snr &&
            rssi == sample.rssi &&
            chUtil == sample.chUtil &&
            airUtil == sample.airUtil)
        ? sample
        : MeshLinkSample(
            timestamp: sample.timestamp,
            fromNode: sample.fromNode,
            toNode: sample.toNode,
            snr: snr,
            rssi: rssi,
            hopCount: sample.hopCount,
            portnum: sample.portnum,
            chUtil: chUtil,
            airUtil: airUtil,
          );
    final key = edgeKey(clean.fromNode, clean.toNode);
    var q = _edges[key];
    if (q == null) {
      if (_edges.length >= maxEdges) {
        // Drop the stalest edge (oldest newest-sample).
        String? stalest;
        DateTime? stalestAt;
        for (final e in _edges.entries) {
          final at = e.value.isEmpty
              ? DateTime.fromMillisecondsSinceEpoch(0)
              : e.value.last.timestamp;
          if (stalestAt == null || at.isBefore(stalestAt)) {
            stalest = e.key;
            stalestAt = at;
          }
        }
        if (stalest != null) _edges.remove(stalest);
      }
      q = Queue<MeshLinkSample>();
      _edges[key] = q;
    }
    q.addLast(clean);
    while (q.length > maxSamplesPerEdge) {
      q.removeFirst();
    }
  }

  /// All samples for one directed edge, oldest first. Empty when
  /// the edge has never been seen.
  List<MeshLinkSample> seriesFor(int from, int to) {
    final q = _edges[edgeKey(from, to)];
    if (q == null) return const [];
    return List<MeshLinkSample>.unmodifiable(q);
  }

  /// Directed edge keys currently stored, as `(from, to)` pairs.
  List<(int, int)> get edges => [
        for (final k in _edges.keys)
          (
            int.parse(k.split('>').first),
            int.parse(k.split('>').last),
          ),
      ];

  /// Total samples stored across all edges.
  int get sampleCount =>
      _edges.values.fold(0, (sum, q) => sum + q.length);

  /// Number of distinct edges stored.
  int get edgeCount => _edges.length;

  /// Drop samples older than [maxAge] relative to [now]
  /// (defaults to now). Empty edges are removed.
  void pruneOlderThan(Duration maxAge, {DateTime? now}) {
    final cutoff = (now ?? DateTime.now()).subtract(maxAge);
    final dead = <String>[];
    for (final e in _edges.entries) {
      while (e.value.isNotEmpty &&
          e.value.first.timestamp.isBefore(cutoff)) {
        e.value.removeFirst();
      }
      if (e.value.isEmpty) dead.add(e.key);
    }
    for (final k in dead) {
      _edges.remove(k);
    }
  }

  void clear() => _edges.clear();

  /// Step-change detector: median of the last [window] samples vs
  /// median of the [window] samples before them, on SNR (falling
  /// back to RSSI when an edge has no SNR at all).
  ///
  /// Returns the signed step (recent median − prior median, dB) when
  /// both windows are full and |step| >= [minStepDb]; null otherwise
  /// (too few samples, or no step big enough to call out).
  ///
  /// A returned step is an ESTIMATE, consistent with a link being
  /// shadowed or a node moving — it is not proof of a disturbance,
  /// and it must never, on its own, create, delete, or downgrade a
  /// detection.
  double? detectStep(
    int from,
    int to, {
    int window = 5,
    double minStepDb = 3.0,
  }) {
    // FIX (review 2026-11-28, item 3): window < 1 used to throw
    // RangeError from sublist; a public method must return null
    // for a degenerate window instead. A negative or NaN
    // minStepDb is likewise not a usable threshold.
    if (window < 1 || minStepDb.isNaN || minStepDb < 0) return null;
    final series = seriesFor(from, to);
    if (series.length < window * 2) return null;
    List<double> values(MeshLinkSample s) =>
        <double>[if (s.snr != null) s.snr!];
    var vals = series.map(values).toList();
    // Fall back to RSSI only when the edge has no SNR anywhere.
    if (vals.every((v) => v.isEmpty)) {
      vals = series
          .map((s) => <double>[if (s.rssi != null) s.rssi!])
          .toList();
    }
    // Keep only samples that carry the chosen metric, in order.
    // Non-finite values are skipped, never medians-poisoning NaN.
    final xs = <double>[];
    for (final v in vals) {
      if (v.isNotEmpty && v.first.isFinite) xs.add(v.first);
    }
    if (xs.length < window * 2) return null;
    final recent = xs.sublist(xs.length - window);
    final prior = xs.sublist(xs.length - window * 2, xs.length - window);
    final step = _median(recent) - _median(prior);
    if (step.abs() < minStepDb) return null;
    return step;
  }

  static double _median(List<double> xs) {
    final sorted = [...xs]..sort();
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid];
    return (sorted[mid - 1] + sorted[mid]) / 2;
  }
}

/// Latest telemetry utilization per node, fed by the driver's
/// telemetry parsing (portnum 67). Kept separate from the series so
/// a dashboard can read "current ChUtil" without scanning history.
///
/// Bounded (FIX, review 2026-11-28, item 12): at most
/// [maxEntries] nodes are kept; when the cap is hit the stalest
/// entry (oldest `at`) is evicted, and [pruneOlderThan] drops
/// entries older than a caller-supplied age. Previously this map
/// grew by one entry per node number ever seen, with no cap.
class MeshChannelUtilization {
  /// Max nodes kept. Same order as the series edge cap (256).
  static const int maxEntries = 256;

  final Map<int, ({double? chUtil, double? airUtil, DateTime at})> _latest =
      {};

  void record(int nodeNum, double? chUtil, double? airUtil,
      {DateTime? at}) {
    // FIX (re-review item 6): drop non-finite values, like
    // [MeshLinkSeries.record] does. A NaN chUtil stored here flows
    // straight into the guard as observedUtilizationPercent, making
    // maySend compute NaN and refuse forever.
    final cleanChUtil = chUtil?.isFinite == true ? chUtil : null;
    final cleanAirUtil = airUtil?.isFinite == true ? airUtil : null;
    if (cleanChUtil == null && cleanAirUtil == null) return;
    if (!_latest.containsKey(nodeNum) &&
        _latest.length >= maxEntries) {
      // Evict the stalest entry (oldest `at`).
      var stalestKey = _latest.keys.first;
      var stalestAt = _latest[stalestKey]!.at;
      for (final e in _latest.entries) {
        if (e.value.at.isBefore(stalestAt)) {
          stalestKey = e.key;
          stalestAt = e.value.at;
        }
      }
      _latest.remove(stalestKey);
    }
    _latest[nodeNum] = (
      chUtil: cleanChUtil,
      airUtil: cleanAirUtil,
      at: at ?? DateTime.now(),
    );
  }

  /// Drop entries older than [maxAge] relative to [now].
  void pruneOlderThan(Duration maxAge, {DateTime? now}) {
    final cutoff = (now ?? DateTime.now()).subtract(maxAge);
    _latest.removeWhere((_, v) => v.at.isBefore(cutoff));
  }

  /// Number of nodes currently kept.
  int get entryCount => _latest.length;

  ({double? chUtil, double? airUtil, DateTime at})? latest(int nodeNum) =>
      _latest[nodeNum];

  Map<int, ({double? chUtil, double? airUtil, DateTime at})> get all =>
      Map.unmodifiable(_latest);
}
