import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../services/experimental_sensors.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'beam.dart';
import 'drone_tab.dart';
import 'fetch_screen.dart';
import 'spectrum_screen.dart';
import 'tracking.dart';
import 'wifi_vision.dart';

/// Sensors — the instrument list. One row per instrument; tapping a
/// row opens that instrument's current screen unchanged, wrapped in a
/// Scaffold so it has a title and a back button.
///
/// Six rows: Field map, Beam, WiFi, Drone, Fetch, Spectrum. Fetch and
/// Spectrum are EXPERIMENTAL: hidden while the Experimental sensors
/// toggle in Settings is OFF ("4 of 6 shown"), shown with
/// EXPERIMENTAL tags when it is ON ("6 of 6 shown"). Nothing inside
/// the instrument screens changes here.
class SensorsScreen extends StatelessWidget {
  const SensorsScreen({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: experimentalSensors,
      builder: (context, _) {
        final showExp = experimentalSensors.shown;
        final rows = _rows();
        final visible =
            showExp ? rows : rows.where((r) => !r.experimental).toList();
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            OutridePanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('SENSORS', style: OutrideType.section()),
                  const SizedBox(height: 6),
                  Text(
                    'ONE TAP OPENS THE INSTRUMENT. NOTHING HERE WATCHES '
                    'FOR YOU — THE PICTURE SCREEN DOES THAT.',
                    style: OutrideType.section(10).copyWith(height: 1.6),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            for (final row in visible) ...[
              _sensorRow(context, row),
              const SizedBox(height: 12),
            ],
            OutridePanel(
              child: Text(
                showExp
                    ? '6 OF 6 SHOWN — EXPERIMENTAL SENSORS ON.'
                    : '4 OF 6 SHOWN — EXPERIMENTAL SENSORS HIDDEN. '
                        'TURN THEM ON IN SETTINGS.',
                style: OutrideType.section(10).copyWith(height: 1.6),
              ),
            ),
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
          status: state.polling ? 'MAP LIVE' : 'PAUSED',
          statusColor:
              state.polling ? OutrideColors.green : OutrideColors.muted,
          open: (context) => _pushInstrument(
              context, 'Field map', TrackingScreen(state: state)),
        ),
        _SensorRow(
          name: 'Beam',
          icon: Icons.view_in_ar,
          desc: '3D beam view — mesh geometry, drag to orbit.',
          experimental: false,
          status: state.nodeHealthMap.isEmpty
              ? 'NO NODES'
              : '${state.nodeHealthMap.length} NODES',
          statusColor: state.nodeHealthMap.isEmpty
              ? OutrideColors.muted
              : OutrideColors.green,
          open: (context) =>
              _pushInstrument(context, 'Beam', BeamScreen(state: state)),
        ),
        _SensorRow(
          name: 'WiFi',
          icon: Icons.wifi,
          desc: 'Passive WiFi / BLE scan — device probes and beacons.',
          experimental: false,
          status: kIsWeb
              ? 'NOT ON WEB'
              : (state.wifi.running ? 'LISTENING' : 'OFF'),
          statusColor: kIsWeb
              ? OutrideColors.amber
              : (state.wifi.running
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
                  context, 'WiFi', WifiVisionScreen(state: state));
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
              _pushInstrument(context, 'Drone', DroneTab(state: state)),
        ),
        _SensorRow(
          name: 'Fetch',
          icon: Icons.pets,
          desc: 'The Fetch — throwable sensor ball, tripwires, voice alerts.',
          experimental: true,
          status: state.hasFetchDriver ? 'CONNECTED' : 'NO DRIVER',
          statusColor: state.hasFetchDriver
              ? OutrideColors.green
              : OutrideColors.muted,
          open: (context) =>
              _pushInstrument(context, 'Fetch', FetchScreen(state: state)),
        ),
        _SensorRow(
          name: 'Spectrum',
          icon: Icons.graphic_eq,
          desc: 'Wideband SDR sweep — detected peaks by frequency.',
          experimental: true,
          status: state.hasSdrDriver ? 'SWEEPING' : 'NO DRIVER',
          statusColor: state.hasSdrDriver
              ? OutrideColors.green
              : OutrideColors.muted,
          open: (context) => _pushInstrument(
              context, 'Spectrum', SpectrumScreen(state: state)),
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

  Widget _sensorRow(BuildContext context, _SensorRow row) {
    // Two-line row on purpose: name + status pill on top, the
    // EXPERIMENTAL tag and description below, indented to the name.
    // A tag beside the name would not fit next to the status pill on
    // a narrow phone — the pill's inner Row cannot shrink below its
    // intrinsic width and the row would overflow.
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => row.open(context),
      child: OutridePanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(row.icon, color: OutrideColors.purple, size: 26),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(row.name.toUpperCase(),
                      style: OutrideType.rowValue(OutrideColors.onDark),
                      overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(width: 8),
                OutrideChip(label: row.status, color: row.statusColor),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right,
                    color: OutrideColors.muted, size: 18),
              ],
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 38),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (row.experimental) ...[
                    const OutrideChip(
                        label: 'EXPERIMENTAL',
                        color: OutrideColors.amber),
                    const SizedBox(height: 6),
                  ],
                  Text(row.desc,
                      style: OutrideType.section(10).copyWith(height: 1.5)),
                ],
              ),
            ),
          ],
        ),
      ),
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
