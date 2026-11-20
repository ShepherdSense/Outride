import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/build_age.dart';
import '../services/health.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'dashboard.dart' show eventSizeColor;
import 'events_list_screen.dart';
import 'fleet_screen.dart';
import 'hunt_screen.dart';
import 'radios_links_screen.dart';

/// Picture — the one-glance watch view. Answers one question: is
/// anything coming, where, and how far? Top to bottom: status banner,
/// nearest-event card, one big START/STOP, fleet chip, voice row,
/// 3-event timeline tail.
///
/// Honesty contract, same as the old Alerts tab this replaces:
/// direction, distance, speed and heading come ONLY from the fused
/// track estimate ([AppState.track]) — null fields are shown as "—",
/// never invented. With 2 radios the app is a single-link tripwire:
/// it can say a link was disturbed and how big the dip was, not where
/// the mover is. The banner states follow proposal §4
/// (outride-ui-simplification.md), building on the old Alerts tab's
/// precedence — a detection always wins, a failed or partial system
/// is never green, CLEAR only when the system can vouch. POSSIBLE
/// MOVEMENT (amber) and TRACK (red, only when a fused track is
/// INBOUND) are new Picture states: the old panel titled the
/// detected state DETECTED and had no TRACK state at all.
class PictureScreen extends StatelessWidget {
  const PictureScreen({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _statusBanner(),
            const SizedBox(height: 12),
            _radiosLinksRow(context),
            const SizedBox(height: 12),
            _nearestEventCard(),
            const SizedBox(height: 12),
            _startStopButton(),
            const SizedBox(height: 12),
            _fleetChip(context),
            if (buildAgeWarning(now: DateTime.now()) != null) ...[
              const SizedBox(height: 12),
              _buildAgeBanner(),
            ],
            const SizedBox(height: 12),
            _voiceRow(context),
            const SizedBox(height: 12),
            _timelineTail(context),
            const SizedBox(height: 12),
            const _ScopeNote(),
          ],
        );
      },
    );
  }

  /// Banner state, per proposal §4: a detection always wins;
  /// otherwise a failed or partial system is never green; CLEAR only
  /// when the system can vouch. POSSIBLE MOVEMENT (amber) is a
  /// disturbed link with no fused track; TRACK (red) needs a fused
  /// track that is INBOUND. (The old Alerts tab's panel titled the
  /// detected state DETECTED and had no TRACK state.)
  ({Color color, IconData icon, String title, String subtitle})
      _bannerState() {
    final disturbed = state.disturbedLinks;
    final idle = !state.polling;
    final detected = !idle && disturbed.isNotEmpty;
    final h = state.health;
    final t = state.track;
    if (idle) {
      return (
        color: OutrideColors.muted,
        icon: Icons.pause_circle_outline,
        title: 'PAUSED',
        subtitle: 'PRESS START TO BEGIN MONITORING',
      );
    }
    if (detected && t != null && t.relation == 'INBOUND') {
      return (
        color: OutrideColors.red,
        icon: Icons.flight_takeoff,
        title: 'TRACK',
        subtitle: 'TRACK — INBOUND · ${t.headingCompass} '
            '${t.headingDeg?.toStringAsFixed(0) ?? '—'}° · '
            '${t.speedMps?.toStringAsFixed(1) ?? '—'} M/S',
      );
    }
    if (detected) {
      return (
        color: OutrideColors.amber,
        icon: Icons.warning_amber_rounded,
        title: 'POSSIBLE MOVEMENT',
        subtitle: '${disturbed.length} LINK DIRECTION(S) DISTURBED',
      );
    }
    if (h.level == Coverage.blind) {
      return (
        color: OutrideColors.red,
        icon: Icons.sensors_off,
        title: 'NO DATA',
        subtitle: 'NOT MONITORING — CLEAR CANNOT BE ASSUMED',
      );
    }
    if (h.level == Coverage.degraded) {
      return (
        color: OutrideColors.orange,
        icon: Icons.error_outline,
        title: 'DEGRADED',
        subtitle: 'CLEAR ON ${h.liveLinks} OF ${h.expectedLinks} '
            'LINK DIRECTION(S)',
      );
    }
    if (h.level == Coverage.starting) {
      return (
        color: OutrideColors.muted,
        icon: Icons.hourglass_empty,
        title: 'STARTING',
        subtitle: 'WAITING FOR LINK DATA',
      );
    }
    return (
      color: OutrideColors.green,
      icon: Icons.shield_outlined,
      title: 'CLEAR',
      subtitle: 'MONITORING ${h.liveLinks} LINK DIRECTION(S)',
    );
  }

  Widget _statusBanner() {
    final b = _bannerState();
    final live = !state.settings.simulatedMode;
    return OutridePanel(
      glow: b.color,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('PERIMETER STATUS', style: OutrideType.section()),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  border: Border.all(color: OutrideColors.border),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: live
                            ? OutrideColors.green
                            : OutrideColors.orange,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      live ? 'LIVE' : 'SIM',
                      style: OutrideType.chip(live
                              ? OutrideColors.green
                              : OutrideColors.orange)
                          .copyWith(fontSize: 10),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(b.icon, color: b.color, size: 52),
              const SizedBox(width: 16),
              Expanded(
                // Long titles ("POSSIBLE MOVEMENT") shrink to fit one
                // line instead of overflowing a narrow phone.
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    b.title,
                    style: OutrideType.readout(32, b.color)
                        .copyWith(letterSpacing: 3),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(b.subtitle, style: OutrideType.section(11)),
        ],
      ),
    );
  }

  /// Nearest event: the latest crossing plus the fused track's
  /// direction / distance / speed / heading when a track exists.
  /// Without a track those rows read "—" — position, heading and
  /// speed need 3+ mesh nodes and are never guessed from one link.
  Widget _nearestEventCard() {
    if (state.events.isEmpty) {
      return OutridePanel(
        child: Row(
          children: [
            const Icon(Icons.radar,
                color: OutrideColors.muted, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('NEAREST EVENT', style: OutrideType.section()),
                  const SizedBox(height: 6),
                  Text('NO CROSSINGS DETECTED YET',
                      style: OutrideType.rowLabel()),
                ],
              ),
            ),
          ],
        ),
      );
    }
    final e = state.events.first;
    final t = state.track;
    final sizeColor = eventSizeColor(e.sizeEstimate);
    final distM = t == null
        ? null
        : math.sqrt(math.pow(t.x - state.defended.x, 2) +
            math.pow(t.y - state.defended.y, 2));
    return OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('NEAREST EVENT', style: OutrideType.section()),
              const Spacer(),
              OutrideChip(label: 'SIZE ${e.sizeEstimate}', color: sizeColor),
            ],
          ),
          const SizedBox(height: 12),
          _dataRow('TIME', _fmtTime(e.timestamp), OutrideColors.onDark),
          const SizedBox(height: 6),
          _dataRow(
              'DIRECTION',
              t == null
                  ? '—'
                  : '${t.headingCompass} '
                      '${t.headingDeg?.toStringAsFixed(0) ?? '—'}°',
              OutrideColors.onDark),
          const SizedBox(height: 6),
          _dataRow(
              'DISTANCE',
              distM == null
                  ? '—'
                  : '≈ ${distM.toStringAsFixed(0)} M FROM DEFENDED (EST)',
              OutrideColors.onDark),
          const SizedBox(height: 6),
          _dataRow(
              'SPEED',
              t?.speedMps == null
                  ? '—'
                  : '${t!.speedMps!.toStringAsFixed(1)} M/S (EST)',
              OutrideColors.onDark),
          const SizedBox(height: 6),
          _dataRow(
              'MOVEMENT',
              t?.relation ?? '—',
              t?.relation == 'INBOUND'
                  ? OutrideColors.red
                  : OutrideColors.onDark),
          const SizedBox(height: 6),
          _dataRow('LINK', shortLinkKey(e.linkKey), OutrideColors.onDark),
          const SizedBox(height: 6),
          _dataRow('DIP', '-${e.dipDepth.toStringAsFixed(0)} EST',
              OutrideColors.red),
          const SizedBox(height: 6),
          _dataRow(
              'AI CLASSIFY',
              e.aiLabel == null
                  ? '—'
                  : e.aiConfidence == null
                      ? '${e.aiLabel} EST'
                      : '${e.aiLabel} ${(e.aiConfidence! * 100).toStringAsFixed(0)}% EST',
              OutrideColors.purple),
          if (t == null) ...[
            const SizedBox(height: 10),
            Text(
              'DIRECTION · DISTANCE · SPEED NEED 3+ NODES — WITH 2 '
              'RADIOS THIS IS A SINGLE-LINK TRIPWIRE.',
              style: OutrideType.section(9),
            ),
          ],
          const SizedBox(height: 10),
          Text(
            'SIZE AND AI LABELS ARE HEURISTIC ESTIMATES, NOT IDENTIFICATION.',
            style: OutrideType.section(9),
          ),
        ],
      ),
    );
  }

  Widget _dataRow(String label, String value, Color color) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
            width: 110, child: Text(label, style: OutrideType.rowLabel())),
        Expanded(child: Text(value, style: OutrideType.rowValue(color))),
      ],
    );
  }

  /// One big action, full width, 56 px tall. The theme's transparent
  /// purple style — never a solid block.
  Widget _startStopButton() {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: state.polling ? state.stop : state.start,
        child: Text(state.polling ? 'STOP' : 'START'),
      ),
    );
  }

  /// Fleet chip: one-line fleet status, tap opens the Fleet screen
  /// (PIN dialer lives there, unchanged). Same as the old Alerts tab.
  Widget _fleetChip(BuildContext context) {
    final inFleet = state.inFleet;
    return InkWell(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => FleetScreen(state: state),
          ),
        );
      },
      child: OutridePanel(
        child: Row(
          children: [
            Icon(Icons.group,
                color: inFleet ? OutrideColors.green : OutrideColors.muted,
                size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                state.fleetSummary,
                style: OutrideType.chip(
                    inFleet ? OutrideColors.green : OutrideColors.muted),
              ),
            ),
            const Icon(Icons.chevron_right,
                color: OutrideColors.purple, size: 18),
          ],
        ),
      ),
    );
  }

  Widget _buildAgeBanner() {
    final warning = buildAgeWarning(now: DateTime.now())!;
    return OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'BUILD AGE',
            style: OutrideType.section().copyWith(
              color: OutrideColors.amber,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            warning,
            style: OutrideType.section(10).copyWith(height: 1.6),
          ),
        ],
      ),
    );
  }

  /// Voice alerts mute toggle + Hunt entry. Voice is the ideal the
  /// screen is measured against: the operator should be able to run
  /// a watch with the screen off and the voice on.
  Widget _voiceRow(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            style: OutrideButtons.outline,
            onPressed: state.toggleAlerts,
            icon: Icon(
              state.alertsEnabled ? Icons.volume_up : Icons.volume_off,
              size: 18,
            ),
            label: Text(state.alertsEnabled ? 'ALERTS ON' : 'MUTED'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            style: OutrideButtons.outline,
            icon: const Icon(Icons.whatshot, size: 18),
            label: const Text('HUNT'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => HuntScreen(state: state),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Compact radios + mesh-links status, tap to open the full panels
  /// (moved from the old Alerts tab — see [RadiosLinksScreen]).
  Widget _radiosLinksRow(BuildContext context) {
    final drivers = state.driverStatuses.length;
    final links = state.history.length;
    final disturbed = state.disturbedLinks.length;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => RadiosLinksScreen(state: state),
        ),
      ),
      child: OutridePanel(
        child: Row(
          children: [
            Icon(Icons.sensors,
                color: disturbed > 0
                    ? OutrideColors.amber
                    : OutrideColors.muted,
                size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'RADIOS $drivers · LINKS $links'
                '${disturbed > 0 ? ' · $disturbed DISTURBED' : ''}',
                style: OutrideType.chip(disturbed > 0
                    ? OutrideColors.amber
                    : OutrideColors.muted),
              ),
            ),
            const Icon(Icons.chevron_right,
                color: OutrideColors.purple, size: 18),
          ],
        ),
      ),
    );
  }

  /// Last three events, newest first, one line each. Tap anywhere —
  /// or SEE ALL — to open the full crossing-events list with triage.
  Widget _timelineTail(BuildContext context) {
    final tail = state.events.take(3).toList();
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => EventsListScreen(state: state),
        ),
      ),
      child: OutridePanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('LATEST EVENTS', style: OutrideType.section()),
                const Spacer(),
                Text('SEE ALL', style: OutrideType.section(10)),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right,
                    color: OutrideColors.purple, size: 16),
              ],
            ),
            const SizedBox(height: 10),
            if (tail.isEmpty)
              Text('NO EVENTS YET', style: OutrideType.rowLabel())
            else
              for (final e in tail)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    children: [
                      Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: eventSizeColor(e.sizeEstimate),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '${_fmtTime(e.timestamp)} · ${shortLinkKey(e.linkKey)} · '
                          'SIZE ${e.sizeEstimate} EST · DIP -${e.dipDepth.toStringAsFixed(0)} EST',
                          style: OutrideType.rowValue(OutrideColors.onDark)
                              .copyWith(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }

  String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
}

class _ScopeNote extends StatelessWidget {
  const _ScopeNote();

  @override
  Widget build(BuildContext context) {
    return OutridePanel(
      child: Text(
        'SCOPE — WITH 2 RADIOS THIS IS A SINGLE-LINK TRIPWIRE: CROSSING ALERTS '
        'PLUS A CRUDE SIZE ESTIMATE (S/M/L) FROM THE DIP. TYPE, HEADING, SPEED '
        'AND POSITION NEED 3+ MESH NODES; THOSE READOUTS UNLOCK AS RADIOS JOIN.',
        style: OutrideType.section(10).copyWith(height: 1.6),
      ),
    );
  }
}
