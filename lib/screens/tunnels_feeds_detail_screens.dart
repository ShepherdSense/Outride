import 'dart:async';

import 'package:flutter/material.dart';

import '../services/cloudflare_auto.dart';
import '../services/tailscale_detect.dart';
import '../services/zerotier_detect.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'zmeta_join_dialog.dart';

/// Tunnels & Feeds detail screens (v0.30.1): one deeper screen per
/// row of the "Tunnels & Feeds" section in Radios & Networks
/// (Sensors grid → Radios & Networks → detail). Every screen is the
/// same visual language as the R&N screen — Scaffold + AppBar +
/// ListView of glass-purple OutrideGlassPanel sections — and every
/// status line is read from live AppState / a local interface probe,
/// never synthetic data. Anything unverified on hardware is labelled
/// EXPERIMENTAL; anything still needed (a domain, a network ID) is
/// stated plainly instead of implied.

// ---- Shared builders (glass purple throughout these screens) ----

Widget _detailSection(String title, List<Widget> children) {
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

Widget _kv(String label, String value, {Color? valueColor}) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 130,
          child: Text(label, style: OutrideType.rowLabel()),
        ),
        Expanded(
          child: Text(value,
              style: OutrideType.rowValue(
                  valueColor ?? OutrideColors.onDark)),
        ),
      ],
    ),
  );
}

Widget _note(String text, {Color? color}) {
  return Text(
    text,
    style: OutrideType.section(10).copyWith(
        height: 1.6, color: color ?? OutrideColors.dim),
  );
}

Widget _tag(String text, Color color) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
    decoration: BoxDecoration(
      border: Border.all(color: color.withAlpha(128)),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(text,
        style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.5,
            color: color)),
  );
}

Widget _statusLine(String label, String value, Color color) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        SizedBox(
          width: 130,
          child: Text(label, style: OutrideType.rowLabel()),
        ),
        Expanded(
          child: Text(value,
              style: OutrideType.rowValue(color)),
        ),
      ],
    ),
  );
}

// ---- 1. WireGuard ----

/// WireGuard tunnel status. The tunnel itself comes from the external
/// WireGuard app — Outride cannot embed it and never claims to create
/// it. This screen only RECOGNIZES the tunnel: a local 10.99.0.x
/// address means the WireGuard app has the tunnel up. Re-check runs
/// AppState.evaluateWireguardPath (detection only — it never flips
/// the transport; a stored WireGuard join already owns it).
class WireguardDetailScreen extends StatefulWidget {
  const WireguardDetailScreen({super.key, required this.state});

  final AppState state;

  @override
  State<WireguardDetailScreen> createState() =>
      _WireguardDetailScreenState();
}

class _WireguardDetailScreenState extends State<WireguardDetailScreen> {
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    unawaited(widget.state.evaluateWireguardPath());
  }

  Future<void> _recheck() async {
    setState(() => _checking = true);
    await widget.state.evaluateWireguardPath();
    if (mounted) setState(() => _checking = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('WIREGUARD')),
      body: ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          final detected = widget.state.wireguardTunnelDetected;
          final address = widget.state.wireguardDetectedAddress;
          final s = widget.state.settings;
          final joined = s.zmetaJoinedPlatformId;
          final isWgTransport = s.zmetaTransport == 'wireguard';
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _detailSection('Tunnel', [
                _statusLine(
                  'TUNNEL',
                  detected == null
                      ? 'NOT PROBED'
                      : detected
                          ? 'UP'
                          : 'DOWN',
                  detected == null
                      ? OutrideColors.muted
                      : detected
                          ? OutrideColors.green
                          : OutrideColors.amber,
                ),
                _kv('LOCAL ADDRESS', address ?? '—'),
                _kv('TUNNEL POOL', '10.99.0.0/24'),
                const SizedBox(height: 8),
                _note(
                  'THE TUNNEL COMES FROM THE WIREGUARD APP — OUTRIDE '
                  'CANNOT CREATE IT. ACTIVATE THE TUNNEL IN THE '
                  'WIREGUARD APP (IMPORT THE .CONF FROM THE JOIN FLOW); '
                  'OUTRIDE RECOGNIZES IT HERE; THE STORED WIREGUARD '
                  'JOIN SELECTS THE TRANSPORT. '
                  'A 10.99.0.X ADDRESS ON THIS DEVICE MEANS THE TUNNEL '
                  'IS UP.'),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: _checking ? null : _recheck,
                  child:
                      Text(_checking ? 'Checking…' : 'Re-check tunnel'),
                ),
              ]),
              _detailSection('ZMeta link', [
                _kv('TRANSPORT', s.zmetaTransport.toUpperCase()),
                _kv('JOINED PLATFORM ID',
                    joined.isEmpty ? '— (NOT JOINED)' : joined),
                _kv('GATEWAY', '${s.zmetaHost}:${s.zmetaPort}'),
                const SizedBox(height: 8),
                if (!isWgTransport || joined.isEmpty)
                  _note(
                    'NO WIREGUARD JOIN IS STORED. JOIN WITH AN INVITE '
                    'CODE (ZMETA DETAIL → JOIN VIA INVITE CODE) TO GET '
                    'A TUNNEL CONFIG FROM THE HUB.',
                    color: OutrideColors.amber,
                  )
                else
                  _note(
                    'WIREGUARD JOIN STORED — THIS TRANSPORT IS NEVER '
                    'OVERRIDDEN BY THE CLOUDFLARE OR ZEROTIER PATHS.',
                    color: OutrideColors.green,
                  ),
              ]),
            ],
          );
        },
      ),
    );
  }
}

// ---- 2. Cloudflare ----

/// Cloudflare auto-path status. Wires the existing v0.29.7 auto-path
/// (cloudflare_auto.dart) — nothing here is rebuilt. Honest note: a
/// domain is still needed; without a stored Cloudflare-mode ingest
/// URL the screen says what is missing.
class CloudflareDetailScreen extends StatefulWidget {
  const CloudflareDetailScreen({super.key, required this.state});

  final AppState state;

  @override
  State<CloudflareDetailScreen> createState() =>
      _CloudflareDetailScreenState();
}

class _CloudflareDetailScreenState extends State<CloudflareDetailScreen> {
  bool _checking = false;

  Future<void> _recheck() async {
    setState(() => _checking = true);
    await widget.state.evaluateCloudflarePath();
    if (mounted) setState(() => _checking = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('CLOUDFLARE')),
      body: ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          final s = widget.state.settings;
          final url = s.zmetaIngestUrl;
          final host = Uri.tryParse(url.trim())?.host ?? '';
          final configured = isCloudflareIngestUrl(url, s.zmetaIngestFp);
          final reason = widget.state.cloudflarePathReason;
          final active = widget.state.cloudflarePathActive;
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _detailSection('Ingest path', [
                _kv('INGEST HOST', host.isEmpty ? '— (NONE STORED)' : host),
                _kv('INGEST URL',
                    url.isEmpty ? '— (NONE STORED)' : url),
                _statusLine(
                  'PROBE',
                  reason.toUpperCase(),
                  active
                      ? OutrideColors.green
                      : reason == 'offline'
                          ? OutrideColors.amber
                          : OutrideColors.muted,
                ),
                _kv('TRANSPORT', s.zmetaTransport.toUpperCase()),
                const SizedBox(height: 8),
                if (!configured)
                  _note(
                    'NOT CONFIGURED. THIS PATH NEEDS A DOMAIN: THE HUB '
                    'MUST SIT BEHIND CLOUDFLARED ON A PUBLIC DOMAIN '
                    'NAME, AND THE JOIN MUST RETURN A CLOUDFLARE-MODE '
                    'INGEST URL (CERTFP ‘-’). NO DOMAIN IS CONFIGURED YET, '
                    'SO THERE IS NOTHING TO PROBE — JOIN WITH AN '
                    'INVITE CODE FROM SUCH A HUB TO SET IT UP.',
                    color: OutrideColors.amber,
                  )
                else
                  _note(
                    'CLOUDFLARE-MODE INGEST URL STORED. THE AUTO-PATH '
                    'PROBES THE STORED HOST ONLY — NEVER A NEW '
                    'DESTINATION — AND SELECTS HTTPS WHEN IT ANSWERS. '
                    'A JOINED WIREGUARD OR ZEROTIER LINK IS NEVER '
                    'OVERRIDDEN.'),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: _checking ? null : _recheck,
                  child: Text(_checking ? 'Checking…' : 'Re-check'),
                ),
              ]),
              if (configured)
                _detailSection('Auto-path', [
                  SwitchListTile(
                    title: Text('CLOUDFLARE AUTO-PATH',
                        style: OutrideType.rowValue(OutrideColors.onDark)),
                    subtitle: Text(
                      'WHEN THE HUB IS UP, SWITCH TO IT AUTOMATICALLY. '
                      'TURN OFF TO STAY ON THE CURRENT LINK — YOU CAN '
                      'STILL CONNECT BY HAND WITH RE-CHECK.',
                      style:
                          OutrideType.section(10).copyWith(height: 1.6),
                    ),
                    value: s.zmetaCloudflareAuto,
                    onChanged: (v) async {
                      await widget.state.setCloudflareAuto(v);
                    },
                  ),
                  if (!s.zmetaCloudflareAuto)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: OutlinedButton(
                        onPressed: _checking
                            ? null
                            : () async {
                                setState(() => _checking = true);
                                await widget.state
                                    .connectCloudflarePathManually();
                                if (mounted) {
                                  setState(() => _checking = false);
                                }
                              },
                        child: const Text('Connect via Cloudflare'),
                      ),
                    ),
                ]),
            ],
          );
        },
      ),
    );
  }
}

// ---- 3. Tailscale (EXPERIMENTAL) ----

/// Tailscale tunnel detection + guidance only. There is NO Tailscale
/// ZMeta transport in this version: the screen reports whether a
/// 100.64.0.0/10 address is present and tells the operator how to
/// use it (join the tailnet in the Tailscale app, then paste the
/// hub's Tailscale IP as the ZMeta host). EXPERIMENTAL — unverified
/// on hardware. Caveat stated on-screen: a carrier CGNAT address can
/// also sit in 100.64.0.0/10, so UP is "an address in the range is
/// present", not proof the Tailscale app is running.
class TailscaleDetailScreen extends StatefulWidget {
  const TailscaleDetailScreen({
    super.key,
    required this.state,
    this.tunnelProbe,
    this.addressProbe,
  });

  final AppState state;

  /// Test seam; production passes nothing.
  final Future<bool?> Function()? tunnelProbe;

  /// Test seam; production passes nothing.
  final Future<String?> Function()? addressProbe;

  @override
  State<TailscaleDetailScreen> createState() =>
      _TailscaleDetailScreenState();
}

class _TailscaleDetailScreenState extends State<TailscaleDetailScreen> {
  bool? _up;
  String? _address;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    unawaited(_probe());
  }

  Future<void> _probe() async {
    setState(() => _checking = true);
    final up = await (widget.tunnelProbe ?? tailscaleTunnelUp)();
    final address = up == true
        ? await (widget.addressProbe ?? tailscaleLocalAddress)()
        : null;
    if (mounted) {
      setState(() {
        _up = up;
        _address = address;
        _checking = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('TAILSCALE')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _detailSection('Tunnel', [
            Row(children: [_tag('EXPERIMENTAL', OutrideColors.amber)]),
            const SizedBox(height: 8),
            _statusLine(
              'TUNNEL',
              _up == null
                  ? 'NOT PROBED'
                  : _up!
                      ? 'UP'
                      : 'NOT DETECTED',
              _up == null
                  ? OutrideColors.muted
                  : _up!
                      ? OutrideColors.green
                      : OutrideColors.amber,
            ),
            _kv('LOCAL ADDRESS', _address ?? '—'),
            _kv('TAILSCALE RANGE', '100.64.0.0/10 (CGNAT)'),
            const SizedBox(height: 8),
            _note(
              'DETECTION ONLY IN THIS VERSION — THERE IS NO TAILSCALE '
              'ZMETA TRANSPORT YET. UP MEANS A 100.64.X.X ADDRESS IS '
              'PRESENT ON THIS DEVICE; A CARRIER CGNAT ADDRESS CAN '
              'ALSO SIT IN THAT RANGE, SO CONFIRM IN THE TAILSCALE APP '
              'BEFORE TRUSTING IT.'),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _checking ? null : _probe,
              child: Text(_checking ? 'Checking…' : 'Re-check tunnel'),
            ),
          ]),
          _detailSection('How to use it', [
            _note(
              '1. JOIN THE TAILNET IN THE TAILSCALE APP ON THIS DEVICE '
              'AND ON THE HUB.\n'
              '2. IN THE TAILSCALE APP, NOTE THE HUB’S TAILSCALE IP '
              '(100.64.X.X).\n'
              '3. IN THE ZMETA DETAIL, SET THE GATEWAY HOST TO THAT IP '
              '(PORT 5555 UNLESS THE HUB SAYS OTHERWISE) AND ENABLE '
              'EXPORT.'),
            const SizedBox(height: 8),
            _kv('CURRENT ZMETA HOST', s.zmetaHost),
            _kv('CURRENT ZMETA PORT', '${s.zmetaPort}'),
            _kv('CURRENT TRANSPORT', s.zmetaTransport.toUpperCase()),
          ]),
        ],
      ),
    );
  }
}

// ---- 4. ZeroTier ----

/// ZeroTier tunnel status. Wires the existing v0.29.7 path
/// (zerotier_detect.dart + AppState.evaluateZerotierPath). The tunnel
/// itself comes from the ZeroTier One app; the network ID is read
/// from the stored join — this screen never runs its own join flow.
/// Honest note: without a stored network ID the screen says the
/// network ID is still needed.
class ZerotierDetailScreen extends StatefulWidget {
  const ZerotierDetailScreen({
    super.key,
    required this.state,
    this.addressProbe,
  });

  final AppState state;

  /// Test seam for the local-address probe; production passes nothing.
  final Future<String?> Function()? addressProbe;

  @override
  State<ZerotierDetailScreen> createState() =>
      _ZerotierDetailScreenState();
}

class _ZerotierDetailScreenState extends State<ZerotierDetailScreen> {
  String? _address;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final address =
        await (widget.addressProbe ?? zerotierLocalAddress)();
    if (mounted) setState(() => _address = address);
  }

  Future<void> _recheck() async {
    setState(() => _checking = true);
    await widget.state.evaluateZerotierPath();
    await _refresh();
    if (mounted) setState(() => _checking = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ZEROTIER')),
      body: ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          final s = widget.state.settings;
          final detected = widget.state.zerotierTunnelDetected;
          final reason = widget.state.zerotierPathReason;
          final networkId = s.zerotierNetworkId;
          final ztIp = s.zerotierIp;
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _detailSection('Tunnel', [
                _statusLine(
                  'TUNNEL',
                  reason == 'unavailable'
                      ? 'NOT PROBED'
                      : detected
                          ? 'UP'
                          : 'DOWN',
                  reason == 'unavailable'
                      ? OutrideColors.muted
                      : detected
                          ? OutrideColors.green
                          : OutrideColors.amber,
                ),
                _statusLine('PATH', reason.toUpperCase(),
                    widget.state.zerotierPathActive
                        ? OutrideColors.green
                        : OutrideColors.muted),
                _kv('LOCAL ADDRESS', _address ?? '—'),
                _kv('GATEWAY IP', kZerotierGatewayIp),
                _kv('MESH SUBNET', '10.99.1.0/24'),
                const SizedBox(height: 8),
                _note(
                  'THE TUNNEL COMES FROM THE ZEROTIER ONE APP — '
                  'OUTRIDE CANNOT CREATE IT. A 10.99.1.X ADDRESS ON '
                  'THIS DEVICE MEANS THE APP HAS JOINED THE NETWORK '
                  'AND THE INTERFACE IS LIVE.'),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: _checking ? null : _recheck,
                  child:
                      Text(_checking ? 'Checking…' : 'Re-check tunnel'),
                ),
              ]),
              _detailSection('Join', [
                _kv('NETWORK ID',
                    networkId.isEmpty ? '— (NONE STORED)' : networkId),
                _kv('NODE ID',
                    s.zerotierNodeId.isEmpty ? '—' : s.zerotierNodeId),
                if (ztIp.isNotEmpty)
                  _kv(
                    s.zerotierIpConfirmed &&
                            s.zerotierIpStatus == 'confirmed'
                        ? 'ZEROTIER IP (CONFIRMED)'
                        : 'RESERVED IP (NOT CONFIRMED)',
                    ztIp,
                  ),
                _kv('ZMETA TARGET',
                    s.zmetaTargetZt.isEmpty ? '—' : s.zmetaTargetZt),
                const SizedBox(height: 8),
                if (networkId.isEmpty)
                  _note(
                    'NO ZEROTIER JOIN IS STORED — A NETWORK ID IS '
                    'STILL NEEDED. JOIN WITH AN INVITE CODE (ZMETA '
                    'DETAIL → JOIN VIA INVITE CODE) AND ENTER THE '
                    'ZEROTIER NODE ID FROM THE ZEROTIER APP; THE HUB '
                    'RETURNS THE NETWORK ID.',
                    color: OutrideColors.amber,
                  )
                else if (ztIp.isNotEmpty && !s.zerotierIpConfirmed)
                  _note(
                    'THE HUB RESERVED $ztIp BUT THE CONTROLLER HAS NOT '
                    'CONFIRMED IT — IT IS NOT THE MESH’S ZEROTIER IP '
                    'UNTIL CONFIRMED. ASK THE HUB OPERATOR TO ASSIGN '
                    'THAT IP TO THE NODE IN THE CONTROLLER.',
                    color: OutrideColors.amber,
                  )
                else
                  _note(
                    'WHEN THE TUNNEL IS UP WITH THIS JOIN STORED, THE '
                    'TRANSPORT SELECTS ZEROTIER BY ITSELF. A STORED '
                    'WIREGUARD JOIN OUTRANKS IT AND IS NEVER '
                    'OVERRIDDEN.',
                    color: OutrideColors.green,
                  ),
              ]),
            ],
          );
        },
      ),
    );
  }
}

// ---- 5. Predator-RF (CoT feed) ----

/// Predator-RF CoT feed status. Surfaces the existing CoT feed
/// (shipped v0.18.0): the emitter listener (RX-only) and the track
/// publisher (emit-only). Read-only status plus the existing enable
/// controls — no new CoT stack is built here. Last-received info
/// comes from AppState's own status line and fresh-emitter evidence
/// lines; when nothing is in the window the screen says so instead
/// of inventing a reading.
class PredatorRfDetailScreen extends StatefulWidget {
  const PredatorRfDetailScreen({super.key, required this.state});

  final AppState state;

  @override
  State<PredatorRfDetailScreen> createState() =>
      _PredatorRfDetailScreenState();
}

class _PredatorRfDetailScreenState extends State<PredatorRfDetailScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('PREDATOR-RF')),
      body: ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          final s = widget.state.settings;
          final statusLine = widget.state.cotStatusLine;
          final evidence = widget.state.emitterEvidenceLines;
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _detailSection('CoT feed', [
                _statusLine(
                  'LISTEN',
                  s.cotListenEnabled ? 'ON' : 'OFF',
                  s.cotListenEnabled
                      ? OutrideColors.green
                      : OutrideColors.muted,
                ),
                _statusLine(
                  'EMIT',
                  s.cotEmitEnabled ? 'ON' : 'OFF',
                  s.cotEmitEnabled
                      ? OutrideColors.green
                      : OutrideColors.muted,
                ),
                _kv('LISTEN GROUP',
                    '${s.cotListenMulticastGroup}:${s.cotListenMulticastPort}'),
                _kv('EMIT DESTINATION', s.cotEmitUseMulticast
                    ? '${s.cotMulticastGroup}:${s.cotMulticastPort} (MULTICAST)'
                    : '${s.cotTakHost}:${s.cotTakPort} (TAK SERVER)'),
                _kv('EMITTER PREFIX', s.cotEmitterPrefix),
                _kv('OBSERVATION WINDOW',
                    '${s.cotListenWindowSeconds} S'),
                const SizedBox(height: 8),
                _note(
                  'CURSOR-ON-TARGET FEED FROM PREDATOR-RF EMITTERS, '
                  'SHIPPED IN V0.18.0. LISTEN IS RECEIVE-ONLY; EMIT '
                  'PUBLISHES THE FUSED TRACK ONLY. EMITTER READINGS '
                  'ARE COINCIDENT WITH A TRACK — NEVER CONFIRMED '
                  'IDENTITY.'),
                const SizedBox(height: 8),
                _kv('STATUS', statusLine ?? 'BOTH PATHS OFF'),
              ]),
              _detailSection('Last received', [
                if (evidence.isEmpty)
                  _note(
                    s.cotListenEnabled
                        ? 'LISTENING — NO EMITTER EVENTS IN THE CURRENT '
                            'WINDOW. NOTHING RECEIVED YET IS A REAL '
                            'READING, NOT A GAP TO FILL IN.'
                        : 'LISTEN IS OFF — ENABLE IT BELOW TO RECEIVE '
                            'EMITTER EVENTS.'),
                for (final line in evidence) _note(line),
              ]),
              _detailSection('Controls', [
                SwitchListTile(
                  title: Text('LISTEN FOR EMITTER TRACKS',
                      style: OutrideType.rowValue(OutrideColors.onDark)),
                  subtitle: Text(
                    'INGEST COT TRACKS MATCHING THE EMITTER PREFIX '
                    '(RX-ONLY). DEFAULT OFF.',
                    style: OutrideType.section(10).copyWith(height: 1.6),
                  ),
                  value: s.cotListenEnabled,
                  onChanged: (v) async {
                    await widget.state.setCotListenEnabled(v);
                  },
                ),
                SwitchListTile(
                  title: Text('EMIT COT TRACKS',
                      style: OutrideType.rowValue(OutrideColors.onDark)),
                  subtitle: Text(
                    'PUBLISH THE FUSED TRACK AS CURSOR-ON-TARGET '
                    'EVENTS. EMIT-ONLY, DEFENSIVE-ONLY. DEFAULT OFF.',
                    style: OutrideType.section(10).copyWith(height: 1.6),
                  ),
                  value: s.cotEmitEnabled,
                  onChanged: (v) async {
                    await widget.state.setCotEmitEnabled(v);
                  },
                ),
              ]),
            ],
          );
        },
      ),
    );
  }
}

// ---- 6. ZMeta ----

/// ZMeta ingest — core setup surfaced here. The full ZMeta section
/// stays in Settings; this screen hosts only the core fields (host,
/// port, transport readout, enable toggle) plus the existing join
/// dialog. Transport is a readout, never edited here — it is set by
/// the join flow and the tunnel auto-paths.
class ZmetaDetailScreen extends StatefulWidget {
  const ZmetaDetailScreen({super.key, required this.state});

  final AppState state;

  @override
  State<ZmetaDetailScreen> createState() => _ZmetaDetailScreenState();
}

class _ZmetaDetailScreenState extends State<ZmetaDetailScreen> {
  late final TextEditingController _host;
  late final TextEditingController _port;

  @override
  void initState() {
    super.initState();
    _host = TextEditingController(text: widget.state.settings.zmetaHost);
    _port = TextEditingController(
        text: widget.state.settings.zmetaPort.toString());
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  Future<void> _joinNetwork() async {
    final current = widget.state.settings.zmetaPlatformId.trim();
    final result = await showDialog<ZmetaJoinResult>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => ZmetaJoinDialog(
        initialPlatformId:
            current.isEmpty ? 'outride-mesh-1' : current,
      ),
    );
    if (result == null || !mounted) return;
    await widget.state.applyZmetaJoin(
      platformId: result.platformId,
      linkMode: result.linkMode,
      host: result.zmetaHost,
      port: result.zmetaPort,
      ingestUrl: result.ingestUrl,
      ingestFp: result.ingestFp,
      zerotierNetworkId: result.zerotierNetworkId,
      zerotierNodeId: result.zerotierNodeId,
      zerotierIp: result.zerotierIp,
      zerotierIpStatus: result.zerotierIpStatus,
      zerotierIpConfirmed: result.zerotierIpConfirmed,
      zerotierTarget: result.zmetaTargetZt,
    );
    if (!mounted) return;
    setState(() {
      _host.text = widget.state.settings.zmetaHost;
      _port.text = widget.state.settings.zmetaPort.toString();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.linkMode == 'zerotier'
            ? 'JOINED OVER ZEROTIER — ACTIVATE THE TUNNEL IN THE '
                'ZEROTIER APP. EXPORT STAYS OFF UNTIL YOU ENABLE IT.'
            : result.linkMode == 'https'
                ? 'JOINED OVER HTTPS — NO OTHER APP NEEDED. EXPORT '
                    'STAYS OFF UNTIL YOU ENABLE IT.'
                : 'JOINED — EXPORT STAYS OFF UNTIL YOU ENABLE IT.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ZMETA')),
      body: ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          final s = widget.state.settings;
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _detailSection('Gateway', [
                OutlinedButton.icon(
                  icon: const Icon(Icons.link,
                      color: OutrideColors.purple),
                  label: Text('JOIN VIA INVITE CODE',
                      style:
                          OutrideType.rowValue(OutrideColors.onDark)),
                  onPressed: _joinNetwork,
                ),
                const SizedBox(height: 4),
                _note(
                  'HAVE AN INVITE CODE? JOINING REGISTERS THIS MESH. '
                  'EXPORT STAYS OFF UNTIL YOU ENABLE IT BELOW.'),
                const SizedBox(height: 12),
                TextField(
                  controller: _host,
                  style: OutrideType.rowValue(OutrideColors.onDark),
                  decoration: const InputDecoration(
                      labelText: 'GATEWAY HOST',
                      hintText: 'e.g. 127.0.0.1'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _port,
                  style: OutrideType.rowValue(OutrideColors.onDark),
                  decoration: const InputDecoration(
                      labelText: 'GATEWAY UDP PORT',
                      hintText: 'e.g. 5555'),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: () async {
                    // Capture the messenger before the awaits: no
                    // BuildContext use across the async gap.
                    final messenger = ScaffoldMessenger.of(context);
                    await widget.state.setZmetaHost(_host.text);
                    await widget.state.setZmetaPort(
                        int.tryParse(_port.text.trim()) ?? s.zmetaPort);
                    if (mounted) {
                      messenger.showSnackBar(
                        const SnackBar(
                            content: Text('Gateway saved')),
                      );
                    }
                  },
                  child: const Text('Save gateway'),
                ),
              ]),
              _detailSection('Link', [
                _kv('TRANSPORT', s.zmetaTransport.toUpperCase()),
                _kv('PLATFORM ID', s.zmetaPlatformId),
                _kv('JOINED PLATFORM ID',
                    s.zmetaJoinedPlatformId.isEmpty
                        ? '— (NOT JOINED)'
                        : s.zmetaJoinedPlatformId),
                _kv('HEARTBEAT',
                    s.zmetaHeartbeatEnabled
                        ? 'ON — EVERY ${s.zmetaHeartbeatIntervalSec} S'
                        : 'OFF'),
                if (widget.state.zmetaPlatformMismatch)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _note(
                      'PLATFORM ID CHANGED — RE-JOIN THE NETWORK.',
                      color: OutrideColors.amber,
                    ),
                  ),
                if (s.zmetaTransport == 'https' &&
                    widget.state.zmetaIngestTokenRejected)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _note(
                      'HUB REJECTED THE TOKEN — RE-JOIN OR CONTACT THE '
                      'HUB OPERATOR.',
                      color: OutrideColors.red,
                    ),
                  ),
                const SizedBox(height: 8),
                _note(
                  'OPEN-STANDARD INGEST: EACH DETECTION IS SENT TO THE '
                  'HUB GATEWAY (EMIT-ONLY). TRANSPORT IS SET BY THE '
                  'JOIN AND THE TUNNEL AUTO-PATHS, NEVER BY HAND HERE.'),
              ]),
              _detailSection('Export', [
                SwitchListTile(
                  title: Text('EMIT ZMETA EVENTS',
                      style: OutrideType.rowValue(OutrideColors.onDark)),
                  subtitle: Text(
                    s.zmetaTransport == 'https'
                        ? 'SEND EACH DETECTION TO THE HUB OVER HTTPS '
                            '(EMIT-ONLY).'
                        : s.zmetaTransport == 'wireguard'
                            ? 'SEND EACH DETECTION TO A ZMETA GATEWAY '
                                'OVER WIREGUARD (EMIT-ONLY).'
                            : s.zmetaTransport == 'zerotier'
                                ? 'SEND EACH DETECTION TO A ZMETA '
                                    'GATEWAY OVER ZEROTIER (EMIT-ONLY).'
                                : 'SEND EACH DETECTION TO A ZMETA '
                                    'GATEWAY OVER UDP (EMIT-ONLY).',
                    style: OutrideType.section(10).copyWith(height: 1.6),
                  ),
                  value: s.zmetaEnabled,
                  onChanged: (v) async {
                    await widget.state.setZmetaEnabled(v);
                  },
                ),
              ]),
            ],
          );
        },
      ),
    );
  }
}
