import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../services/discovery.dart';
import '../services/operator_pose.dart';
import '../services/radio_driver.dart';
import '../services/experimental_sensors.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'beam.dart';
import 'drone_tab.dart';
import 'fetch_screen.dart';
import 'radios_links_screen.dart';
import 'radios_networks_screen.dart';
import 'spectrum_screen.dart';
import 'tracking.dart';
import 'wifi_vision.dart';
import 'wifi_web_gate_screen.dart';

/// Sensor status as the grid shows it: live data flowing, ready but
/// idle, or unavailable. Every card's status is derived from live
/// [AppState] — never a placeholder.
enum _SensorStatus { connected, standby, off }

extension on _SensorStatus {
  String get label => switch (this) {
        _SensorStatus.connected => 'Connected',
        _SensorStatus.standby => 'Standby',
        _SensorStatus.off => 'Off',
      };
}

/// Sensors — the instrument list as a two-column card grid (v0.30.1,
/// per the picked grid mockup). Each card: icon tile, sensor name,
/// small description, status pill. Cards are multicoloured — one
/// colour per sensor following its natural or brand colour — on
/// glassy translucent dark panels, never solid opaque dark and never
/// all amber.
///
/// Ten cards: Silvus RF Mesh, Fetch Ball, Meshtastic, Wi-Fi Sensing,
/// Bluetooth, GPS, mmWave Radar, Microphone Array, Camera, Spectrum.
/// Fetch Ball, mmWave, Microphone Array and Spectrum are EXPERIMENTAL:
/// hidden while the Experimental sensors toggle in Settings is OFF,
/// shown with EXPERIMENTAL tags when it is ON. Tapping a card opens
/// that sensor's current screen unchanged. A Radios & Networks card
/// below the grid groups all radio/network management in one place,
/// and "Scan for new sensors" runs a real LAN scan for Silvus radios
/// and Meshtastic nodes on the discovery subnet.
class SensorsScreen extends StatefulWidget {
  const SensorsScreen({super.key, required this.state, this.scanRadios});

  final AppState state;

  /// Test seam for the scan; production passes nothing.
  final SensorScanFn? scanRadios;

  @override
  State<SensorsScreen> createState() => _SensorsScreenState();
}

class _SensorsScreenState extends State<SensorsScreen> {
  /// "Only connected" filter from the count bar.
  bool _onlyConnected = false;

  /// Scan in flight (button disabled, "Scanning…" shown).
  bool _scanning = false;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: experimentalSensors,
      builder: (context, _) {
        final showExp = experimentalSensors.shown;
        final all = _cards();
        final visible =
            showExp ? all : all.where((c) => !c.experimental).toList();
        final shown = _onlyConnected
            ? visible
                .where((c) => c.status == _SensorStatus.connected)
                .toList()
            : visible;
        final connectedCount = visible
            .where((c) => c.status == _SensorStatus.connected)
            .length;
        return ListView(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
          children: [
            const Text('SENSORS',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                  color: OutrideColors.dim,
                )),
            const SizedBox(height: 4),
            const Text('Select sensors to activate',
                style: TextStyle(
                    fontSize: 13, color: OutrideColors.faint, height: 1.45)),
            const SizedBox(height: 2),
            Text(
              showExp
                  ? '${visible.length} of ${all.length} shown — experimental sensors on.'
                  : '${visible.length} of ${all.length} shown — experimental sensors hidden. Turn them on in Settings.',
              style: const TextStyle(
                  fontSize: 13, color: OutrideColors.faint, height: 1.45),
            ),
            const SizedBox(height: 12),
            // Count bar: active count + "Only connected" filter. The
            // count text is Expanded with an ellipsis: under the
            // test font every glyph is ~1em wide, so the row must
            // survive 360 px even when the text measures wide.
            Row(
              children: [
                Expanded(
                  child: Text('$connectedCount of ${visible.length} active',
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: OutrideColors.amber),
                      overflow: TextOverflow.ellipsis),
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () =>
                      setState(() => _onlyConnected = !_onlyConnected),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: _onlyConnected
                          ? OutrideColors.amber.withAlpha(38)
                          : Colors.transparent,
                      border: Border.all(
                          color: _onlyConnected
                              ? OutrideColors.amber
                              : OutrideColors.border),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Only connected',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: _onlyConnected
                                    ? OutrideColors.amber
                                    : OutrideColors.muted)),
                        const SizedBox(width: 6),
                        Icon(Icons.filter_list,
                            size: 15,
                            color: _onlyConnected
                                ? OutrideColors.amber
                                : OutrideColors.muted),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (shown.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text('No connected sensors.',
                    style: TextStyle(fontSize: 14, color: OutrideColors.dim),
                    textAlign: TextAlign.center),
              )
            else
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  // 224 px: room for the icon row, a wrapped
                  // name + EXPERIMENTAL tag line and three
                  // description lines, even under the wide test
                  // font. 204 px clipped the experimental cards
                  // by 12 px.
                  mainAxisExtent: 224,
                ),
                itemCount: shown.length,
                itemBuilder: (context, i) => _sensorCard(context, shown[i]),
              ),
            const SizedBox(height: 12),
            // Radios & Networks: every radio and network connection in
            // one place (glass purple), instead of piling up in
            // Settings. Tap opens the Radios & Networks screen.
            _radiosNetworksCard(context),
            const SizedBox(height: 16),
            // Scan for new sensors: real LAN scan (Silvus + Meshtastic)
            // on the discovery subnet; results open in a dialog with
            // an Add action per find.
            InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: _scanning ? null : _scan,
              child: Container(
                height: 56,
                decoration: BoxDecoration(
                  color: _scanning
                      ? OutrideColors.amber.withAlpha(120)
                      : OutrideColors.amber,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_scanning)
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Color(0xFF1A1207),
                        ),
                      )
                    else
                      const Icon(Icons.radar,
                          color: Color(0xFF1A1207), size: 22),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                          _scanning ? 'Scanning…' : 'Scan for new sensors',
                          style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF1A1207)),
                          overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  List<_SensorCard> _cards() {
    final state = widget.state;
    final silvusLive = state.nodeHealthMap.keys
        .any((id) => driverOf(id) == 'silvus');
    final silvusConfigured = state.radioConfigs
        .any((c) => c.driverId == 'silvus' && c.enabled);
    final meshLive = state.nodeHealthMap.keys
        .any((id) => driverOf(id) == 'meshtastic');
    final meshConfigured = state.radioConfigs
        .any((c) => c.driverId == 'meshtastic' && c.enabled);
    final wifiRunning = !kIsWeb && state.wifi.running;
    return [
      _SensorCard(
        name: 'Silvus RF Mesh',
        icon: Icons.cell_tower,
        desc: 'Secure peer-to-peer radio mesh network',
        color: OutrideColors.cyan,
        experimental: false,
        status: silvusLive
            ? _SensorStatus.connected
            : (silvusConfigured
                ? _SensorStatus.standby
                : _SensorStatus.off),
        open: (context) =>
            _pushInstrument(context, 'Beam', BeamScreen(state: state)),
      ),
      _SensorCard(
        name: 'Fetch Ball',
        icon: Icons.sports_baseball,
        // Jeremy's wording (2026-11-26): thrown sensor for extended
        // object / human detection — not "retrieval", not a capability
        // list.
        desc: 'Thrown sensor for extended object / human detection',
        color: OutrideColors.red,
        experimental: true,
        status: state.hasFetchDriver
            ? _SensorStatus.connected
            : _SensorStatus.off,
        open: (context) =>
            _pushInstrument(context, 'Fetch', FetchScreen(state: state)),
      ),
      _SensorCard(
        name: 'Meshtastic',
        icon: Icons.hub,
        desc: 'LoRa mesh for off-grid messaging',
        // Meshtastic's own app colour.
        color: OutrideColors.green,
        experimental: false,
        status: meshLive
            ? _SensorStatus.connected
            : (meshConfigured
                ? _SensorStatus.standby
                : _SensorStatus.off),
        open: (context) => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => RadiosLinksScreen(state: state),
          ),
        ),
      ),
      _SensorCard(
        name: 'Wi-Fi Sensing',
        icon: Icons.wifi,
        desc: 'Detect presence via Wi-Fi CSI',
        color: OutrideColors.blue,
        experimental: false,
        status: kIsWeb
            ? _SensorStatus.off
            : (wifiRunning
                ? _SensorStatus.connected
                : _SensorStatus.off),
        open: (context) {
          // Web gate (§9 of the proposal): the web sim has no WiFi
          // scanning interface, so on web the card opens an explicit
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
      _SensorCard(
        name: 'Bluetooth',
        icon: Icons.bluetooth,
        desc: 'BLE scan — nearby device beacons',
        color: OutrideColors.blue,
        experimental: false,
        // BLE scanning runs with the Wi-Fi vision instrument (same
        // service, same switch) — its status is that instrument's.
        status: kIsWeb
            ? _SensorStatus.off
            : (wifiRunning
                ? _SensorStatus.connected
                : _SensorStatus.off),
        open: (context) {
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
      _SensorCard(
        name: 'GPS',
        icon: Icons.location_on,
        desc: 'Global navigation & location tracking',
        color: OutrideColors.purple,
        experimental: false,
        status: switch (state.liveGpsState) {
          LiveGpsState.live => _SensorStatus.connected,
          LiveGpsState.starting => _SensorStatus.standby,
          _ => _SensorStatus.off,
        },
        open: (context) => _pushInstrument(
            context, 'Field map', TrackingScreen(state: state)),
      ),
      _SensorCard(
        name: 'mmWave Radar',
        icon: Icons.radar,
        desc: 'Motion & distance detection (60GHz)',
        color: OutrideColors.orange,
        experimental: true,
        // The 60 GHz radar lives on the Fetch ball: live exactly when
        // the ball is connected.
        status: state.hasFetchDriver
            ? _SensorStatus.connected
            : _SensorStatus.off,
        open: (context) =>
            _pushInstrument(context, 'Fetch', FetchScreen(state: state)),
      ),
      _SensorCard(
        name: 'Microphone Array',
        icon: Icons.mic,
        desc: 'Multi-mic direction & audio sensing',
        color: OutrideColors.amber,
        experimental: true,
        // The mic array lives on the Fetch ball: live exactly when
        // the ball is connected.
        status: state.hasFetchDriver
            ? _SensorStatus.connected
            : _SensorStatus.off,
        open: (context) =>
            _pushInstrument(context, 'Fetch', FetchScreen(state: state)),
      ),
      _SensorCard(
        name: 'Camera',
        icon: Icons.camera_alt,
        desc: 'Visual capture for detection confirmation',
        color: const Color(0xFFF472B6),
        experimental: false,
        // Camera confirmation is on-demand (upgrade-only): enabled
        // means ready, never live-streaming — Standby is the honest
        // ready state.
        status: state.cameraSettings.enabled
            ? _SensorStatus.standby
            : _SensorStatus.off,
        open: (context) =>
            _pushInstrument(context, 'Drone', DroneTab(state: state)),
      ),
      _SensorCard(
        name: 'Spectrum',
        icon: Icons.graphic_eq,
        desc: 'Wideband SDR sweep — detected peaks by frequency.',
        color: const Color(0xFF818CF8),
        experimental: true,
        status: state.hasSdrDriver
            ? _SensorStatus.connected
            : _SensorStatus.off,
        open: (context) => _pushInstrument(
            context, 'Spectrum', SpectrumScreen(state: state)),
      ),
    ];
  }

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

  /// One sensor card: glassy translucent panel in the sensor's own
  /// colour, icon tile + status pill on top, name, small
  /// description. Connected cards carry their colour in the border
  /// and glow; standby/off cards keep a neutral hairline border.
  Widget _sensorCard(BuildContext context, _SensorCard card) {
    final connected = card.status == _SensorStatus.connected;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => card.open(context),
      child: OutrideGlassPanel(
        tint: card.color,
        tintedBorder: connected,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: card.color
                        .withAlpha(connected ? 72 : 36),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(card.icon, color: card.color, size: 22),
                ),
                const Spacer(),
                // Flexible + ellipsis: the Connected pill plus the
                // icon must fit a 124 px content width — on a
                // phone the pill is ~79 px, under the wide test
                // font it would be 124 px alone.
                Flexible(child: _statusPill(card.status, card.color)),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                Text(card.name,
                    style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        color: OutrideColors.onDark),
                    overflow: TextOverflow.ellipsis),
                if (card.experimental)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      border: Border.all(
                          color: OutrideColors.amber.withAlpha(128)),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text('EXPERIMENTAL',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                            color: OutrideColors.amber)),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(card.desc,
                style: const TextStyle(
                    fontSize: 14, color: OutrideColors.dim, height: 1.35),
                maxLines: 3,
                overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }

  /// Status pill: Connected is a filled pill in the sensor's own
  /// colour with dark text; Standby/Off are neutral outlined pills.
  Widget _statusPill(_SensorStatus status, Color color) {
    if (status == _SensorStatus.connected) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withAlpha(230),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(status.label,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: Color(0xFF1A1207)),
            overflow: TextOverflow.ellipsis),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: OutrideColors.muted.withAlpha(24),
        border: Border.all(color: OutrideColors.muted.withAlpha(120)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(status.label,
          style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: OutrideColors.muted),
          overflow: TextOverflow.ellipsis),
    );
  }

  /// Radios & Networks hub card: glass purple. Every radio and
  /// network connection lives here — Silvus, Meshtastic, Wi-Fi,
  /// Bluetooth and the GL.iNet field hub — instead of piling up in
  /// Settings.
  Widget _radiosNetworksCard(BuildContext context) {
    final radios = widget.state.radioConfigs.length;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => RadiosNetworksScreen(state: widget.state),
        ),
      ),
      child: OutrideGlassPanel(
        tint: OutrideColors.purple,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: OutrideColors.purple.withAlpha(72),
                borderRadius: BorderRadius.circular(13),
              ),
              child: const Icon(Icons.router,
                  color: OutrideColors.purple, size: 26),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Radios & Networks',
                      style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                          color: OutrideColors.onDark)),
                  const SizedBox(height: 2),
                  const Text(
                      'Silvus, Meshtastic, Wi-Fi, Bluetooth and the GL.iNet field hub — all in one place.',
                      style: TextStyle(
                          fontSize: 14,
                          color: OutrideColors.dim,
                          height: 1.35)),
                  const SizedBox(height: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                      color: OutrideColors.muted.withAlpha(24),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text('$radios RADIOS CONFIGURED',
                        style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.8,
                            color: OutrideColors.muted)),
                  ),
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

  /// Real LAN scan for Silvus radios + Meshtastic nodes on the
  /// discovery subnet. Results open in a dialog with an Add action
  /// per find; already-configured finds show ADDED instead.
  Future<void> _scan() async {
    setState(() => _scanning = true);
    final subnet = widget.state.settings.subnet;
    List<DiscoveredRadio>? found;
    Object? error;
    try {
      final scan = widget.scanRadios ?? scanForSensors;
      found = await scan(subnet);
    } catch (e) {
      error = e;
    }
    if (!mounted) return;
    setState(() => _scanning = false);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('SCAN RESULTS'),
          content: SizedBox(
            width: double.maxFinite,
            child: error != null
                ? Text('Scan failed: $error',
                    style:
                        const TextStyle(color: OutrideColors.red))
                : (found == null || found.isEmpty)
                    ? Text(
                        'No new sensors found on $subnet.\n\nRadios must be on this subnet and reachable over HTTP. Change the subnet in Radios & Networks.',
                        style: const TextStyle(
                            fontSize: 14,
                            color: OutrideColors.dim,
                            height: 1.5),
                      )
                    : ListView(
                        shrinkWrap: true,
                        children: [
                          for (final r in found)
                            _foundTile(r, setDialogState),
                        ],
                      ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('DONE'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _foundTile(
      DiscoveredRadio r, void Function(void Function()) setDialogState) {
    final alreadyAdded = widget.state.radioConfigs.any(
        (c) => c.address == r.ip && c.driverId == r.driverId);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.router, color: OutrideColors.blue),
      title: Text(r.label,
          style: OutrideType.rowValue(OutrideColors.onDark)),
      subtitle: Text(
          alreadyAdded
              ? 'ALREADY ADDED'
              : 'TAP TO ADD AS ${r.driverId.toUpperCase()} RADIO',
          style: OutrideType.section(10)),
      trailing: alreadyAdded
          ? const Text('ADDED',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: OutrideColors.muted))
          : null,
      onTap: alreadyAdded
          ? null
          : () async {
              await widget.state.addRadio(RadioConfig(
                driverId: r.driverId,
                address: r.ip,
                label: r.label,
                pollInterval: widget.state.settings.pollInterval,
              ));
              setDialogState(() {});
            },
    );
  }
}

class _SensorCard {
  const _SensorCard({
    required this.name,
    required this.icon,
    required this.desc,
    required this.color,
    required this.experimental,
    required this.status,
    required this.open,
  });

  final String name;
  final IconData icon;
  final String desc;

  /// The sensor's own colour (natural / brand): Silvus cyan, Fetch
  /// red, Meshtastic green, Wi-Fi/Bluetooth blue, GPS purple,
  /// mmWave orange, Microphone amber, Camera pink, Spectrum indigo.
  final Color color;
  final bool experimental;
  final _SensorStatus status;
  final void Function(BuildContext context) open;
}
