import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/build_age.dart';
import '../services/health.dart';
import '../services/operator_pose.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../utils/field_map_transform.dart';
import 'dashboard.dart' show eventSizeColor;
import 'events_list_screen.dart';
import 'fleet_screen.dart';
import 'hunt_screen.dart';
import 'radios_links_screen.dart';
import 'tile_pack_layer.dart';
import 'tracking.dart';

/// Picture — the one-glance watch view. Answers one question: is
/// anything coming, where, and how far? Mock structure
/// (outride-ui-mock.html): centered verdict, compact live GPS map
/// where the mock's radar scope sits, 2x2 readout grid from the
/// nearest-event data, callout card, full-width fleet chip, node
/// health row — then the working controls the mock does not show:
/// START/STOP, radios/links, voice/HUNT, latest-events tail.
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
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
          children: [
            _statusBanner(),
            const SizedBox(height: 14),
            _LiveMapCard(state: state),
            const SizedBox(height: 14),
            _readoutGrid(),
            const SizedBox(height: 14),
            _callout(),
            if (state.events.isNotEmpty) ...[
              const SizedBox(height: 14),
              _eventDetail(),
            ],
            const SizedBox(height: 14),
            _startStopButton(),
            const SizedBox(height: 14),
            _fleetChip(context),
            if (buildAgeWarning(now: DateTime.now()) != null) ...[
              const SizedBox(height: 14),
              _buildAgeBanner(),
            ],
            const SizedBox(height: 14),
            _nodeHealthRow(),
            const SizedBox(height: 14),
            _radiosLinksRow(context),
            const SizedBox(height: 14),
            _voiceRow(context),
            const SizedBox(height: 14),
            _timelineTail(context),
            const SizedBox(height: 14),
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
  ({Color color, String title, String subtitle}) _bannerState() {
    final disturbed = state.disturbedLinks;
    final idle = !state.polling;
    final detected = !idle && disturbed.isNotEmpty;
    final h = state.health;
    final t = state.track;
    if (idle) {
      return (
        color: OutrideColors.muted,
        title: 'PAUSED',
        subtitle: 'PRESS START TO BEGIN MONITORING',
      );
    }
    if (detected && t != null && t.relation == 'INBOUND') {
      return (
        color: OutrideColors.red,
        title: 'TRACK',
        subtitle: 'TRACK — INBOUND · ${t.headingCompass} '
            '${t.headingDeg?.toStringAsFixed(0) ?? '—'}° · '
            '${t.speedMps?.toStringAsFixed(1) ?? '—'} M/S',
      );
    }
    if (detected) {
      return (
        color: OutrideColors.amber,
        title: 'POSSIBLE MOVEMENT',
        subtitle: '${disturbed.length} LINK DIRECTION(S) DISTURBED',
      );
    }
    if (h.level == Coverage.blind) {
      return (
        color: OutrideColors.red,
        title: 'NO DATA',
        subtitle: 'NOT MONITORING — CLEAR CANNOT BE ASSUMED',
      );
    }
    if (h.level == Coverage.degraded) {
      return (
        color: OutrideColors.orange,
        title: 'DEGRADED',
        // v0.29.2: the subtitle names the actual reason
        // (see degradedSubtitle) — never "CLEAR ON 12 OF 12"
        // under a DEGRADED banner.
        subtitle: degradedSubtitle(h),
      );
    }
    if (h.level == Coverage.starting) {
      return (
        color: OutrideColors.muted,
        title: 'STARTING',
        subtitle: 'WAITING FOR LINK DATA',
      );
    }
    return (
      color: OutrideColors.green,
      title: 'CLEAR',
      subtitle: 'MONITORING ${h.liveLinks} LINK DIRECTION(S)',
    );
  }

  /// Mock verdict: big centered title (34 px) + dim subtitle
  /// (17 px). The LIVE/SIM chip stays in the top row — the mock
  /// puts SIMULATED in the top bar, and the banner is the only
  /// place on this screen that still says which mode is live.
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
          Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                b.title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.5,
                  color: b.color,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            // The banner title doubles as the verdict word; the
            // subtitle is the plain-language reading of it.
            switch (b.title) {
              'CLEAR' => 'Nothing moving inside the perimeter.',
              'POSSIBLE MOVEMENT' =>
                'Something disturbed the RF field. Not confirmed yet.',
              'TRACK' => 'A fused track is closing on your position.',
              'DEGRADED' => b.subtitle,
              'NO DATA' => 'Not monitoring — clear cannot be assumed.',
              'STARTING' => 'Waiting for link data.',
              _ => 'Press START to begin monitoring.',
            },
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 17, color: OutrideColors.dim, height: 1.4),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(b.subtitle,
                textAlign: TextAlign.center,
                style: OutrideType.section(11)),
          ),
        ],
      ),
    );
  }

  /// 2x2 readout grid from the nearest-event data (mock .readout):
  /// Distance / Direction / Speed / Confidence. Every cell reads
  /// "—" without a fused track — position, heading and speed need
  /// 3+ mesh nodes and are never guessed from one link.
  Widget _readoutGrid() {
    final t = state.track;
    final e = state.events.isEmpty ? null : state.events.first;
    final distM = t == null
        ? null
        : math.sqrt(math.pow(t.x - state.defended.x, 2) +
            math.pow(t.y - state.defended.y, 2));
    final conf = state.trackConfidence?.displayed ?? e?.aiConfidence;
    return Column(
      children: [
        Row(
          children: [
            Expanded(
                child: _readoutCell('Distance',
                    distM == null ? '—' : '≈ ${distM.toStringAsFixed(0)} m')),
            const SizedBox(width: 10),
            Expanded(
                child: _readoutCell(
                    'Direction',
                    t == null
                        ? '—'
                        : '${t.headingCompass} '
                            '${t.headingDeg?.toStringAsFixed(0) ?? '—'}°')),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
                child: _readoutCell(
                    'Speed',
                    t?.speedMps == null
                        ? '—'
                        : '${t!.speedMps!.toStringAsFixed(1)} m/s')),
            const SizedBox(width: 10),
            Expanded(
                child: _readoutCell(
                    'Confidence',
                    conf == null
                        ? '—'
                        : '${(conf * 100).toStringAsFixed(0)}%')),
          ],
        ),
      ],
    );
  }

  Widget _readoutCell(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: OutrideColors.surface,
        border: Border.all(color: OutrideColors.border),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(),
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                  color: OutrideColors.faint)),
          const SizedBox(height: 4),
          Text(value,
              style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: OutrideColors.onDark)),
        ],
      ),
    );
  }

  /// Mock callout: title + body, border tinted by banner state.
  /// Carries the first honesty note when there is no fused track:
  /// direction / distance / speed need 3+ nodes. The second note
  /// (size and AI labels are heuristic estimates) lives in the
  /// scope note at the bottom of the screen.
  Widget _callout() {
    final b = _bannerState();
    final disturbed = state.disturbedLinks;
    final t = state.track;
    final e = state.events.isEmpty ? null : state.events.first;
    final String title;
    final String body;
    if (!state.polling) {
      title = 'Monitoring paused';
      body = 'Press START — nothing is being watched right now.';
    } else if (t != null && t.relation == 'INBOUND') {
      title = 'Act now — closing on you';
      final distM = math.sqrt(math.pow(t.x - state.defended.x, 2) +
          math.pow(t.y - state.defended.y, 2));
      final eta = t.speedMps != null && t.speedMps! > 0
          ? (distM / t.speedMps!).round()
          : null;
      body = 'A fused track is inbound from the ${t.headingCompass}, '
          'about ${distM.toStringAsFixed(0)} m out'
          '${eta != null ? ', roughly $eta seconds away' : ''}. '
          '${e?.aiLabel != null ? 'Possible ${e!.aiLabel} (estimate). ' : ''}'
          // Honest wording (v0.29.2 review): a fused track here
          // comes from disturbed mesh links alone — one RF
          // modality, no second sensor required — so the callout
          // must not claim two sensors corroborate.
          'A fused mesh track, not a maybe.';
    } else if (disturbed.isNotEmpty) {
      title = 'Possible movement — not confirmed';
      body = '${disturbed.length} link direction(s) disturbed. '
          'Direction, distance and speed need 3+ nodes — with 2 '
          'radios this is a single-link tripwire, so where it is '
          'cannot be said yet.';
    } else if (e == null) {
      title = 'Perimeter quiet';
      body = 'No crossings detected yet. Direction, distance and '
          'speed need 3+ nodes — with 2 radios this is a '
          'single-link tripwire.';
    } else {
      title = 'Latest crossing ${_fmtTime(e.timestamp)}';
      body = 'Size ${e.sizeEstimate} (estimate) · dip '
          '-${e.dipDepth.toStringAsFixed(0)} on ${shortLinkKey(e.linkKey)}. '
          'Size and AI labels are heuristic estimates, not identification.';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: OutrideColors.surface2,
        border: Border.all(color: b.color.withAlpha(120)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: OutrideColors.onDark)),
          const SizedBox(height: 2),
          Text(body,
              style: const TextStyle(
                  fontSize: 17, color: OutrideColors.onDark, height: 1.45)),
        ],
      ),
    );
  }

  /// Nearest-event detail rows (time / direction / distance /
  /// speed / movement / link / dip / AI classify), mock panel
  /// styling. Only when an event exists.
  Widget _eventDetail() {
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

  /// Fleet chip, mock style: full-width, surface-2, purple border,
  /// 60 px, main line 17 px + dim sub-line, chevron. Tap opens the
  /// Fleet screen (PIN dialer lives there, unchanged).
  Widget _fleetChip(BuildContext context) {
    final inFleet = state.inFleet;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => FleetScreen(state: state),
          ),
        );
      },
      child: Container(
        constraints: const BoxConstraints(minHeight: 60),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: OutrideColors.surface2,
          border: Border.all(color: OutrideColors.purpleStrong),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    state.fleetSummary,
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                        color: inFleet
                            ? OutrideColors.green
                            : OutrideColors.onDark),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    inFleet
                        ? 'Tap to view members, chat and fleet settings'
                        : 'Tap to join or manage the fleet with a 4-digit PIN',
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: OutrideColors.dim,
                        height: 1.35),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right,
                color: OutrideColors.faint, size: 22),
          ],
        ),
      ),
    );
  }

  /// Node health row (mock .fleet): one cell per node, dot + label.
  /// Dot color is link freshness (green/amber/red/grey), same
  /// derivation as the Field map health overlay.
  Widget _nodeHealthRow() {
    final nodes = state.effectiveNodes.values.toList();
    if (nodes.isEmpty) {
      return const Text('NO NODES YET — START POLLING FIRST',
          style: TextStyle(fontSize: 12, color: OutrideColors.faint));
    }
    final health = state.nodeHealthMap;
    return Row(
      children: [
        for (var i = 0; i < nodes.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
              decoration: BoxDecoration(
                color: OutrideColors.surface,
                border: Border.all(color: OutrideColors.border),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: switch (health[nodes[i].nodeId]) {
                        NodeHealthStatus.ok => OutrideColors.green,
                        NodeHealthStatus.degraded => OutrideColors.amber,
                        NodeHealthStatus.dead => OutrideColors.red,
                        _ => OutrideColors.faint,
                      },
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${nodes[i].displayName.toUpperCase()} · '
                    '${switch (health[nodes[i].nodeId]) {
                      NodeHealthStatus.ok => 'SYNC',
                      NodeHealthStatus.degraded => 'STALE',
                      NodeHealthStatus.dead => 'DEAD',
                      _ => '—',
                    }}',
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: OutrideColors.dim),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
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

/// Compact live GPS map for the Picture screen: the same field map
/// as [TrackingScreen] (tile packs under the field overlay — nodes,
/// links, defended point, track, operator marker), at a glance.
/// Tapping it opens the full Field Map. The map is the live GPS map
/// by Draco's call: the operator marker is the live fix when one is
/// fresh, the labelled SIM demo anchor in simulated mode, and absent
/// (with an honest status line) when there is no position at all —
/// never a fake position.
///
/// WEB: tile packs are deliberately unsupported on web
/// ([TilePackStore.supported] is false there), so on web the layer
/// fetches USGS tiles live through the web loader instead (v0.29.3)
/// — Topo by default, Imagery as the alternate, held in memory
/// only. Offline or out of coverage, the field grid + live GPS
/// position still render and the status line says so. The visitor's
/// position stays in their browser — it is never sent, stored or
/// logged.
class _LiveMapCard extends StatefulWidget {
  const _LiveMapCard({required this.state});

  final AppState state;

  @override
  State<_LiveMapCard> createState() => _LiveMapCardState();
}

class _LiveMapCardState extends State<_LiveMapCard> {
  // Starts as web on web so the first frame never claims tiles are
  // unavailable there — the loader is the tile source, even before
  // its first tile lands.
  TileLayerStatus _tileStatus = const TileLayerStatus(web: kIsWeb);

  AppState get state => widget.state;

  void _openFullMap(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('FIELD MAP')),
          body: TrackingScreen(state: state),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final nodes = state.effectiveNodes.values.toList();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: OutrideColors.surface,
        border: Border.all(color: OutrideColors.border),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text('LIVE GPS MAP',
                    style: OutrideType.section(),
                    overflow: TextOverflow.ellipsis),
              ),
              IconButton(
                tooltip: 'FULL FIELD MAP',
                icon: const Icon(Icons.fullscreen,
                    color: OutrideColors.muted, size: 20),
                onPressed: () => _openFullMap(context),
              ),
            ],
          ),
          // LIVE GPS toggle on its own wrapping row: title +
          // toggle + fullscreen icon do not fit one 360 px row in
          // the mono section type (89 px overflow, v0.29.2).
          Wrap(
            spacing: 4,
            runSpacing: 0,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton(
                style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () {
                  if (state.liveGpsState == LiveGpsState.off ||
                      state.liveGpsState == LiveGpsState.denied ||
                      state.liveGpsState == LiveGpsState.unavailable) {
                    unawaited(state.startLiveGps());
                  } else {
                    unawaited(state.stopLiveGps());
                  }
                },
                child: Text(switch (state.liveGpsState) {
                  LiveGpsState.off => 'LIVE GPS OFF',
                  LiveGpsState.starting => 'LIVE GPS…',
                  LiveGpsState.live => 'LIVE GPS ON',
                  LiveGpsState.denied => 'LIVE GPS DENIED',
                  LiveGpsState.unavailable => 'LIVE GPS N/A',
                }),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: state.mapOperatorPosition == null
                    ? null
                    : () => state.setLiveGpsFollow(!state.liveGpsFollow),
                child: Text(
                    state.liveGpsFollow ? 'FOLLOW ON' : 'FOLLOW OFF'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // The range label below is computed from this map's
          // actual transform (visible width / scale), not a fixed
          // number: the fit extent varies with node spread.
          LayoutBuilder(
            builder: (context, constraints) {
              final mapSize = Size(constraints.maxWidth, 260);
              final mapPts = <math.Point<double>>[
                for (final n in nodes) math.Point(n.x, n.y),
                math.Point(state.defended.x, state.defended.y),
              ];
              final mapTrack = state.track;
              if (mapTrack != null) {
                mapPts.add(math.Point(mapTrack.x, mapTrack.y));
              }
              final mapFit =
                  FieldMapTransform.fit(mapSize, mapPts, zoom: 1.0);
              // Visible width in meters, rounded sensibly.
              final rangeM = mapSize.width / mapFit.scale;
              final rangeText = rangeM >= 1000
                  ? 'RANGE ≈ ${(rangeM / 1000).toStringAsFixed(1)} KM'
                  : 'RANGE ≈ ${rangeM.toStringAsFixed(0)} M';
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
          GestureDetector(
            onTap: () => _openFullMap(context),
            child: SizedBox(
              height: 260,
              width: double.infinity,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final size = Size(
                      constraints.maxWidth, constraints.maxHeight);
                  final pts = <math.Point<double>>[
                    for (final n in nodes)
                      math.Point(n.x, n.y),
                    math.Point(state.defended.x, state.defended.y),
                  ];
                  final t = state.track;
                  if (t != null) pts.add(math.Point(t.x, t.y));
                  final fit =
                      FieldMapTransform.fit(size, pts, zoom: 1.0);
                  final op = state.liveGpsFollow
                      ? state.mapOperatorMeters
                      : null;
                  final tr = op != null
                      ? FieldMapTransform.centered(
                          size: size,
                          centerX: op.x,
                          centerY: op.y,
                          scale: fit.scale,
                        )
                      : fit;
                  final origin = state.displayOrigin;
                  return Stack(
                    children: [
                      if (origin != null)
                        TilePackMapLayer(
                          transform: tr,
                          origin: origin,
                          size: size,
                          tilePacks: state.tilePacks,
                          webTiles: state.webTiles,
                          onStatus: (s) =>
                              setState(() => _tileStatus = s),
                        ),
                      CustomPaint(
                        size: size,
                        painter: TrackingMapPainter(
                          transform: tr,
                          nodes: nodes,
                          disturbedPairs: state.disturbedPairs,
                          defended: state.defended,
                          track: state.track,
                          shadow: state.shadow,
                          showShadow: true,
                          rti: state.rtiImage,
                          showRti: true,
                          operatorPos: state.mapOperatorMeters,
                          operatorAccuracyM:
                              state.mapOperatorAccuracyM,
                          operatorLive: state.mapOperatorIsLive,
                        ),
                      ),
                      const Positioned(
                        left: 8,
                        top: 8,
                        child: Text('N',
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: OutrideColors.faint)),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(rangeText,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12, color: OutrideColors.faint)),
              ),
              Flexible(
                child: Text(
                  state.track != null
                      ? 'TRACK ${state.track!.relation}'
                      : state.disturbedLinks.isNotEmpty
                          ? '${state.disturbedLinks.length} UNCONFIRMED CONTACT(S)'
                          : 'NO CONTACTS',
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                      fontSize: 12, color: OutrideColors.faint),
                ),
              ),
            ],
          ),
                ],
              );
            },
          ),
          const SizedBox(height: 6),
          Text(
            _mapStatusLine(),
            style: OutrideType.section(10),
          ),
          const SizedBox(height: 4),
          const Text('TAP THE MAP FOR THE FULL FIELD MAP',
              style: TextStyle(fontSize: 12, color: OutrideColors.faint)),
        ],
      ),
    );
  }

  /// One-line map status: where YOU are (live GPS / simulated /
  /// denied fallback) and what tiles are rendering. On web the
  /// tiles come from the live loader (v0.29.3) — packs are not
  /// available on web, but the map is no longer grid-only there.
  String _mapStatusLine() {
    final op = state.mapOperatorPosition;
    final String you;
    if (state.mapOperatorIsLive) {
      final acc = state.mapOperatorAccuracyM;
      you = 'YOU: LIVE GPS${acc != null ? ' ±${acc.toStringAsFixed(0)} M' : ''}'
          '${state.liveGpsFollow ? ' · FOLLOWING' : ''}';
    } else if (state.liveGpsState == LiveGpsState.denied ||
        state.liveGpsState == LiveGpsState.unavailable) {
      // "SIMULATED FALLBACK" is only true when a fallback marker
      // is actually drawn (simulated mode's demo anchor). Live
      // mode with GPS denied and no fix draws no YOU marker, so
      // the line must say NO POSITION instead (v0.29.2 review).
      you = op != null
          ? 'YOU: GPS ${state.liveGpsState == LiveGpsState.denied ? 'DENIED' : 'UNAVAILABLE'} — SIMULATED FALLBACK'
          : 'YOU: NO POSITION — TAP LIVE GPS';
    } else if (op != null) {
      you = 'YOU: SIMULATED (DEMO ANCHOR)';
    } else {
      you = 'YOU: NO POSITION — TAP LIVE GPS';
    }
    final String tiles;
    // A source name is shown only once at least one tile is
    // actually painted — a covering source with zero tiles loaded
    // (offline web, or a pack whose tiles all failed to decode)
    // reads as no tiles, not as a map that is there.
    if (_tileStatus.hasTiles && _tileStatus.tilesLoaded > 0) {
      tiles = 'TILES: ${_tileStatus.packName} · Z${_tileStatus.zoom}';
    } else if (_tileStatus.web) {
      // Web loader is the tile source but nothing loaded (offline,
      // or outside USGS coverage): the grid is the map, said plainly.
      tiles = 'TILES: WEB — NO TILES — GRID ONLY';
    } else if (!state.tilePacks.supported) {
      tiles = 'TILES: NOT AVAILABLE ON WEB — GRID ONLY';
    } else {
      tiles = 'TILES: NONE — GRID ONLY';
    }
    return '$you · $tiles';
  }
}

class _ScopeNote extends StatelessWidget {
  const _ScopeNote();

  @override
  Widget build(BuildContext context) {
    return OutridePanel(
      child: Text(
        'SCOPE — WITH 2 RADIOS THIS IS A SINGLE-LINK TRIPWIRE: CROSSING ALERTS '
        'PLUS A CRUDE SIZE ESTIMATE (S/M/L) FROM THE DIP. TYPE, HEADING, SPEED '
        'AND POSITION NEED 3+ MESH NODES; THOSE READOUTS UNLOCK AS RADIOS JOIN. '
        'SIZE AND AI LABELS ARE HEURISTIC ESTIMATES, NOT IDENTIFICATION.',
        style: OutrideType.section(10).copyWith(height: 1.6),
      ),
    );
  }
}
