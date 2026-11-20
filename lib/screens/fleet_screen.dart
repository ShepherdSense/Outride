/// Fleet screen — Outride v0.28.0 auto-mesh (spec §7).
///
/// Reached from Settings (8 tabs already fill the nav bar — no 9th
/// tab). Top shows own status + role badge + member count; middle
/// lists joined EUDs (callsign, role, link state, last-seen) then
/// fleets heard but not joined; bottom is a big dialer pad (1–9, 0,
/// four filled dots, backspace). "Create fleet" for the lead;
/// joining is tap-a-fleet → dial 4 digits → auto-submit on the 4th.
/// No keyboard, no IP field, no second app, no terminal. Failure
/// states in plain words, never a code. Dark mode, purple accents.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../services/fleet_dialer.dart';
import '../services/fleet_service.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'fleet_chat_screen.dart';

class FleetScreen extends StatefulWidget {
  const FleetScreen({super.key, required this.state});

  final AppState state;

  @override
  State<FleetScreen> createState() => _FleetScreenState();
}

class _FleetScreenState extends State<FleetScreen> {
  final FleetDialerState _dialer = FleetDialerState();
  FleetHeard? _joinTarget;
  bool _dialerVisible = false;
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    // Opening Fleet starts listening (spec §8): beacons are heard
    // from here on, and a remembered fleet auto-rejoins on sight.
    unawaited(widget.state.ensureFleetListening());
  }

  AppState get _state => widget.state;
  FleetService get _fleet => _state.fleetService;

  void _onDigit(String d) {
    if (_busy) return;
    setState(() {
      if (_dialer.addDigit(d) && _dialer.isComplete) {
        _submitPin();
      }
    });
  }

  void _onBackspace() {
    if (_busy) return;
    setState(_dialer.backspace);
  }

  Future<void> _submitPin() async {
    final pin = _dialer.digits;
    setState(() {
      _busy = true;
      _message = null;
    });
    bool ok;
    if (_joinTarget != null) {
      ok = await _state.joinFleet(_joinTarget!, pin);
    } else {
      try {
        await _state.createFleet(pin);
        ok = true;
      } catch (_) {
        ok = false;
      }
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _dialer.clear();
      if (ok) {
        _dialerVisible = false;
        _joinTarget = null;
        _message = null;
      } else {
        // One message for every join failure: wrong PIN, timeout,
        // or a member-side lockout (silent by design — no oracle).
        _message = 'Wrong PIN — try again';
      }
    });
  }

  Future<void> _forget() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: OutrideColors.surface,
        title: const Text('FORGET FLEET?'),
        content: const Text(
          'This EUD leaves the fleet and forgets it. The fleet '
          'key is deleted. You will need the 4-digit PIN to join '
          'again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('FORGET'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    await _state.forgetFleet();
    if (!mounted) return;
    setState(() {
      _dialerVisible = false;
      _joinTarget = null;
      _message = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('FLEET')),
      body: ListenableBuilder(
        listenable: _state,
        builder: (context, _) {
          final inFleet = _fleet.inFleet;
          final peers = _fleet.peers;
          final heard = _fleet.heardFleets;
          final now = DateTime.now();
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _statusPanel(inFleet, peers.length),
              const SizedBox(height: 12),
              _sectionTitle('JOINED EUDS'),
              const SizedBox(height: 8),
              _selfRow(),
              for (final p in peers) ...[
                const SizedBox(height: 8),
                _peerRow(p, now),
              ],
              if (inFleet && peers.isEmpty) ...[
                const SizedBox(height: 8),
                const Text(
                  'Only this EUD so far — other EUDs join by '
                  'dialing the same 4-digit PIN.',
                  style: TextStyle(
                      color: OutrideColors.muted, fontSize: 12),
                ),
              ],
              if (!inFleet) ...[
                const SizedBox(height: 16),
                _sectionTitle('FLEETS HEARD'),
                const SizedBox(height: 8),
                if (heard.isEmpty)
                  Text(
                    _fleet.heardNothing
                        ? 'No fleet heard — this network may block '
                            'device discovery (AP isolation).'
                        : 'Listening for fleets…',
                    style: const TextStyle(
                        color: OutrideColors.muted, fontSize: 12),
                  ),
                for (final h in heard) ...[
                  const SizedBox(height: 8),
                  _heardRow(h),
                ],
              ],
              const SizedBox(height: 16),
              if (_message != null) ...[
                Text(
                  _message!,
                  style: OutrideType.rowValue(OutrideColors.red),
                ),
                const SizedBox(height: 12),
              ],
              if (_busy)
                const Center(child: CircularProgressIndicator()),
              if (!_busy && !_dialerVisible && !inFleet) ...[
                ElevatedButton(
                  onPressed: () => setState(() {
                    _dialerVisible = true;
                    _joinTarget = null;
                    _dialer.clear();
                    _message = null;
                  }),
                  child: const Text('CREATE FLEET'),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Create a fleet with a 4-digit PIN. Other EUDs '
                  'hear it and join by dialing the same digits.',
                  style:
                      TextStyle(color: OutrideColors.muted, fontSize: 12),
                ),
              ],
              if (!_busy && _dialerVisible) ...[
                Text(
                  _joinTarget == null
                      ? 'DIAL A 4-DIGIT PIN TO CREATE THE FLEET'
                      : 'DIAL THE 4-DIGIT PIN TO JOIN '
                          'FLEET ${_joinTarget!.shortId.toUpperCase()}',
                  style: OutrideType.section(),
                ),
                const SizedBox(height: 12),
                FleetDialerPad(
                  digits: _dialer.digits,
                  onDigit: _onDigit,
                  onBackspace: _onBackspace,
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => setState(() {
                    _dialerVisible = false;
                    _joinTarget = null;
                    _dialer.clear();
                  }),
                  child: const Text('CANCEL'),
                ),
              ],
              if (!_busy && inFleet) ...[
                const SizedBox(height: 8),
                ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          FleetChatScreen(state: _state),
                    ),
                  ),
                  child: const Text('OPEN CHAT — EXPERIMENTAL'),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Fleet channel + direct messages. Encrypted '
                  'between fleet members only — no cloud, no '
                  'server. History is on this device only.',
                  style:
                      TextStyle(color: OutrideColors.muted, fontSize: 12),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: _forget,
                  child: const Text('FORGET FLEET'),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _sectionTitle(String title) =>
      Text(title, style: OutrideType.section());

  Widget _statusPanel(bool inFleet, int peerCount) {
    final rec = _fleet.record;
    final status = inFleet
        ? 'IN FLEET ${rec == null ? '' : rec.fleetId.substring(0, 6).toUpperCase()}'
        : 'NOT IN A FLEET';
    final role = _fleet.ownRoleLabel;
    return OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(status,
                    style: OutrideType.readout(
                        16,
                        inFleet
                            ? OutrideColors.green
                            : OutrideColors.muted)),
              ),
              _roleBadge(role),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            inFleet
                ? '${peerCount + 1} EUD${peerCount + 1 == 1 ? '' : 'S'} IN FLEET · '
                    'THIS EUD: ${_fleet.callsign}'
                : 'No fleet joined. Create one, or tap a fleet '
                    'below to join it.',
            style: const TextStyle(
                color: OutrideColors.muted, fontSize: 12),
          ),
          if (_fleet.lastError != null) ...[
            const SizedBox(height: 8),
            Text(
              _fleet.lastError!,
              style: const TextStyle(
                  color: OutrideColors.amber, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _roleBadge(String role) {
    final color =
        role == 'SENSING' ? OutrideColors.green : OutrideColors.blue;
    return OutrideChip(label: role, color: color);
  }

  Widget _selfRow() {
    return OutridePanel(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${_fleet.callsign} (THIS EUD)',
                    style: OutrideType.rowValue(OutrideColors.onDark)),
                const SizedBox(height: 4),
                const Text('THIS EUD',
                    style: TextStyle(
                        color: OutrideColors.muted, fontSize: 11)),
              ],
            ),
          ),
          _roleBadge(_fleet.ownRoleLabel),
          const SizedBox(width: 8),
          const OutrideChip(label: 'LIVE', color: OutrideColors.green),
        ],
      ),
    );
  }

  Widget _peerRow(FleetPeer p, DateTime now) {
    final link = p.linkStateAt(now);
    final linkColor = link == 'LIVE'
        ? OutrideColors.green
        : link == 'STALE'
            ? OutrideColors.amber
            : OutrideColors.red;
    // Tap a team member to open their DM thread (fleet chat,
    // EXPERIMENTAL). A peer row is otherwise display-only.
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => FleetChatScreen(
            state: _state,
            initialDmPeer: p.nodeId,
          ),
        ),
      ),
      child: OutridePanel(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.callsign,
                      style: OutrideType.rowValue(OutrideColors.onDark)),
                  const SizedBox(height: 4),
                  Text(
                    'LAST SEEN ${p.lastSeenSecondsAgo(now)}s AGO · '
                    '${p.memberCount} MEMBERS — TAP TO MESSAGE',
                    style: const TextStyle(
                        color: OutrideColors.muted, fontSize: 11),
                  ),
                ],
              ),
            ),
            _roleBadge(p.roleLabel),
            const SizedBox(width: 8),
            OutrideChip(label: link, color: linkColor),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right,
                color: OutrideColors.purple),
          ],
        ),
      ),
    );
  }

  Widget _heardRow(FleetHeard h) {
    final selected = _joinTarget?.fleetId == h.fleetId && _dialerVisible;
    return InkWell(
      onTap: _busy
          ? null
          : () => setState(() {
                _joinTarget = h;
                _dialerVisible = true;
                _dialer.clear();
                _message = null;
              }),
      child: OutridePanel(
        glow: selected ? OutrideColors.purple : null,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('FLEET ${h.shortId.toUpperCase()}',
                      style:
                          OutrideType.rowValue(OutrideColors.onDark)),
                  const SizedBox(height: 4),
                  Text(
                    '${h.memberCount} MEMBER${h.memberCount == 1 ? '' : 'S'} — TAP TO JOIN',
                    style: const TextStyle(
                        color: OutrideColors.muted, fontSize: 11),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right,
                color: OutrideColors.purple),
          ],
        ),
      ),
    );
  }
}
