import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../services/discovery.dart';
import '../services/glinet_router.dart';
import '../services/radio_driver.dart';
import '../services/tailscale_detect.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'tunnels_feeds_detail_screens.dart';
import 'wifi_vision.dart';
import 'wifi_web_gate_screen.dart';

/// Radios & Networks (v0.30.1): every radio and network connection in
/// one place, grouped under one card in Sensors — instead of piling
/// up in Settings. Covers Silvus, Meshtastic, Wi-Fi, Bluetooth and
/// the GL.iNet field-hub connection.
///
/// The RADIOS and FIND RADIOS ON LAN sections moved here verbatim
/// from Settings (same rows, same add form, same scan); Settings
/// keeps only a link row pointing here. Everything on this screen
/// carries the transparent glass-purple treatment: translucent dark
/// purple panels, never solid.
///
/// GL.iNet: read-only JSON-RPC client for firmware 4.x routers
/// (see docs/glinet-support.md). The router admin password is
/// session-only and never stored; the SID lives in memory only.
/// EXPERIMENTAL — unverified on hardware.
class RadiosNetworksScreen extends StatefulWidget {
  const RadiosNetworksScreen({super.key, required this.state, this.scanRadios});

  final AppState state;

  /// Test seam for the subnet scan; production passes nothing.
  final SensorScanFn? scanRadios;

  @override
  State<RadiosNetworksScreen> createState() => _RadiosNetworksScreenState();
}

class _RadiosNetworksScreenState extends State<RadiosNetworksScreen> {
  // ---- Radios (moved from Settings) ----
  String _newDriverId = 'silvus';
  late final TextEditingController _newAddress;
  late final TextEditingController _newLabel;

  // ---- Find radios on LAN (moved from Settings) ----
  late final TextEditingController _subnet;
  bool _scanning = false;
  List<DiscoveredRadio> _found = [];
  String? _scanError;

  // ---- GL.iNet field hub ----
  late final TextEditingController _glinetHost;
  late final TextEditingController _glinetUser;
  late final TextEditingController _glinetPass;
  GlinetRouter? _glinetRouter;
  bool _glinetBusy = false;
  GlinetProbeResult? _glinetProbeResult;
  GlinetRouterInfo? _glinetInfo;
  GlinetRouterStatus? _glinetStatus;
  GlinetRouterLoad? _glinetLoad;
  List<GlinetClient> _glinetClients = [];
  String? _glinetError;

  // ---- Tunnels & Feeds (v0.30.1) ----
  // Tailscale has no AppState status (detection + guidance only), so
  // this screen probes it once on open. Null = not probed yet (and on
  // web, where there is no tunnel to see).
  bool? _tailscaleUp;

  @override
  void initState() {
    super.initState();
    _newAddress = TextEditingController();
    _newLabel = TextEditingController();
    _subnet =
        TextEditingController(text: widget.state.settings.subnet);
    _glinetHost = TextEditingController(text: '192.168.8.1');
    _glinetUser = TextEditingController(text: 'root');
    _glinetPass = TextEditingController();
    // WireGuard status is AppState-owned; refresh it for this open,
    // then rebuild so the row pill shows the probe result.
    unawaited(widget.state.evaluateWireguardPath().then((_) {
      if (mounted) setState(() {});
    }));
    unawaited(_probeTailscale());
  }

  Future<void> _probeTailscale() async {
    final up = await tailscaleTunnelUp();
    if (mounted) setState(() => _tailscaleUp = up);
  }

  @override
  void dispose() {
    _newAddress.dispose();
    _newLabel.dispose();
    _subnet.dispose();
    _glinetHost.dispose();
    _glinetUser.dispose();
    _glinetPass.dispose();
    _glinetRouter?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('RADIOS & NETWORKS')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _section('Radios', [
            for (int i = 0;
                i < widget.state.radioConfigs.length;
                i++)
              _radioRow(i),
            if (widget.state.radioConfigs.isEmpty)
              Text('NO RADIOS CONFIGURED.',
                  style: OutrideType.section(10)
                      .copyWith(color: OutrideColors.muted)),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _newDriverId,
                    // The button must fill its flex slot: without
                    // isExpanded it sizes to the widest item and
                    // overflows the row on a phone-width screen.
                    isExpanded: true,
                    dropdownColor: OutrideColors.surface2,
                    style: OutrideType.rowValue(OutrideColors.onDark),
                    decoration:
                        const InputDecoration(labelText: 'DRIVER'),
                    items: [
                      for (final t in driverTypes)
                        DropdownMenuItem(
                          value: t.id,
                          child: Text(
                              '${t.label}${t.implemented ? '' : ' (SOON)'}'),
                        ),
                    ],
                    onChanged: (v) => setState(() {
                      _newDriverId = v ?? 'silvus';
                      // The SDR bridge talks to this app on UDP; prefill
                      // the listen endpoint so it is one tap, not a guess.
                      if (_newDriverId == 'sdr' &&
                          _newAddress.text.trim().isEmpty) {
                        _newAddress.text = '127.0.0.1:49161';
                      }
                      // KrakenSDR web UI default.
                      if (_newDriverId == 'kraken' &&
                          _newAddress.text.trim().isEmpty) {
                        _newAddress.text = '127.0.0.1:8081';
                      }
                    }),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: _field(
                      _newAddress, 'Address (IP)', 'e.g. 172.17.97.182'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: _field(
                      _newLabel, 'Label (optional)', 'e.g. North ridge'),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _addRadio,
                    child: const Text('Add radio'),
                  ),
                ),
              ],
            ),
          ]),
          _section('Find radios on LAN', [
            _field(_subnet, 'Discovery subnet (CIDR)',
                'e.g. 172.17.97.0/24'),
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: _scanning ? null : _scan,
              child: Text(_scanning ? 'Scanning…' : 'Scan subnet'),
            ),
            if (_scanning) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(),
            ],
            if (_scanError != null) ...[
              const SizedBox(height: 8),
              Text(_scanError!,
                  style: const TextStyle(color: OutrideColors.red)),
            ],
            for (final r in _found)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading:
                    const Icon(Icons.router, color: OutrideColors.blue),
                title: Text(r.label,
                    style: OutrideType.rowValue(OutrideColors.onDark)),
                subtitle: Text(
                    'TAP TO ADD AS ${r.driverId.toUpperCase()} RADIO',
                    style: OutrideType.section(10)),
                onTap: () async {
                  await widget.state.addRadio(RadioConfig(
                    driverId: r.driverId,
                    address: r.ip,
                    label: r.label,
                    pollInterval: widget.state.settings.pollInterval,
                  ));
                  if (mounted) setState(() {});
                },
              ),
            if (!_scanning && _found.isEmpty && _scanError == null)
              Text(
                'NO SCAN YET. RADIOS MUST BE ON THIS SUBNET AND REACHABLE OVER HTTP.',
                style: OutrideType.section(10).copyWith(height: 1.6),
              ),
          ]),
          _section('Networks', [
            _networkRow(
              icon: Icons.wifi,
              name: 'Wi-Fi',
              desc: 'Wi-Fi vision — passive Wi-Fi sensing on this device.',
              status: kIsWeb
                  ? 'NOT ON WEB'
                  : (widget.state.wifi.running ? 'LISTENING' : 'OFF'),
              statusColor: kIsWeb
                  ? OutrideColors.amber
                  : (widget.state.wifi.running
                      ? OutrideColors.green
                      : OutrideColors.muted),
              open: _openWifi,
            ),
            _networkRow(
              icon: Icons.bluetooth,
              name: 'Bluetooth',
              desc: 'BLE scan — nearby device beacons. Runs with Wi-Fi vision.',
              status: kIsWeb
                  ? 'NOT ON WEB'
                  : (widget.state.wifi.running ? 'LISTENING' : 'OFF'),
              statusColor: kIsWeb
                  ? OutrideColors.amber
                  : (widget.state.wifi.running
                      ? OutrideColors.green
                      : OutrideColors.muted),
              open: _openWifi,
            ),
          ]),
          _section('Tunnels & Feeds', [
            _networkRow(
              icon: Icons.vpn_key,
              name: 'WireGuard',
              desc: 'Tunnel from the WireGuard app — Outride recognizes it; the stored join selects the transport.',
              status: widget.state.wireguardTunnelDetected == null
                  ? 'NOT PROBED'
                  : widget.state.wireguardTunnelDetected!
                      ? 'UP'
                      : 'DOWN',
              statusColor: widget.state.wireguardTunnelDetected == null
                  ? OutrideColors.muted
                  : widget.state.wireguardTunnelDetected!
                      ? OutrideColors.green
                      : OutrideColors.amber,
              open: () => _openDetail(
                  (state) => WireguardDetailScreen(state: state)),
            ),
            _networkRow(
              icon: Icons.cloud_outlined,
              name: 'Cloudflare',
              desc: 'Hub behind cloudflared — auto-path to the public ingest URL.',
              status: widget.state.cloudflarePathReason.toUpperCase(),
              statusColor: widget.state.cloudflarePathActive
                  ? OutrideColors.green
                  : widget.state.cloudflarePathReason == 'offline'
                      ? OutrideColors.amber
                      : OutrideColors.muted,
              open: () => _openDetail(
                  (state) => CloudflareDetailScreen(state: state)),
            ),
            _networkRow(
              icon: Icons.lan,
              name: 'Tailscale',
              desc: 'Detection + guidance only — experimental, no Tailscale transport yet.',
              status: _tailscaleUp == null
                  ? 'NOT PROBED'
                  : _tailscaleUp!
                      ? 'UP'
                      : 'NOT DETECTED',
              statusColor: _tailscaleUp == null
                  ? OutrideColors.muted
                  : _tailscaleUp!
                      ? OutrideColors.green
                      : OutrideColors.amber,
              open: () => _openDetail(
                  (state) => TailscaleDetailScreen(state: state)),
            ),
            _networkRow(
              icon: Icons.hub,
              name: 'ZeroTier',
              desc: 'Mesh tunnel from the ZeroTier One app — auto-connects when up.',
              status: widget.state.zerotierPathReason.toUpperCase(),
              statusColor: widget.state.zerotierPathActive
                  ? OutrideColors.green
                  : widget.state.zerotierPathReason == 'down'
                      ? OutrideColors.amber
                      : OutrideColors.muted,
              open: () => _openDetail(
                  (state) => ZerotierDetailScreen(state: state)),
            ),
            _networkRow(
              icon: Icons.radar,
              name: 'Predator-RF',
              desc: 'CoT feed — emitter ingest (RX-only) and track publish.',
              status: widget.state.settings.cotListenEnabled
                  ? 'LISTENING'
                  : widget.state.settings.cotEmitEnabled
                      ? 'EMITTING'
                      : 'OFF',
              statusColor: widget.state.settings.cotListenEnabled ||
                      widget.state.settings.cotEmitEnabled
                  ? OutrideColors.green
                  : OutrideColors.muted,
              open: () => _openDetail(
                  (state) => PredatorRfDetailScreen(state: state)),
            ),
            _networkRow(
              icon: Icons.sync_alt,
              name: 'ZMeta',
              desc: 'Open-standard ingest — gateway, transport, and join.',
              status: widget.state.settings.zmetaEnabled
                  ? widget.state.settings.zmetaTransport.toUpperCase()
                  : 'OFF',
              statusColor: widget.state.settings.zmetaEnabled
                  ? OutrideColors.green
                  : OutrideColors.muted,
              open: () => _openDetail(
                  (state) => ZmetaDetailScreen(state: state)),
            ),
          ]),
          _section('GL.iNet field hub', _glinetBody()),
        ],
      ),
    );
  }

  // ---- Radios (moved from Settings, unchanged behaviour) ----

  Future<void> _addRadio() async {
    final type = driverTypes.firstWhere((t) => t.id == _newDriverId);
    if (!type.implemented) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${type.label} telemetry not yet implemented')),
      );
      return;
    }
    final address = _newAddress.text.trim();
    if (address.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter the radio address (IP)')),
      );
      return;
    }
    await widget.state.addRadio(RadioConfig(
      driverId: _newDriverId,
      address: address,
      label: _newLabel.text.trim(),
      pollInterval: widget.state.settings.pollInterval,
    ));
    _newAddress.clear();
    _newLabel.clear();
    if (mounted) setState(() {});
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _found = [];
      _scanError = null;
    });
    try {
      final subnet = _subnet.text.trim();
      final scan = widget.scanRadios ?? scanForSensors;
      final found = await scan(subnet);
      // The subnet field now lives here, not in Settings: persist a
      // changed subnet only after a scan proves the CIDR parses.
      if (subnet != widget.state.settings.subnet) {
        unawaited(widget.state.setDiscoverySubnet(subnet));
      }
      if (mounted) setState(() => _found = found);
    } catch (e) {
      if (mounted) setState(() => _scanError = 'Scan failed: $e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Widget _radioRow(int i) {
    final c = widget.state.radioConfigs[i];
    final st = widget.state.statusFor(c);
    final type = driverTypes.firstWhere((t) => t.id == c.driverId,
        orElse: () => (
              id: c.driverId,
              label: c.driverId.toUpperCase(),
              implemented: true
            ));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: driverColor(c.driverId),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  c.displayLabel,
                  style: OutrideType.rowValue(OutrideColors.onDark)
                      .copyWith(fontSize: 12),
                ),
                Text(
                  st?.error ??
                      (st?.lastPoll == null
                          ? 'NOT POLLING'
                          : '${st!.linkCount} LINKS'),
                  style: OutrideType.section(10).copyWith(
                      color: st?.error != null
                          ? OutrideColors.red
                          : OutrideColors.muted),
                ),
              ],
            ),
          ),
          if (!type.implemented)
            Text('SOON',
                style: OutrideType.section(10)
                    .copyWith(color: OutrideColors.orange))
          else
            Switch(
              value: c.enabled,
              activeThumbColor: OutrideColors.purple,
              onChanged: (v) async {
                await widget.state.setRadioEnabled(i, v);
                if (mounted) setState(() {});
              },
            ),
          IconButton(
            icon: const Icon(Icons.delete_outline,
                color: OutrideColors.muted, size: 20),
            onPressed: () async {
              await widget.state.removeRadioAt(i);
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
    );
  }

  // ---- Tunnels & Feeds ----

  /// Push a detail screen, then refresh this screen's live statuses
  /// when the operator comes back (a re-check or toggle inside may
  /// have changed them).
  void _openDetail(Widget Function(AppState state) build) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => build(widget.state)))
        .then((_) {
      if (!mounted) return;
      setState(() {});
      unawaited(_probeTailscale());
    });
  }

  // ---- Networks ----

  void _openWifi() {
    if (kIsWeb) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const WifiWebGateScreen()),
      );
    } else {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => Scaffold(
            appBar: AppBar(title: const Text('WIFI')),
            body: WifiVisionScreen(state: widget.state),
          ),
        ),
      );
    }
  }

  Widget _networkRow({
    required IconData icon,
    required String name,
    required String desc,
    required String status,
    required Color statusColor,
    required VoidCallback open,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: open,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: OutrideColors.purpleDeep.withAlpha(48),
          border: Border.all(color: OutrideColors.purple.withAlpha(70)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, color: OutrideColors.purple, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: OutrideColors.onDark)),
                  const SizedBox(height: 2),
                  Text(desc,
                      style: const TextStyle(
                          fontSize: 13,
                          color: OutrideColors.dim,
                          height: 1.35)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: statusColor.withAlpha(38),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(status,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                      color: statusColor)),
            ),
            const Icon(Icons.chevron_right,
                color: OutrideColors.faint, size: 20),
          ],
        ),
      ),
    );
  }

  // ---- GL.iNet field hub ----

  List<Widget> _glinetBody() {
    final loggedIn = _glinetRouter?.isLoggedIn ?? false;
    return [
      // (The section header already says GL.INET FIELD HUB; the
      // title row here carries only the EXPERIMENTAL tag.)
      Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              border:
                  Border.all(color: OutrideColors.amber.withAlpha(128)),
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
      const SizedBox(height: 8),
      const Text(
        'USE A GL.INET TRAVEL ROUTER (OPENWRT, FIRMWARE 4.X) AS THE PORTABLE FIELD HUB. READ-ONLY: THE APP NEVER CHANGES ROUTER SETTINGS. PASSWORD IS SESSION-ONLY AND NEVER STORED. UNVERIFIED ON HARDWARE.',
        style: TextStyle(
            fontSize: 11, color: OutrideColors.dim, height: 1.6),
      ),
      const SizedBox(height: 12),
      _field(_glinetHost, 'Router address', 'e.g. 192.168.8.1'),
      const SizedBox(height: 10),
      _field(_glinetUser, 'Username', 'root'),
      const SizedBox(height: 10),
      TextField(
        controller: _glinetPass,
        obscureText: true,
        enableSuggestions: false,
        autocorrect: false,
        style: OutrideType.rowValue(OutrideColors.onDark),
        decoration: const InputDecoration(
            labelText: 'ROUTER ADMIN PASSWORD',
            hintText: 'session-only — never stored'),
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _glinetBusy ? null : _glinetProbe,
              child: const Text('Probe'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ElevatedButton(
              onPressed: _glinetBusy ? null : _glinetConnect,
              child: Text(loggedIn ? 'Refresh' : 'Connect'),
            ),
          ),
          if (loggedIn) ...[
            const SizedBox(width: 8),
            Expanded(
              child: TextButton(
                onPressed: _glinetBusy ? null : _glinetDisconnect,
                child: const Text('Disconnect',
                    style: TextStyle(color: OutrideColors.red)),
              ),
            ),
          ],
        ],
      ),
      if (_glinetBusy) ...[
        const SizedBox(height: 12),
        const LinearProgressIndicator(),
      ],
      if (_glinetProbeResult != null) ...[
        const SizedBox(height: 10),
        Text(
          _glinetProbeResult!.isGlinet4x
              ? 'GL.INET FIRMWARE 4.X ROUTER FOUND (CHALLENGE ALG ${_glinetProbeResult!.challengeAlg}).'
              : 'NOT A GL.INET FIRMWARE 4.X ROUTER: ${_glinetProbeResult!.error ?? 'NO ANSWER'}.',
          style: TextStyle(
              fontSize: 12,
              color: _glinetProbeResult!.isGlinet4x
                  ? OutrideColors.green
                  : OutrideColors.red,
              height: 1.5),
        ),
      ],
      if (_glinetError != null) ...[
        const SizedBox(height: 10),
        Text(_glinetError!,
            style:
                const TextStyle(fontSize: 12, color: OutrideColors.red, height: 1.5)),
      ],
      if (loggedIn && _glinetInfo != null) ...[
        const SizedBox(height: 12),
        ..._glinetStatusRows(),
      ],
    ];
  }

  List<Widget> _glinetStatusRows() {
    final info = _glinetInfo!;
    final status = _glinetStatus;
    final load = _glinetLoad;
    final clients = status == null
        ? 0
        : status.clientCounts.cableTotal +
            status.clientCounts.wirelessTotal;
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              SizedBox(
                width: 110,
                child: Text(label,
                    style: OutrideType.rowLabel()),
              ),
              Expanded(
                child: Text(value,
                    style:
                        OutrideType.rowValue(OutrideColors.onDark)),
              ),
            ],
          ),
        );
    return [
      row('MODEL', info.boardModel.isEmpty ? info.model : info.boardModel),
      row('FIRMWARE', info.firmwareVersion.isEmpty ? '—' : info.firmwareVersion),
      row('MAC', info.mac.isEmpty ? '—' : info.mac),
      if (status?.uptimeSeconds != null)
        row('UPTIME', _fmtUptime(status!.uptimeSeconds!)),
      row('CLIENTS', '$clients connected'),
      if (load?.load1Min != null)
        row('CPU LOAD 1 MIN', load!.load1Min!.toStringAsFixed(2)),
      if (status?.memoryTotal != null && status?.memoryFree != null)
        row('MEMORY FREE',
            '${(status!.memoryFree! / 1048576).toStringAsFixed(0)} / ${(status.memoryTotal! / 1048576).toStringAsFixed(0)} MB'),
      if (_glinetClients.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text('CLIENTS ON THE HUB', style: OutrideType.section(10)),
        const SizedBox(height: 4),
        for (final c in _glinetClients.take(8))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: c.online
                        ? OutrideColors.green
                        : OutrideColors.muted,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(c.displayName,
                      style: OutrideType.rowValue(OutrideColors.onDark),
                      overflow: TextOverflow.ellipsis),
                ),
                Text(c.ip,
                    style: OutrideType.rowLabel()),
                const SizedBox(width: 8),
                Text(c.iface,
                    style: OutrideType.rowLabel()),
              ],
            ),
          ),
      ],
    ];
  }

  Uri _glinetRpcUri() {
    final host = _glinetHost.text.trim();
    if (host.isEmpty) return Uri.parse('http://192.168.8.1/rpc');
    if (host.startsWith('http://') || host.startsWith('https://')) {
      final base = host.endsWith('/') ? host.substring(0, host.length - 1) : host;
      return Uri.parse(base.endsWith('/rpc') ? base : '$base/rpc');
    }
    return Uri.parse('http://$host/rpc');
  }

  GlinetRouter _newGlinetRouter() {
    _glinetRouter?.close();
    final router = GlinetRouter(rpcUri: _glinetRpcUri());
    _glinetRouter = router;
    return router;
  }

  Future<void> _glinetProbe() async {
    setState(() {
      _glinetBusy = true;
      _glinetProbeResult = null;
      _glinetError = null;
    });
    try {
      final router = _newGlinetRouter();
      final probe =
          await router.probe(username: _glinetUser.text.trim().isEmpty
              ? 'root'
              : _glinetUser.text.trim());
      if (mounted) setState(() => _glinetProbeResult = probe);
    } catch (e) {
      if (mounted) {
        setState(() => _glinetError =
            e is GlinetException ? e.message : e.toString());
      }
    } finally {
      if (mounted) setState(() => _glinetBusy = false);
    }
  }

  Future<void> _glinetConnect() async {
    final password = _glinetPass.text;
    if (password.isEmpty) {
      setState(() =>
          _glinetError = 'Enter the router admin password (session-only).');
      return;
    }
    setState(() {
      _glinetBusy = true;
      _glinetError = null;
      _glinetProbeResult = null;
    });
    try {
      final router = _newGlinetRouter();
      await router.login(
        username: _glinetUser.text.trim().isEmpty
            ? 'root'
            : _glinetUser.text.trim(),
        password: password,
      );
      final info = await router.routerInfo();
      final status = await router.routerStatus();
      final load = await router.routerLoad();
      final clients = await router.listClients();
      if (mounted) {
        setState(() {
          _glinetInfo = info;
          _glinetStatus = status;
          _glinetLoad = load;
          _glinetClients = clients;
        });
      }
    } on GlinetException catch (e) {
      if (mounted) setState(() => _glinetError = e.message);
    } catch (e) {
      if (mounted) setState(() => _glinetError = e.toString());
    } finally {
      if (mounted) setState(() => _glinetBusy = false);
    }
  }

  Future<void> _glinetDisconnect() async {
    final router = _glinetRouter;
    setState(() {
      _glinetBusy = true;
    });
    try {
      await router?.logout();
    } catch (_) {
      // Best effort — the session is forgotten locally regardless.
    } finally {
      router?.close();
    }
    if (!mounted) return;
    setState(() {
      _glinetRouter = null;
      _glinetInfo = null;
      _glinetStatus = null;
      _glinetLoad = null;
      _glinetClients = [];
      _glinetProbeResult = null;
      _glinetError = null;
      _glinetBusy = false;
    });
    _glinetPass.clear();
  }

  String _fmtUptime(double seconds) {
    final total = seconds.round();
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }

  // ---- Shared builders (glass purple throughout this screen) ----

  Widget _section(String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: OutrideGlassPanel(
        tint: OutrideColors.purple,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title.toUpperCase(), style: OutrideType.section()),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String label, String hint,
      {bool numeric = false, ValueChanged<String>? onChanged}) {
    return TextField(
      controller: c,
      onChanged: onChanged,
      style: OutrideType.rowValue(OutrideColors.onDark),
      decoration:
          InputDecoration(labelText: label.toUpperCase(), hintText: hint),
      keyboardType: numeric
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
    );
  }
}
