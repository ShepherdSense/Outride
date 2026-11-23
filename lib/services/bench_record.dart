/// Bench recording — record real field sessions the benches can run
/// on, in the experimental branch only.
///
/// THE CRUX (design §0/§2.5): the in-app tuning recorder
/// (recorder.dart) writes only `t_iso,link_key,from_node,to_node,
/// snr_db` — NO dip_db, NO truth columns — so the B1 harness
/// REJECTS its output. This recorder closes that gap, and a session
/// it writes is directly consumable by the bench harnesses:
///
/// - dip_db: the recorder takes its own vacant-baseline window
///   (first [BenchRecordConfig.baselineSeconds], default 10 s) and
///   records per-link baseline = mean snr over that window; later
///   rows carry dip_db = baseline − snr. Baseline rows carry empty
///   dip_db (the harness treats them as undisturbed). The sidecar
///   records `dip_units` honestly: the app's snr is radio-internal
///   units, not calibrated dB.
/// - truth: operator-declared scripted truth. The session template
///   (empty baseline / moving crossings / move-in-then-stand-still)
///   plus two waypoints (field metres, entered at record time)
///   define the truth path; truth(t) is the linear interpolation
///   along that path over the recording's actual duration. The
///   sidecar records the provenance (`operator-declared scripted
///   walk, linear interpolation by wall time`) so the truth is
///   auditable, never hidden. Empty-baseline sessions carry no truth
///   (no target) — the harness scores nothing on them, which is
///   correct.
/// - node positions: auto-filled from the observed nodes at record
///   start, written to `<session>.meta.json` AND to the B1
///   convention `<session>.nodes.json` sidecar. If the app only sees
///   2 nodes, the session says 2 nodes — never padded to 6.
/// - format: the SAME BenchSession CSV the B1 harness reads
///   (header `t_iso,link_key,from_node,to_node,snr_db,dip_db,
///   truth_x,truth_y,truth_id`), EXTENDED with optional trailing
///   `# SECTION` blocks (csi_summary, trip_events, camera_events,
///   sweep_frames, backhaul) — an old B1 file has no sections and
///   replays exactly as before.
///
/// Rows are buffered in memory and written at stop (truth needs the
/// final duration). A kill mid-recording loses the session instead
/// of writing a half-labelled file — re-record. Sessions live in
/// `bench_sessions/` under the app documents dir, the same directory
/// the Bench screen scans and the harnesses read — so a recorded
/// session can be run on-device immediately.
///
/// Recording never touches live detection, alerting, tripwire, or
/// fleet paths: it only observes the same sample stream the live
/// pipeline already sees.
library;

import 'dart:convert';
import 'dart:io';

import '../models/link_sample.dart';
import '../models/sensor_observation.dart';
import '../models/spectrum_sweep.dart';
import '../models/tracking.dart';
import 'bench_csi.dart' show defaultCsiSessionsDirName;
import 'experimental_build.dart';
import 'fusion_bench_harness.dart' show defaultSessionsDirName;
import 'sensor_protocol.dart' show CsiObservation;

/// Session templates — the Nov 2–4 capture shapes, selectable at
/// record time.
enum BenchSessionTemplate {
  /// Vacant area, no target. Truth: none. Serves baselines.
  emptyBaseline,

  /// Operator walks waypoint A → B across the recording. Truth:
  /// linear interpolation A→B over the recording duration.
  movingCrossings,

  /// Operator walks A → B in the first third, then stands at B.
  /// Truth: lerp A→B over the first third, then B.
  moveInStandStill,
}

extension BenchSessionTemplateLabel on BenchSessionTemplate {
  String get label => switch (this) {
        BenchSessionTemplate.emptyBaseline => 'Empty baseline',
        BenchSessionTemplate.movingCrossings => 'Moving crossings',
        BenchSessionTemplate.moveInStandStill =>
          'Move in, then stand still',
      };

  /// Bench IDs this template's sessions can serve.
  List<String> get benchesServed => switch (this) {
        BenchSessionTemplate.emptyBaseline => ['B1', 'B4', 'B5', 'B14'],
        BenchSessionTemplate.movingCrossings => [
            'B1',
            'B4',
            'B5',
            'B9',
            'B10',
            'B11',
            'B14',
          ],
        BenchSessionTemplate.moveInStandStill => [
            'B1',
            'B4',
            'B5',
            'B9',
            'B10',
            'B11',
            'B14',
          ],
      };
}

/// Configuration for one bench recording, filled in by the Bench
/// screen's Record section (or by a feed record_start command).
class BenchRecordConfig {
  const BenchRecordConfig({
    required this.template,
    this.label = '',
    this.notes = '',
    this.waypointA,
    this.waypointB,
    this.baselineSeconds = 10,
    this.illuminatorBand = '',
  });

  final BenchSessionTemplate template;

  /// Operator's label for the session.
  final String label;

  /// Free-text geometry notes.
  final String notes;

  /// Waypoint A (field metres, x/y). Required for the moving
  /// templates; ignored for empty baseline.
  final (double, double)? waypointA;

  /// Waypoint B (field metres, x/y).
  final (double, double)? waypointB;

  /// Leading vacant-baseline window, seconds.
  final int baselineSeconds;

  /// Illuminator band for B19 sessions (e.g. `3.44 GHz 5G`), else ''.
  final String illuminatorBand;

  /// True when the config can produce truth (moving templates with
  /// both waypoints). Without truth the session still records — the
  /// harness simply scores nothing on it.
  bool get hasTruth =>
      template != BenchSessionTemplate.emptyBaseline &&
      waypointA != null &&
      waypointB != null;

  String? get validationError {
    if (template != BenchSessionTemplate.emptyBaseline &&
        (waypointA == null || waypointB == null)) {
      return 'moving templates need both waypoints (A and B) for truth';
    }
    if (baselineSeconds < 5) {
      return 'baseline window must be at least 5 s';
    }
    return null;
  }
}

/// One buffered link row (truth filled in at stop).
class _LinkRow {
  _LinkRow({
    required this.t,
    required this.linkKey,
    required this.fromNode,
    required this.toNode,
    required this.snrDb,
    required this.dipDb,
  });

  final DateTime t;
  final String linkKey;
  final String fromNode;
  final String toNode;
  final double snrDb;
  final double? dipDb;
}

/// Bench recorder: buffers one session, writes it at stop.
class BenchRecorder {
  bool get isRecording => _startedAt != null;

  int get rows => _linkRows.length;

  String? get currentPath => _file?.path;

  DateTime? get startedAt => _startedAt;

  BenchRecordConfig? get config => _config;

  String? get lastError => _lastError;

  DateTime? _startedAt;
  BenchRecordConfig? _config;
  File? _file;
  File? _metaFile;
  Map<String, NodePosition> _nodes = {};
  final List<_LinkRow> _linkRows = [];
  final Map<String, List<double>> _baselineSnr = {};
  final List<Map<String, String>> _csiSummary = [];
  final List<Map<String, String>> _tripEvents = [];
  final List<Map<String, String>> _cameraEvents = [];
  final List<Map<String, String>> _sweepFrames = [];
  String? _lastError;

  /// Start a bench recording. Returns the session file path, or ''
  /// on failure (check [lastError]). Never throws.
  Future<String> start(
    BenchRecordConfig config,
    Map<String, NodePosition> nodes,
    Directory docsDir,
  ) async {
    if (isRecording) return _file?.path ?? '';
    final err = config.validationError;
    if (err != null) {
      _lastError = err;
      return '';
    }
    try {
      final dir = Directory('${docsDir.path}/$defaultSessionsDirName');
      if (!await dir.exists()) await dir.create(recursive: true);
      final stamp =
          DateTime.now().toIso8601String().replaceAll(':', '-');
      final name = 'bench_${config.template.name}_$stamp.csv';
      _file = File('${dir.path}/$name');
      _metaFile = File('${dir.path}/$name'.replaceAll('.csv', '.meta.json'));
      _config = config;
      _nodes = Map.of(nodes);
      _startedAt = DateTime.now();
      _linkRows.clear();
      _baselineSnr.clear();
      _csiSummary.clear();
      _tripEvents.clear();
      _cameraEvents.clear();
      _sweepFrames.clear();
      _lastError = null;
      return _file!.path;
    } catch (e) {
      _lastError = 'bench recording start failed: $e';
      return '';
    }
  }

  /// Record one raw link sample (same stream the live pipeline sees).
  /// During the baseline window the sample feeds the per-link
  /// baseline; after it, dip_db = baseline − snr.
  void recordLink(LinkSample raw) {
    if (!isRecording) return;
    final snr = raw.snr;
    if (snr == null || !snr.isFinite) return;
    final elapsed =
        DateTime.now().difference(_startedAt!).inMicroseconds / 1e6;
    final baseline = _config!.baselineSeconds;
    double? dip;
    if (elapsed < baseline) {
      (_baselineSnr[raw.linkKey] ??= []).add(snr);
    } else {
      final base = _baselineSnr[raw.linkKey];
      if (base != null && base.isNotEmpty) {
        final mean = base.fold(0.0, (a, b) => a + b) / base.length;
        dip = mean - snr;
      }
    }
    _linkRows.add(_LinkRow(
      t: raw.timestamp,
      linkKey: raw.linkKey,
      fromNode: raw.fromNode,
      toNode: raw.toNode,
      snrDb: snr,
      dipDb: dip,
    ));
  }

  /// Record one aggregated CSI motion observation (UDP 49160 CSI
  /// verb: 1 s devHz aggregate — NOT per-subcarrier data; see the
  /// `csi_summary` section note in the file footer).
  void recordCsi(CsiObservation o) {
    if (!isRecording) return;
    _csiSummary.add({
      't_iso': o.timestamp.toIso8601String(),
      'sensor_id': o.sensorId,
      'dev_hz': o.devHz.toStringAsFixed(3),
      'pairs_active': '${o.pairsActive ?? ''}',
      'link': o.link ?? '',
    });
  }

  /// Record one trip event (B17 trip data: timestamp + link context).
  void recordTrip(CrossingEvent e) {
    if (!isRecording) return;
    _tripEvents.add({
      't_iso': e.timestamp.toIso8601String(),
      'event': 'trip',
      'link_key': e.linkKey,
      'dip_depth': e.dipDepth.toStringAsFixed(2),
      'duration_s': e.durationSecs.toStringAsFixed(2),
      'size_estimate': e.sizeEstimate,
      'direction': e.direction,
      'ai_label': e.aiLabel ?? '',
    });
  }

  /// Record one camera motion observation (B18 confirm-tier context).
  /// No detector boxes exist in the app — the row carries the motion
  /// event + snapshot ref only; see the section note in the file.
  void recordCamera(SensorObservation o) {
    if (!isRecording) return;
    _cameraEvents.add({
      't_iso': o.timestamp.toIso8601String(),
      'camera': o.sensorId,
      'zone': o.zone ?? '',
      'label': o.zoneLabel ?? '',
      'snapshot_ref': o.snapshotRef ?? '',
    });
  }

  /// Record one SDR sweep step's peak (B13/B19 context: band-energy
  /// peaks, NOT range–Doppler — the bridge ships energy, not IQ).
  void recordSweep(SweepStep s) {
    if (!isRecording) return;
    final peak = s.peaks.isEmpty
        ? null
        : s.peaks.reduce((a, b) => a.dbfs > b.dbfs ? a : b);
    _sweepFrames.add({
      't_iso': s.receivedAt.toIso8601String(),
      'center_mhz': s.centerMhz.toStringAsFixed(2),
      'span_mhz': s.spanMhz.toStringAsFixed(2),
      'energy_dbfs': s.energyDbfs.toStringAsFixed(1),
      'peak_mhz': peak == null ? '' : peak.freqMhz.toStringAsFixed(2),
      'peak_dbfs': peak == null ? '' : peak.dbfs.toStringAsFixed(1),
      'radio': s.radio,
    });
  }

  /// Stop, write the session file + sidecars, return a summary.
  /// Never throws — failures surface in the returned string and
  /// [lastError].
  Future<String> stop() async {
    final file = _file;
    final started = _startedAt;
    final config = _config;
    if (file == null || started == null || config == null) {
      return 'NOT RECORDING';
    }
    final stopped = DateTime.now();
    final durationS =
        stopped.difference(started).inMicroseconds / 1e6;
    try {
      final buf = StringBuffer();
      buf.writeln(
          't_iso,link_key,from_node,to_node,snr_db,dip_db,truth_x,truth_y,truth_id');
      for (final r in _linkRows) {
        final (tx, ty, tid) = _truthAt(r.t, started, durationS, config);
        buf.writeln('${r.t.toIso8601String()},'
            '"${r.linkKey}","${r.fromNode}","${r.toNode}",'
            '${r.snrDb.toStringAsFixed(3)},'
            '${r.dipDb == null ? '' : r.dipDb!.toStringAsFixed(3)},'
            '${tx == null ? '' : tx.toStringAsFixed(3)},'
            '${ty == null ? '' : ty.toStringAsFixed(3)},'
            '${tid ?? ''}');
      }
      _writeSection(buf, 'csi_summary',
          ['t_iso', 'sensor_id', 'dev_hz', 'pairs_active', 'link'],
          _csiSummary,
          note: 'Aggregated CSI motion observations from the UDP 49160 '
              'CSI verb (1 s devHz aggregates). NOT per-subcarrier '
              'amp/phase — this section NEVER feeds the B7/B12/B-W '
              'benches; those need externally recorded CSI CSVs in '
              '$defaultCsiSessionsDirName/.');
      _writeSection(buf, 'trip_events',
          ['t_iso', 'event', 'link_key', 'dip_depth', 'duration_s',
            'size_estimate', 'direction', 'ai_label'],
          _tripEvents);
      _writeSection(buf, 'camera_events',
          ['t_iso', 'camera', 'zone', 'label', 'snapshot_ref'],
          _cameraEvents,
          note: 'Confirm-tier motion events only. No detector boxes '
              'exist in the app, so no boxes are recorded — stills '
              'only, via snapshot_ref when the camera is configured.');
      _writeSection(buf, 'sweep_frames',
          ['t_iso', 'center_mhz', 'span_mhz', 'energy_dbfs', 'peak_mhz',
            'peak_dbfs', 'radio'],
          _sweepFrames,
          note: 'SDR-bridge band-energy peaks (UDP 49161). Energy only, '
              'never range–Doppler — the bridge ships no IQ, so B13/B19 '
              'cannot run on these rows.');
      _writeSection(buf, 'backhaul',
          ['t_iso', 'node', 'uplinks_seen', 'gap_max_s', 'median_gap_s',
            'missing_rate'],
          _backhaulRows(stopped),
          note: 'Per-node uplink-gap summary computed from the recorded '
              'link-sample timestamps at stop. Serves B3/B15 observably; '
              'the jammer-bench side is bench setup, not app work.');
      await file.writeAsString(buf.toString());
      // Sidecars: meta.json (full provenance) + nodes.json (the B1
      // convention for node geometry).
      final meta = {
        'version': kExperimentalVersion,
        'template': config.template.name,
        'label': config.label,
        'notes': config.notes,
        'benches_served': config.template.benchesServed,
        'started_at': started.toIso8601String(),
        'stopped_at': stopped.toIso8601String(),
        'duration_s': durationS,
        'rows': _linkRows.length,
        'nodes': [
          for (final n in _nodes.values)
            {
              'node_id': n.nodeId,
              'x': n.x,
              'y': n.y,
              'height': n.height,
            },
        ],
        'waypoint_a': config.waypointA == null
            ? null
            : [config.waypointA!.$1, config.waypointA!.$2],
        'waypoint_b': config.waypointB == null
            ? null
            : [config.waypointB!.$1, config.waypointB!.$2],
        'baseline_s': config.baselineSeconds,
        'dip_units':
            'snr units (baseline mean snr minus snr), not calibrated dB',
        'truth_provenance': config.hasTruth
            ? 'operator-declared scripted walk: waypoints A/B entered at '
                'record time, truth = linear interpolation by wall time '
                'over the recording duration'
            : 'no truth: ${config.template == BenchSessionTemplate.emptyBaseline ? 'empty-baseline session, no target' : 'waypoints missing'}',
        'illuminator_band': config.illuminatorBand,
        'sections': {
          'csi_summary': _csiSummary.length,
          'trip_events': _tripEvents.length,
          'camera_events': _cameraEvents.length,
          'sweep_frames': _sweepFrames.length,
          'backhaul': _nodes.length,
        },
      };
      await _metaFile!.writeAsString(
          const JsonEncoder.withIndent('  ').convert(meta));
      final nodesFile = File(
          file.path.replaceAll('.csv', '.nodes.json'));
      await nodesFile.writeAsString(const JsonEncoder.withIndent('  ')
          .convert({
        'nodes': meta['nodes'],
      }));
      final summary =
          '${_linkRows.length} rows, ${durationS.toStringAsFixed(1)}s, '
          '${_nodes.length} node(s) → ${file.path}';
      _reset();
      _lastError = null;
      return summary;
    } catch (e) {
      _lastError = 'bench recording stop failed: $e';
      _reset();
      return 'STOP FAILED: $_lastError';
    }
  }

  /// Truth for row time [t], from the template + waypoints over the
  /// recording's actual [durationS]. Empty for baseline sessions.
  (double?, double?, String?) _truthAt(DateTime t, DateTime started,
      double durationS, BenchRecordConfig config) {
    if (!config.hasTruth || durationS <= 0) return (null, null, null);
    final a = config.waypointA!;
    final b = config.waypointB!;
    final frac = (t.difference(started).inMicroseconds / 1e6) /
        durationS;
    final f = frac.clamp(0.0, 1.0);
    switch (config.template) {
      case BenchSessionTemplate.emptyBaseline:
        return (null, null, null);
      case BenchSessionTemplate.movingCrossings:
        return (
          a.$1 + (b.$1 - a.$1) * f,
          a.$2 + (b.$2 - a.$2) * f,
          'walk',
        );
      case BenchSessionTemplate.moveInStandStill:
        final wf = f < 1 / 3 ? f * 3 : 1.0;
        return (
          a.$1 + (b.$1 - a.$1) * wf,
          a.$2 + (b.$2 - a.$2) * wf,
          'walk',
        );
    }
  }

  void _writeSection(
    StringBuffer buf,
    String name,
    List<String> columns,
    List<Map<String, String>> rows, {
    String? note,
  }) {
    buf.writeln('# SECTION $name');
    if (note != null) buf.writeln('# $note');
    buf.writeln(columns.join(','));
    for (final r in rows) {
      buf.writeln([for (final c in columns) r[c] ?? ''].join(','));
    }
  }

  /// Per-node uplink-gap summary from the buffered link rows.
  List<Map<String, String>> _backhaulRows(DateTime stopped) {
    final byNode = <String, List<DateTime>>{};
    for (final r in _linkRows) {
      for (final n in [r.fromNode, r.toNode]) {
        (byNode[n] ??= []).add(r.t);
      }
    }
    final out = <Map<String, String>>[];
    for (final e in byNode.entries) {
      final times = e.value..sort();
      final gaps = <double>[];
      for (var i = 1; i < times.length; i++) {
        gaps.add(
            times[i].difference(times[i - 1]).inMicroseconds / 1e6);
      }
      gaps.sort();
      final medianGap =
          gaps.isEmpty ? 0.0 : gaps[gaps.length ~/ 2];
      final maxGap = gaps.isEmpty ? 0.0 : gaps.last;
      final missing = medianGap > 0
          ? gaps.where((g) => g > 2 * medianGap).length /
              gaps.length
          : 0.0;
      out.add({
        't_iso': stopped.toIso8601String(),
        'node': e.key,
        'uplinks_seen': '${times.length}',
        'gap_max_s': maxGap.toStringAsFixed(2),
        'median_gap_s': medianGap.toStringAsFixed(2),
        'missing_rate': missing.toStringAsFixed(3),
      });
    }
    return out;
  }

  void _reset() {
    _startedAt = null;
    _config = null;
    _file = null;
    _metaFile = null;
    _nodes = {};
    _linkRows.clear();
    _baselineSnr.clear();
    _csiSummary.clear();
    _tripEvents.clear();
    _cameraEvents.clear();
    _sweepFrames.clear();
  }

  /// List recorded bench sessions (bench_sessions/*.csv), newest
  /// first. Never throws.
  static Future<List<File>> listBenchSessions(Directory docsDir) async {
    try {
      final dir = Directory('${docsDir.path}/$defaultSessionsDirName');
      if (!await dir.exists()) return [];
      final files = await dir
          .list()
          .where((e) => e is File && e.path.endsWith('.csv'))
          .cast<File>()
          .toList();
      files.sort((a, b) => b.path.compareTo(a.path));
      return files;
    } catch (_) {
      return [];
    }
  }

  /// Node positions for a session, from its `<session>.meta.json`
  /// sidecar (falling back to `<session>.nodes.json`). Empty when
  /// neither sidecar exists — the runner then reports the session
  /// as missing geometry instead of scoring it.
  static Map<String, NodePosition> loadBenchNodes(
      Directory sessionsDir, String sessionName) {
    for (final suffix in ['.meta.json', '.nodes.json']) {
      final f = File(
          '${sessionsDir.path}/${sessionName.replaceAll('.csv', suffix)}');
      if (!f.existsSync()) continue;
      try {
        final j =
            jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        final nodes = j['nodes'] as List?;
        if (nodes == null) continue;
        final out = <String, NodePosition>{};
        for (final n in nodes) {
          final m = n as Map<String, dynamic>;
          final id = '${m['node_id'] ?? ''}';
          if (id.isEmpty) continue;
          out[id] = NodePosition(
            nodeId: id,
            x: (m['x'] as num).toDouble(),
            y: (m['y'] as num).toDouble(),
            height: (m['height'] as num?)?.toDouble() ?? 0.0,
          );
        }
        return out;
      } catch (_) {
        continue;
      }
    }
    return {};
  }
}
