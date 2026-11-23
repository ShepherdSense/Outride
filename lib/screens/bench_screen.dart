/// Bench screen — the experimental measurement-bench area.
///
/// One screen, no new tab. Reachable ONLY from the Sensors Bench row
/// (gated by the same "Experimental sensors" toggle as Fetch /
/// Spectrum). Renders FROM the registry (bench_registry.dart); no
/// bench metadata is hard-coded here.
///
/// Rules (design §2): benches read files and compute — they never
/// touch the live tracker, tripwire, alerts, or fleet. Nothing runs
/// on synthetic data. No auto-run on screen open (opening scans
/// directories and reports counts — a scan is not a run). Results
/// are NOT persisted across restarts. QUEUED-BLOCKED rows have NO
/// Run button. The B3 fleet-health panel lives here as "fleet health
/// (B3 pending)" with Health `unreadable` — never a green Health
/// cell with no scorer behind it.
///
/// The Record section at the top is the bench-recording UI
/// (bench_record.dart): record start/stop + session labeling +
/// export (files live in the app documents dir under
/// bench_sessions/, listed in-app with paths). On the web build the
/// record commands go through the feed connection to the ingesting
/// device, and recorded files land ON THAT DEVICE — the browser
/// never holds the recording.
///
/// The Live feed section (web build) connects this app as a CLIENT
/// to one mesh node's feed server. The web app never joins the mesh
/// and is never a mesh node.
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../models/tracking.dart';
import '../services/bench_acm.dart';
import '../services/bench_association_multi.dart';
import '../services/bench_b1_refinements.dart';
import '../services/bench_ci_arms.dart';
import '../services/bench_csi.dart';
import '../services/bench_csi_presence.dart';
import '../services/bench_csi_typing.dart';
import '../services/bench_detector_rt.dart';
import '../services/bench_kld.dart';
import '../services/bench_record.dart';
import '../services/bench_registry.dart';
import '../services/bench_replay.dart';
import '../services/bench_run.dart';
import '../services/bench_status.dart';
import '../services/feed_client.dart';
import '../services/fusion_bench_harness.dart';
import '../state/app_state.dart';
import '../theme.dart';

/// Bench screen: header + live feed + record + B3 panel + registry.
class BenchScreen extends StatefulWidget {
  const BenchScreen({super.key, required this.state});

  final AppState state;

  @override
  State<BenchScreen> createState() => _BenchScreenState();
}

class _BenchScreenState extends State<BenchScreen> {
  /// Results by registry id (B5 arms share the 'B5' key).
  final Map<String, BenchOutcome> _results = {};

  /// Extra refinement lines for the B1 row.
  List<String> _b1Extra = [];

  /// Run-all summary line, or null before any run.
  String? _runAllSummary;

  /// Live input summary counts.
  ({
    int rfSessions,
    int rfRejected,
    int csiSessions,
    int csiRejected,
  })? _inputs;

  /// Recorded session files (bench_sessions/*.csv), newest first.
  List<File> _recordedFiles = [];

  /// Record form state.
  BenchSessionTemplate _template = BenchSessionTemplate.movingCrossings;
  final TextEditingController _label = TextEditingController();
  final TextEditingController _notes = TextEditingController();
  final TextEditingController _wayAx = TextEditingController(text: '0');
  final TextEditingController _wayAy = TextEditingController(text: '0');
  final TextEditingController _wayBx = TextEditingController(text: '10');
  final TextEditingController _wayBy = TextEditingController(text: '0');
  final TextEditingController _baseline =
      TextEditingController(text: '10');
  final TextEditingController _illuminator = TextEditingController();
  String? _recordMessage;

  /// Feed connect form state (web build).
  final TextEditingController _feedHost =
      TextEditingController(text: '192.168.1.10:49163');

  @override
  void initState() {
    super.initState();
    _refreshInputs();
  }

  @override
  void dispose() {
    _label.dispose();
    _notes.dispose();
    _wayAx.dispose();
    _wayAy.dispose();
    _wayBx.dispose();
    _wayBy.dispose();
    _baseline.dispose();
    _illuminator.dispose();
    _feedHost.dispose();
    super.dispose();
  }

  Future<void> _refreshInputs() async {
    try {
      final inputs = await scanBenchInputs();
      final docs = await getApplicationDocumentsDirectory();
      final files = await BenchRecorder.listBenchSessions(docs);
      await refreshBenchReadiness();
      if (!mounted) return;
      setState(() {
        _inputs = inputs;
        _recordedFiles = files;
      });
    } catch (_) {
      // No documents dir (e.g. widget tests without path_provider):
      // the screen still renders, inputs read empty.
    }
  }

  // --- Harness dispatch ---------------------------------------------------

  Future<BenchConfig> _rfConfig() async {
    final dir = await benchSessionsDir();
    final load = loadSessions(dir);
    final nodes = <String, NodePosition>{};
    for (final s in load.sessions) {
      nodes.addAll(BenchRecorder.loadBenchNodes(dir, s.name));
    }
    return BenchConfig(sessionsDir: dir, nodes: nodes);
  }

  /// A no-geometry guard: RF harnesses cannot replay a session whose
  /// node positions are unknown. Report it as a skip with the reason
  /// stated, never as a scored FAIL.
  BenchOutcome? _noGeometry(BenchConfig config) {
    if (config.nodes.isEmpty) {
      return const BenchOutcome(
        skipped: true,
        skipReason: kBenchPending,
        rejected: {
          '(nodes)': 'no node geometry — <session>.meta.json missing',
        },
      );
    }
    return null;
  }

  Future<BenchOutcome> _runHarness(String harness) async {
    switch (harness) {
      case BenchHarness.b1:
        final config = await _rfConfig();
        final noGeo = _noGeometry(config);
        if (noGeo != null) return noGeo;
        final outcome = runFusionBench(config);
        if (!outcome.skipped) {
          // B1 refinements (Rønning k_pair + Forsling λ_min/λ_max):
          // computed on the same replay, shown as extra lines.
          final polls = replayAll(loadRfSessions(config.sessionsDir),
              config);
          final errs = normalizedErrors(polls, 'ICI/metropolis');
          final (lambdaMin: lmin, lambdaMax: lmax) =
              neesEigenvalues(errs);
          final logScore = gaussianLogScore(polls, 'ICI/metropolis');
          final boot = bootstrapRmse(polls, 'ICI/metropolis');
          final k = inflationK(errs);
          _b1Extra = [
            'median NEES ${medianNees(errs).toStringAsFixed(3)} '
                '(k_pair inflation k ${k.isFinite ? k.toStringAsFixed(3) : 'N/A'} — '
                'no Stone Soup reference CSV, so the k_pair cross-check '
                'is PENDING)',
            'Gaussian log score ${logScore.total.isFinite ? logScore.total.toStringAsFixed(3) : 'N/A'} '
                '(NEES term ${logScore.neesTerm.isFinite ? logScore.neesTerm.toStringAsFixed(3) : 'N/A'} + '
                'log-det term ${logScore.logDetTerm.isFinite ? logScore.logDetTerm.toStringAsFixed(3) : 'N/A'})',
            'λ_min(Ξ̂) ${lmin.isFinite ? lmin.toStringAsFixed(3) : 'N/A'} · '
                'λ_max(Ξ̂) ${lmax.isFinite ? lmax.toStringAsFixed(3) : 'N/A'} '
                '(no Wishart bound applied — eigenvalues reported raw; '
                'scalar NEES alone is not the verdict)',
            'ICI RMSE ${boot.rmse.isFinite ? boot.rmse.toStringAsFixed(3) : 'N/A'} m '
                '(block-bootstrap 95% [${boot.low.isFinite ? boot.low.toStringAsFixed(3) : 'N/A'}, '
                '${boot.high.isFinite ? boot.high.toStringAsFixed(3) : 'N/A'}])',
          ];
        }
        return outcome;
      case BenchHarness.b4:
        final config = await _rfConfig();
        return _noGeometry(config) ?? runReplayBench(config);
      case BenchHarness.b5:
        final config = await _rfConfig();
        return _noGeometry(config) ?? runCiArmsBench(config);
      case BenchHarness.b7:
        return runCsiTypingBench(await csiSessionsDir());
      case BenchHarness.b9:
        final config = await _rfConfig();
        return _noGeometry(config) ?? runAssociationMultiBench(config);
      case BenchHarness.b10:
        final config = await _rfConfig();
        return _noGeometry(config) ?? runDetectorBench(config);
      case BenchHarness.b11:
        final config = await _rfConfig();
        return _noGeometry(config) ?? runAcmBench(config);
      case BenchHarness.b12:
        return runCsiFeatureBench(await csiSessionsDir());
      case BenchHarness.b14:
        final config = await _rfConfig();
        return _noGeometry(config) ?? runKldBench(config);
      case BenchHarness.bw1:
        return runSplitNodePresenceBench(await csiSessionsDir());
      case BenchHarness.bw2:
        return runSingleBoardMotionBench(await csiSessionsDir());
      case BenchHarness.bw3:
        return runPhaseVarianceBench(await csiSessionsDir());
      case BenchHarness.bw4:
        return runBreathingBench(await csiSessionsDir());
      default:
        return const BenchOutcome(
          skipped: true,
          skipReason: kBenchPending,
        );
    }
  }

  Future<void> _runOne(BenchEntry entry) async {
    final key = entry.group != null ? entry.group! : entry.id;
    final outcome = await _runHarness(entry.harness!);
    if (!mounted) return;
    setState(() => _results[key] = outcome);
    await _refreshInputs();
  }

  Future<void> _runAll() async {
    var pass = 0, fail = 0, pending = 0;
    var blocked = 0;
    for (final entry in benchRegistry) {
      if (entry.kind == BenchVerdictKind.queuedBlocked) {
        blocked++;
        continue;
      }
      if (entry.group != null &&
          _results.containsKey(entry.group!)) {
        continue; // B5 arms run together, once.
      }
      final outcome = await _runHarness(entry.harness!);
      if (!mounted) return;
      final key = entry.group != null ? entry.group! : entry.id;
      _results[key] = outcome;
      if (outcome.skipped) {
        pending++;
      } else if (outcome.allPassed) {
        pass++;
      } else {
        fail++;
      }
    }
    if (!mounted) return;
    setState(() {
      _runAllSummary = '$pass pass / $fail fail / $pending pending / '
          '$blocked blocked';
    });
    await _refreshInputs();
  }

  // --- Record ---------------------------------------------------------------

  BenchRecordConfig? _recordConfigFromForm() {
    (double, double)? point(TextEditingController x,
        TextEditingController y) {
      final px = double.tryParse(x.text.trim());
      final py = double.tryParse(y.text.trim());
      if (px == null || py == null) return null;
      return (px, py);
    }

    return BenchRecordConfig(
      template: _template,
      label: _label.text.trim(),
      notes: _notes.text.trim(),
      waypointA: point(_wayAx, _wayAy),
      waypointB: point(_wayBx, _wayBy),
      baselineSeconds: int.tryParse(_baseline.text.trim()) ?? 10,
      illuminatorBand: _illuminator.text.trim(),
    );
  }

  Future<void> _startRecording() async {
    final config = _recordConfigFromForm();
    if (config == null) return;
    if (kIsWeb) {
      // Web build: the command goes through the feed connection to
      // the ingesting device; the file lands ON THAT DEVICE.
      final client = widget.state.feedClient;
      if (!client.isConnected) {
        setState(() => _recordMessage =
            'Not connected to a feed source — connect first.');
        return;
      }
      final res = await client.sendRecordStart({
        'template': config.template.name,
        'label': config.label,
        'notes': config.notes,
        'waypoint_a': config.waypointA == null
            ? null
            : [config.waypointA!.$1, config.waypointA!.$2],
        'waypoint_b': config.waypointB == null
            ? null
            : [config.waypointB!.$1, config.waypointB!.$2],
        'baseline_s': config.baselineSeconds,
        'illuminator_band': config.illuminatorBand,
      });
      if (!mounted) return;
      setState(() => _recordMessage = res['ok'] == true
          ? 'Recording on ${client.connectedTo}: ${res['summary']}'
          : 'Record start failed: ${res['summary']}');
      return;
    }
    final err = config.validationError;
    if (err != null) {
      setState(() => _recordMessage = err);
      return;
    }
    final res = await widget.state.startBenchRecording(config);
    if (!mounted) return;
    setState(() => _recordMessage =
        res.startsWith('ERROR') ? res : 'Recording → $res');
    await _refreshInputs();
  }

  Future<void> _stopRecording() async {
    String res;
    if (kIsWeb) {
      final client = widget.state.feedClient;
      final r = await client.sendRecordStop();
      res = r['ok'] == true
          ? '${r['summary']}'
          : 'Stop failed: ${r['summary']}';
    } else {
      res = await widget.state.stopBenchRecording();
    }
    if (!mounted) return;
    setState(() => _recordMessage = res);
    await _refreshInputs();
  }

  // --- Build ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final inputs = _inputs;
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
      children: [
        const Text('BENCH — EXPERIMENTAL / UNTESTED',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
              color: OutrideColors.dim,
            )),
        const SizedBox(height: 4),
        const Text(
          'Measurement benches only. Nothing here affects live detection, '
          'alerting, or the fleet. A bench runs ONLY on recorded data '
          'copied into this build; with no input it reports "measurement '
          'pending — no recorded data" and measures nothing. No synthetic '
          'data is ever used. Paper numbers are the papers\' numbers, '
          'never Outride results, until a bench passes on our data.',
          style: TextStyle(
              fontSize: 13, color: OutrideColors.faint, height: 1.45),
        ),
        const SizedBox(height: 8),
        Text(
          inputs == null
              ? 'Scanning inputs…'
              : 'Sessions: ${inputs.rfSessions} RF-track CSVs in '
                  'bench_sessions/ (${inputs.rfRejected} rejected) · '
                  '${inputs.csiSessions} CSI CSVs in csi_sessions/ '
                  '(${inputs.csiRejected} rejected) · 0 camera sessions: '
                  'none',
          style: const TextStyle(
              fontSize: 13, color: OutrideColors.faint, height: 1.45),
        ),
        const SizedBox(height: 12),
        _liveFeedPanel(),
        const SizedBox(height: 12),
        _recordPanel(),
        const SizedBox(height: 12),
        _fleetHealthPanel(),
        const SizedBox(height: 12),
        Row(
          children: [
            ElevatedButton(
              onPressed: _runAll,
              child: const Text('RUN ALL'),
            ),
            const SizedBox(width: 12),
            if (_runAllSummary != null)
              Expanded(
                child: Text(_runAllSummary!,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: OutrideColors.dim)),
              ),
          ],
        ),
        const SizedBox(height: 12),
        ..._registryRows(),
      ],
    );
  }

  /// Live feed panel. Web: connect-to-one-node client flow. Native:
  /// feed-server status (this node serves the web build).
  Widget _liveFeedPanel() {
    if (!kIsWeb) {
      return OutridePanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text('LIVE FEED — THIS NODE SERVES',
                      style: OutrideType.section(),
                      overflow: TextOverflow.ellipsis),
                ),
                const Spacer(),
                OutrideChip(
                  label: widget.state.feedServer.isServing
                      ? 'SERVING'
                      : 'OFF',
                  color: widget.state.feedServer.isServing
                      ? OutrideColors.green
                      : OutrideColors.muted,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Feed server: ${widget.state.feedServerStatus}. The web '
              'build connects to this node as a client (ws://<this-node>'
              ':49163/feed) and views/controls/records through it. The '
              'mesh is untouched — this node still meshes with the other '
              'EUDs over internal Wi-Fi; the web app never joins the mesh.',
              style: OutrideType.section(11).copyWith(height: 1.6),
            ),
          ],
        ),
      );
    }
    return ListenableBuilder(
      listenable: widget.state.feedClient,
      builder: (context, _) {
        final client = widget.state.feedClient;
        final snap = client.latestSnapshot;
        final links = (snap?['links'] as List?) ?? [];
        return OutridePanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text('LIVE FEED — CONNECT TO ONE NODE',
                        style: OutrideType.section(),
                        overflow: TextOverflow.ellipsis),
                  ),
                  const Spacer(),
                  OutrideChip(
                    label: switch (client.state) {
                      FeedState.connected => 'CONNECTED',
                      FeedState.connecting => 'CONNECTING',
                      FeedState.unreachable => 'UNREACHABLE',
                      FeedState.disconnected => 'NOT CONNECTED',
                    },
                    color: client.state == FeedState.connected
                        ? OutrideColors.green
                        : client.state == FeedState.unreachable
                            ? OutrideColors.red
                            : OutrideColors.amber,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'This web app is a CLIENT: it connects to one mesh node '
                '(or the hub) and views/controls/records through it. It '
                'does NOT join the mesh and is NOT a mesh node — a browser '
                'cannot do multicast/UDP peer discovery. The mesh works '
                'unchanged underneath.',
                style: OutrideType.section(11).copyWith(height: 1.6),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _feedHost,
                      decoration: const InputDecoration(
                        labelText: 'NODE HOST:PORT',
                        hintText: '192.168.1.10:49163',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: client.state == FeedState.connecting
                        ? null
                        : () async {
                            if (client.isConnected) {
                              await client.disconnect();
                            } else {
                              await client
                                  .connect(_feedHost.text.trim());
                            }
                            if (mounted) setState(() {});
                          },
                    child: Text(
                        client.isConnected ? 'DISCONNECT' : 'CONNECT'),
                  ),
                ],
              ),
              if (client.state == FeedState.unreachable) ...[
                const SizedBox(height: 8),
                Text(
                  'NO FEED SOURCE REACHABLE — ${client.lastError ?? 'unknown reason'}. '
                  'Nothing below is live data.',
                  style: OutrideType.section(12).copyWith(
                      color: OutrideColors.red, height: 1.5),
                ),
              ],
              if (client.isConnected) ...[
                const SizedBox(height: 8),
                Text(
                  'Live from ${client.connectedTo} — '
                  '${links.length} link(s), '
                  '${snap?['nodes'] ?? '?'} node(s), '
                  'mode: ${snap?['mode'] ?? '?'}',
                  style: OutrideType.section(12).copyWith(height: 1.5),
                ),
                for (final link in links.take(8))
                  Text(
                    '${link['link_key']}: snr ${link['snr_db']} · '
                    'dip ${link['dip_db']}',
                    style: OutrideType.section(11)
                        .copyWith(height: 1.5),
                  ),
              ],
              if (client.state == FeedState.disconnected) ...[
                const SizedBox(height: 8),
                Text(
                  'Not connected. Enter the node\'s LAN address and tap '
                  'CONNECT. Simulated mode is OFF unless you turn it on '
                  'explicitly in Settings — this build never falls back '
                  'to simulated data silently.',
                  style: OutrideType.section(11).copyWith(height: 1.6),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  /// Record section: template + labeling + start/stop + file list.
  Widget _recordPanel() {
    final recording = widget.state.benchRecorder.isRecording;
    const isWeb = kIsWeb;
    return OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text('RECORD — FIELD SESSIONS FOR THE BENCHES',
                    style: OutrideType.section(),
                    overflow: TextOverflow.ellipsis),
              ),
              const Spacer(),
              OutrideChip(
                label: recording ? 'RECORDING' : 'IDLE',
                color: recording
                    ? OutrideColors.red
                    : OutrideColors.muted,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            isWeb
                ? 'Record commands go through the feed connection to the '
                    'ingesting device. Recorded files land ON THAT DEVICE '
                    '(export from there) — the browser never holds the '
                    'recording.'
                : 'Records real link sessions in the BenchSession format '
                    'the benches read (dip_db from a vacant-baseline '
                    'window + operator-declared scripted truth). Files '
                    'land in bench_sessions/ in the app documents dir.',
            style: OutrideType.section(11).copyWith(height: 1.6),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<BenchSessionTemplate>(
            initialValue: _template,
            isExpanded: true,
            decoration:
                const InputDecoration(labelText: 'SESSION TEMPLATE'),
            items: [
              for (final t in BenchSessionTemplate.values)
                DropdownMenuItem(
                  value: t,
                  child: Text(t.label),
                ),
            ],
            onChanged: recording
                ? null
                : (v) => setState(() => _template = v!),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _label,
            enabled: !recording,
            decoration: const InputDecoration(
                labelText: 'LABEL', hintText: 'e.g. nov23-crossings-1'),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _wayAx,
                  enabled: !recording,
                  keyboardType: TextInputType.number,
                  decoration:
                      const InputDecoration(labelText: 'WAYPOINT A X (m)'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _wayAy,
                  enabled: !recording,
                  keyboardType: TextInputType.number,
                  decoration:
                      const InputDecoration(labelText: 'WAYPOINT A Y (m)'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _wayBx,
                  enabled: !recording,
                  keyboardType: TextInputType.number,
                  decoration:
                      const InputDecoration(labelText: 'WAYPOINT B X (m)'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _wayBy,
                  enabled: !recording,
                  keyboardType: TextInputType.number,
                  decoration:
                      const InputDecoration(labelText: 'WAYPOINT B Y (m)'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _baseline,
                  enabled: !recording,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: 'BASELINE WINDOW (s, vacant)'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _illuminator,
                  enabled: !recording,
                  decoration: const InputDecoration(
                      labelText: 'ILLUMINATOR BAND (B19, optional)'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _notes,
            enabled: !recording,
            decoration: const InputDecoration(
                labelText: 'GEOMETRY NOTES',
                hintText: 'e.g. nodes on tripods, 6-node hex'),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton(
                onPressed: recording ? _stopRecording : _startRecording,
                child: Text(recording ? 'STOP RECORDING' : 'START RECORDING'),
              ),
              TextButton(
                onPressed: _refreshInputs,
                child: const Text('REFRESH LIST'),
              ),
            ],
          ),
          if (_recordMessage != null) ...[
            const SizedBox(height: 8),
            Text(_recordMessage!,
                style: OutrideType.section(12).copyWith(height: 1.5)),
          ],
          if (recording) ...[
            const SizedBox(height: 8),
            Text(
              'Recording: ${widget.state.benchRecorder.rows} rows so far. '
              'Keep the area clear for the baseline window, then walk '
              'waypoint A → B (moving templates). Truth is interpolated '
              'over the recording duration at stop.',
              style: OutrideType.section(11).copyWith(height: 1.6),
            ),
          ],
          const SizedBox(height: 8),
          const Text('RECORDED SESSIONS',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.0,
                  color: OutrideColors.dim)),
          const SizedBox(height: 4),
          if (_recordedFiles.isEmpty)
            Text('No recorded sessions yet.',
                style: OutrideType.section(11).copyWith(height: 1.5))
          else
            for (final f in _recordedFiles.take(10))
              Text(f.path,
                  style: OutrideType.section(11).copyWith(height: 1.5)),
          if (_recordedFiles.length > 10)
            Text('… and ${_recordedFiles.length - 10} more.',
                style: OutrideType.section(11).copyWith(height: 1.5)),
          Text(
            'Export: no share sheet exists in the app — copy files from '
            'the app documents dir (bench_sessions/) via USB/file manager. '
            'Share-sheet export is a known gap, not a silent omission.',
            style: OutrideType.section(11)
                .copyWith(color: OutrideColors.muted, height: 1.5),
          ),
        ],
      ),
    );
  }

  /// B3 fleet-health panel (Bench screen only — never the live fleet
  /// view). Health is `unreadable`: B3's scorer is blocked, so no
  /// green Health cell is ever rendered without a scorer behind it.
  Widget _fleetHealthPanel() {
    return OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text('FLEET HEALTH (B3 PENDING)',
                    style: OutrideType.section(),
                    overflow: TextOverflow.ellipsis),
              ),
              const Spacer(),
              const OutrideChip(
                  label: 'UNREADABLE', color: OutrideColors.amber),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Sync: unreadable · Health: unreadable · Coverage: never '
            'green by omission. A node reports a fact, never a verdict; '
            'a probe that cannot run is unreadable, never false. The '
            'Health answer needs the B3 gateway-side link-health scorer, '
            'which is BLOCKED (no Outride backhaul logs in workspace; no '
            'jammer bench set up; no backhaul-log reader/recorder '
            'in-app).',
            style: OutrideType.section(11).copyWith(height: 1.6),
          ),
        ],
      ),
    );
  }

  // --- Registry rows ---------------------------------------------------------

  List<Widget> _registryRows() {
    final out = <Widget>[];
    String? currentGroup;
    for (final entry in benchRegistry) {
      if (entry.group != null && entry.group != currentGroup) {
        currentGroup = entry.group;
        // The group header owns the single RUN button for the whole
        // group harness (one key, run-B5 — never one button per arm
        // row with a duplicated key).
        final runEntry = benchRegistry.firstWhere(
          (e) =>
              e.group == entry.group &&
              e.kind == BenchVerdictKind.implement,
        );
        out.add(_groupHeader(entry.group!, runEntry));
        out.add(const SizedBox(height: 10));
      }
      out.add(_benchRow(entry));
      out.add(const SizedBox(height: 10));
    }
    return out;
  }

  /// Group header: title + the group's single RUN button. The B5
  /// arms share one harness (key `b5`), so the header — not each arm
  /// row — owns the affordance.
  Widget _groupHeader(String group, BenchEntry runEntry) {
    final ran = _results.containsKey(group);
    return Row(
      children: [
        Flexible(
          child: Text(group,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.0,
                color: OutrideColors.dim,
              )),
        ),
        const SizedBox(width: 8),
        ElevatedButton(
          key: Key('run-${group.split(' ').first}'),
          onPressed: () => _runOne(runEntry),
          child: Text(ran ? 'RUN AGAIN' : 'RUN'),
        ),
      ],
    );
  }

  Widget _benchRow(BenchEntry entry) {
    final key = entry.group != null ? entry.group! : entry.id;
    final isImplement =
        entry.kind == BenchVerdictKind.implement;
    // A QUEUED row never shows a result — B5.1 shares the B5 group
    // key, but its blocker stands; the group's outcome belongs to
    // the implement arms only.
    final outcome = isImplement ? _results[key] : null;
    // A grouped arm shows only its own verdict/arm-score from the
    // shared group outcome (the group's chip likewise reflects the
    // arm's own verdict, not all four arms).
    final ownVerdicts = outcome == null || entry.group == null
        ? outcome?.verdicts
        : outcome.verdicts
            .where((v) => v.bar.startsWith('${entry.id} '))
            .toList();
    final isB10 = entry.id == 'B10';
    String chipLabel;
    Color chipColor;
    if (outcome == null) {
      if (isImplement) {
        chipLabel = 'PENDING — NO DATA';
        chipColor = OutrideColors.amber;
      } else {
        chipLabel = 'QUEUED — BLOCKED';
        chipColor = OutrideColors.muted;
      }
    } else if (outcome.skipped) {
      chipLabel = 'PENDING — NO DATA';
      chipColor = OutrideColors.amber;
    } else if (isB10 &&
        outcome.verdicts
            .any((v) => v.notApplicable && v.bar.contains('cost arm'))) {
      chipLabel = 'PARTIAL';
      chipColor = OutrideColors.amber;
    } else if (ownVerdicts != null &&
        ownVerdicts.isNotEmpty &&
        ownVerdicts.every((v) => v.notApplicable)) {
      // All-N/A arm: nothing was evaluable, so it is neither PASS
      // nor FAIL. (_armPassed returns false here, which would render
      // FAIL — an all-N/A arm must never read FAIL either.)
      chipLabel = 'N/A';
      chipColor = OutrideColors.amber;
    } else if (_armPassed(ownVerdicts)) {
      chipLabel = 'PASS';
      chipColor = OutrideColors.green;
    } else {
      chipLabel = 'FAIL';
      chipColor = OutrideColors.red;
    }
    return OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text('${entry.id} — ${entry.title}',
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: OutrideColors.onDark)),
              ),
              const SizedBox(width: 8),
              OutrideChip(label: chipLabel, color: chipColor),
            ],
          ),
          const SizedBox(height: 6),
          Text(entry.source,
              style: OutrideType.section(11).copyWith(height: 1.5)),
          const SizedBox(height: 4),
          Text('Pass bar: ${entry.passBar}',
              style: OutrideType.section(12).copyWith(height: 1.5)),
          if (entry.caveat.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('Note: ${entry.caveat}',
                style: OutrideType.section(11)
                    .copyWith(color: OutrideColors.muted, height: 1.5)),
          ],
          if (!isImplement) ...[
            const SizedBox(height: 6),
            Text('Blocked: ${entry.blocker}',
                style: OutrideType.section(12).copyWith(height: 1.5)),
            if (entry.unblock.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('WHAT WOULD UNBLOCK THIS: ${entry.unblock}',
                  style: OutrideType.section(12).copyWith(height: 1.5)),
            ],
          ],
          if (isImplement && entry.group == null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                ElevatedButton(
                  key: Key('run-${entry.id}'),
                  onPressed: () => _runOne(entry),
                  child: Text(outcome == null ? 'RUN' : 'RUN AGAIN'),
                ),
                if (entry.id == 'B7') ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                        'SVM arm: PENDING until a weights sidecar exists.',
                        style: OutrideType.section(11)
                            .copyWith(height: 1.5)),
                  ),
                ],
              ],
            ),
          ],
          if (outcome != null) ...[
            const SizedBox(height: 8),
            _resultBlock(entry, outcome),
          ],
        ],
      ),
    );
  }

  /// True when every evaluable verdict in [verdicts] passed (and at
  /// least one was evaluable) — the per-arm version of
  /// BenchOutcome.allPassed, for grouped arms sharing one outcome.
  bool _armPassed(List<BenchVerdict>? verdicts) {
    if (verdicts == null) return false;
    final applicable = verdicts.where((v) => !v.notApplicable).toList();
    if (applicable.isEmpty) return false;
    return applicable.every((v) => v.passed);
  }

  Widget _resultBlock(BenchEntry entry, BenchOutcome outcome) {
    final lines = <Widget>[];
    if (outcome.skipped) {
      lines.add(Text(
        'PENDING — NO DATA: ${outcome.skipReason ?? ''}',
        style: OutrideType.section(12)
            .copyWith(color: OutrideColors.amber, height: 1.5),
      ));
    } else {
      lines.add(Text(
        'Ran on: ${outcome.sessionsRun.join(', ')}',
        style: OutrideType.section(11).copyWith(height: 1.5),
      ));
      // A grouped arm shows only its own verdict(s) and arm score(s)
      // from the shared group outcome.
      final verdicts = entry.group == null
          ? outcome.verdicts
          : outcome.verdicts
              .where((v) => v.bar.startsWith('${entry.id} '))
              .toList();
      for (final v in verdicts) {
        final mark = v.notApplicable
            ? 'N/A'
            : v.passed
                ? 'PASS'
                : 'FAIL';
        lines.add(Text(
          '$mark — ${v.bar}: ${v.detail}',
          style: OutrideType.section(12).copyWith(height: 1.5),
        ));
      }
      final armScores = entry.group == null
          ? outcome.armScores.values
          : outcome.armScores.entries
              .where((e) => e.key.startsWith('${entry.id}/'))
              .map((e) => e.value);
      for (final a in armScores) {
        lines.add(Text(
          '${a.arm}: RMSE ${a.rmse.isFinite ? a.rmse.toStringAsFixed(3) : 'N/A'} m · '
          'mean NEES ${a.meanNees.isFinite ? a.meanNees.toStringAsFixed(3) : 'N/A'} '
          'in [${a.neesLow.toStringAsFixed(3)}, ${a.neesHigh.toStringAsFixed(3)}] '
          '(${a.samples} samples)',
          style: OutrideType.section(11).copyWith(height: 1.5),
        ));
      }
      if (entry.id == 'B1') {
        for (final line in _b1Extra) {
          lines.add(Text(line,
              style: OutrideType.section(11).copyWith(height: 1.5)));
        }
        lines.add(Text(
          'Note: the paper\'s 684 m absolute RMSE is a 120-km '
          'bearing-only artifact — only relative ordering transfers.',
          style: OutrideType.section(11)
              .copyWith(color: OutrideColors.muted, height: 1.5),
        ));
      }
      if (entry.id == 'B4') {
        lines.add(Text(
          'Deadline numbers above are wall-clock phone measurements on '
          'replay, not the paper\'s 200 Hz MCU budgets.',
          style: OutrideType.section(11)
              .copyWith(color: OutrideColors.muted, height: 1.5),
        ));
      }
      if (entry.id == 'B11') {
        lines.add(Text(
          'Baseline: the LBP reconstructor built in this harness — no '
          'live Outride reconstructor exists.',
          style: OutrideType.section(11)
              .copyWith(color: OutrideColors.muted, height: 1.5),
        ));
      }
    }
    if (outcome.rejected.isNotEmpty) {
      for (final e in outcome.rejected.entries) {
        lines.add(Text(
          'Rejected file: ${e.key} — ${e.value}',
          style: OutrideType.section(11)
              .copyWith(color: OutrideColors.red, height: 1.5),
        ));
      }
    } else if (outcome.skipped) {
      lines.add(Text(
        'No files rejected.',
        style: OutrideType.section(11)
            .copyWith(color: OutrideColors.muted, height: 1.5),
      ));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: lines,
    );
  }
}
