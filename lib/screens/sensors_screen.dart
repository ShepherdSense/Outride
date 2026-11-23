import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../services/bench_registry.dart';
import '../services/bench_status.dart';
import '../services/experimental_sensors.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'beam.dart';
import 'bench_screen.dart';
import 'drone_tab.dart';
import 'fetch_screen.dart';
import 'spectrum_screen.dart';
import 'tracking.dart';
import 'wifi_vision.dart';

/// Sensors — the instrument list. One row per instrument; tapping a
/// row opens that instrument's current screen unchanged, wrapped in a
/// Scaffold so it has a title and a back button.
///
/// Seven rows: Field map, Beam, WiFi, Drone, Fetch, Spectrum, Bench.
/// Fetch, Spectrum and Bench are EXPERIMENTAL: hidden while the
/// Experimental sensors toggle in Settings is OFF ("4 of 7 shown"),
/// shown with EXPERIMENTAL tags when it is ON ("7 of 7 shown").
/// Nothing inside the instrument screens changes here.
class SensorsScreen extends StatefulWidget {
  const SensorsScreen({super.key, required this.state});

  final AppState state;

  @override
  State<SensorsScreen> createState() => _SensorsScreenState();
}

class _SensorsScreenState extends State<SensorsScreen> {
  @override
  void initState() {
    super.initState();
    // Refresh the Bench pill from the last input scan (0 before any
    // scan — the honest default: no input seen yet, nothing READY).
    refreshBenchReadiness();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([experimentalSensors, benchReadyCount]),
      builder: (context, _) {
        final showExp = experimentalSensors.shown;
        final rows = _rows();
        final visible =
            showExp ? rows : rows.where((r) => !r.experimental).toList();
        return ListView(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
          children: [
            // Mock: uppercase dim heading + small dim count line, no
            // intro panel — the count line carries the same info.
            const Text('SENSORS',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                  color: OutrideColors.dim,
                )),
            const SizedBox(height: 4),
            Text(
              showExp
                  ? '${visible.length} of ${rows.length} shown — experimental sensors on.'
                  : '${visible.length} of ${rows.length} shown — experimental sensors hidden. Turn them on in Settings.',
              style: const TextStyle(
                  fontSize: 13, color: OutrideColors.faint, height: 1.45),
            ),
            const SizedBox(height: 12),
            for (final row in visible) ...[
              _sensorRow(context, row),
              const SizedBox(height: 10),
            ],
          ],
        );
      },
    );
  }

  List<_SensorRow> _rows() => [
        _SensorRow(
          name: 'Field map',
          icon: Icons.map,
          desc: 'Field map, tracks, GPS positioning, offline tiles.',
          experimental: false,
          status: widget.state.polling ? 'MAP LIVE' : 'PAUSED',
          statusColor:
              widget.state.polling ? OutrideColors.green : OutrideColors.muted,
          open: (context) => _pushInstrument(
              context, 'Field map', TrackingScreen(state: widget.state)),
        ),
        _SensorRow(
          name: 'Beam',
          icon: Icons.view_in_ar,
          desc: '3D beam view — mesh geometry, drag to orbit.',
          experimental: false,
          status: widget.state.nodeHealthMap.isEmpty
              ? 'NO NODES'
              : '${widget.state.nodeHealthMap.length} NODES',
          statusColor: widget.state.nodeHealthMap.isEmpty
              ? OutrideColors.muted
              : OutrideColors.green,
          open: (context) =>
              _pushInstrument(context, 'Beam', BeamScreen(state: widget.state)),
        ),
        _SensorRow(
          name: 'WiFi',
          icon: Icons.wifi,
          desc: 'Passive WiFi / BLE scan — device probes and beacons.',
          experimental: false,
          status: kIsWeb
              ? 'NOT ON WEB'
              : (widget.state.wifi.running ? 'LISTENING' : 'OFF'),
          statusColor: kIsWeb
              ? OutrideColors.amber
              : (widget.state.wifi.running
                  ? OutrideColors.green
                  : OutrideColors.muted),
          open: (context) {
            // Web gate (§9 of the proposal): the web sim has no WiFi
            // scanning interface, so on web the row opens an explicit
            // gate card instead of the instrument — never a
            // live-looking screen, never the old grey screen.
            if (kIsWeb) {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const WifiWebGateScreen(),
                ),
              );
            } else {
              _pushInstrument(
                  context, 'WiFi', WifiVisionScreen(state: widget.state));
            }
          },
        ),
        _SensorRow(
          name: 'Drone',
          icon: Icons.flight,
          desc: 'Drone-confirm tier — EO + thermal video.',
          experimental: false,
          status: 'READY',
          statusColor: OutrideColors.muted,
          open: (context) =>
              _pushInstrument(context, 'Drone', DroneTab(state: widget.state)),
        ),
        _SensorRow(
          name: 'Fetch',
          icon: Icons.pets,
          desc: 'The Fetch — throwable sensor ball, tripwires, voice alerts.',
          experimental: true,
          status: widget.state.hasFetchDriver ? 'CONNECTED' : 'NO DRIVER',
          statusColor: widget.state.hasFetchDriver
              ? OutrideColors.green
              : OutrideColors.muted,
          open: (context) =>
              _pushInstrument(context, 'Fetch', FetchScreen(state: widget.state)),
        ),
        _SensorRow(
          name: 'Spectrum',
          icon: Icons.graphic_eq,
          desc: 'Wideband SDR sweep — detected peaks by frequency.',
          experimental: true,
          status: widget.state.hasSdrDriver ? 'SWEEPING' : 'NO DRIVER',
          statusColor: widget.state.hasSdrDriver
              ? OutrideColors.green
              : OutrideColors.muted,
          open: (context) => _pushInstrument(
              context, 'Spectrum', SpectrumScreen(state: widget.state)),
        ),
        // Bench (experimental instrumentation, same family as Fetch):
        // queued measurement benches — papers, pass bars, run status.
        // Nothing runs on synthetic data. The pill counts harnesses
        // whose required input is present (0 of 12 READY on first
        // install); the B5 arms ride B1's input (see
        // benchRunnableEntryCount).
        _SensorRow(
          name: 'Bench',
          icon: Icons.science,
          desc: 'Queued measurement benches — papers, pass bars, run '
              'status. Nothing runs on synthetic data.',
          experimental: true,
          status:
              '${benchReadyCount.value} of $benchRunnableEntryCount READY',
          statusColor: benchReadyCount.value > 0
              ? OutrideColors.green
              : OutrideColors.amber,
          open: (context) => _pushInstrument(
              context, 'Bench', BenchScreen(state: widget.state)),
        ),
      ];

  /// Instrument screens are bare tab bodies (no Scaffold of their
  /// own), so the push wraps each one with a title bar and back
  /// button. The screen inside is untouched.
  void _pushInstrument(BuildContext context, String title, Widget screen) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(title.toUpperCase())),
          body: screen,
        ),
      ),
    );
  }

  /// Mock row: 76 px tall at mock width, 48 px purple icon tile,
  /// name 19 px + desc 14 px, status pill, chevron, EXPERIMENTAL
  /// tag inline beside the name (mock .exp-inline).
  ///
  /// Two narrow-screen concessions (the mock is 430 px wide; at
  /// 360 px the pill text alone is ~135 px in the fallback font):
  /// the status pill sits under the description instead of beside
  /// the name, and the tag scales down rather than overflowing.
  /// Nothing is dropped — every element the mock shows is here.
  Widget _sensorRow(BuildContext context, _SensorRow row) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => row.open(context),
      child: Container(
        constraints: const BoxConstraints(minHeight: 76),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: OutrideColors.surface,
          border: Border.all(color: OutrideColors.border),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: OutrideColors.purpleDeep,
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(row.icon,
                  color: const Color(0xFFDDD6FE), size: 26),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(row.name,
                            style: const TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.w800,
                                color: OutrideColors.onDark),
                            overflow: TextOverflow.ellipsis),
                      ),
                      if (row.experimental) ...[
                        const SizedBox(width: 8),
                        Flexible(
                          fit: FlexFit.loose,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 3),
                              decoration: BoxDecoration(
                                border: Border.all(
                                    color:
                                        OutrideColors.amber.withAlpha(128)),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: const Text('EXPERIMENTAL',
                                  style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 0.5,
                                      color: OutrideColors.amber)),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(row.desc,
                      style: const TextStyle(
                          fontSize: 14,
                          color: OutrideColors.dim,
                          height: 1.35)),
                  const SizedBox(height: 8),
                  _statusPill(row.status, row.statusColor),
                ],
              ),
            ),
            const SizedBox(width: 2),
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Icon(Icons.chevron_right,
                  color: OutrideColors.faint, size: 22),
            ),
          ],
        ),
      ),
    );
  }

  /// Mock status pill: bold, tinted bg, colored text. 11 px so the
  /// widest label ('NOT ON WEB') still fits a 320 px row.
  Widget _statusPill(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withAlpha(38),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
              color: color)),
    );
  }
}

class _SensorRow {
  const _SensorRow({
    required this.name,
    required this.icon,
    required this.desc,
    required this.experimental,
    required this.status,
    required this.statusColor,
    required this.open,
  });

  final String name;
  final IconData icon;
  final String desc;
  final bool experimental;
  final String status;
  final Color statusColor;
  final void Function(BuildContext context) open;
}

/// Web gate for the WiFi instrument: shown instead of the instrument
/// on web, where there is no WiFi scanning interface for the app to
/// use. An explicit dead end, not a live-looking screen and not the
/// old grey screen.
class WifiWebGateScreen extends StatelessWidget {
  const WifiWebGateScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('WIFI')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          OutridePanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text('WIFI SCANNING',
                          style: OutrideType.section(),
                          overflow: TextOverflow.ellipsis),
                    ),
                    const Spacer(),
                    const OutrideChip(
                        label: 'NOT ON WEB', color: OutrideColors.amber),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'WiFi scanning is not available on web',
                  style: OutrideType.rowValue(OutrideColors.onDark)
                      .copyWith(fontSize: 15),
                ),
                const SizedBox(height: 8),
                Text(
                  'Wi-Fi vision runs on Android — the web has no WiFi '
                  'scanning interface for the app to use, so this '
                  'instrument is gated off here instead of showing a '
                  'live-looking screen. Nothing is scanning. The Beam '
                  'picture is unaffected: WiFi only ever adds to it, it '
                  'never vetoes it.',
                  style: OutrideType.section(11).copyWith(height: 1.6),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
