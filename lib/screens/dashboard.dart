import 'package:flutter/material.dart';

import '../models/link_sample.dart';
import '../services/build_age.dart';
import '../services/health.dart';
import '../services/phone_tier.dart';
import '../services/radio_driver.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'events_list_screen.dart';
import 'fleet_screen.dart';
import 'hunt_screen.dart';
import 'radios_links_screen.dart';

/// Dot color for a crossing event's size estimate. Pure function so the
/// timeline and the detection card agree — and so it's unit-testable.
Color eventSizeColor(String sizeEstimate) => switch (sizeEstimate) {
      'S' => OutrideColors.blue,
      'M' => OutrideColors.amber,
      _ => OutrideColors.red,
    };

/// Events for the timeline strip: the last [n] events, oldest first.
/// Pure function so the mapping is unit-testable.
List<CrossingEvent> timelineEvents(List<CrossingEvent> events, [int n = 24]) {
  final take = events.length > n ? n : events.length;
  // events is newest-first; timeline reads oldest-first.
  return events.take(take).toList().reversed.toList();
}

/// Alert-first dashboard in the RuView observatory style: a floating
/// PERIMETER STATUS panel with a giant readout, a LATEST DETECTION panel
/// with technical rows, mesh link health, and the event log.
/// No spectrum charts — this screen answers one question: was something
/// detected? Dark mode only. All signal numbers are estimates
/// (radio-internal units).
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final disturbed = state.disturbedLinks;
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _alertPanel(disturbed),
            // v0.28.0 Fleet: one-line status chip — tap opens the
            // Fleet screen. `FLEET 3 · 2 SENSING` or `NOT IN A FLEET`.
            const SizedBox(height: 12),
            _fleetChip(context),
            // v0.27.1: soft build-age banner — visible ONLY once the
            // build is 90+ days old. A nudge to update, never a
            // lockout: sensing and alerts run exactly as before.
            if (buildAgeWarning(now: DateTime.now()) != null) ...[
              const SizedBox(height: 12),
              _buildAgeBanner(),
            ],
            // v0.26.0: phone-tier banner — visible ONLY when the tier
            // is actually active (switch on + no mesh/SDR hardware
            // attached). Mesh users never see it. Labels verbatim
            // from the tier service, never paraphrased.
            if (state.phoneTier.active) ...[
              const SizedBox(height: 12),
              _phoneTierBanner(context),
            ],
            const SizedBox(height: 12),
            _controlRow(context),
            const SizedBox(height: 12),
            RadiosCard(state: state),
            const SizedBox(height: 12),
            _latestDetection(),
            const SizedBox(height: 12),
            LinksCard(state: state, disturbed: disturbed),
            const SizedBox(height: 12),
            _spectrumCard(),
            if (state.hasSdrDriver) const SizedBox(height: 12),
            _timelineStrip(context),
            const SizedBox(height: 12),
            EventsListCard(state: state),
            const SizedBox(height: 12),
            const _ScopeNote(),
          ],
        );
      },
    );
  }

  /// The big one: CLEAR (shield) vs DETECTED (warning), observatory style.
  Widget _alertPanel(List<String> disturbed) {
    final h = state.health;
    final idle = !state.polling;
    final detected = !idle && disturbed.isNotEmpty;
    // CLEAR is only shown when the system can vouch for it. A detection
    // always wins; otherwise a failed or partial system is never green.
    final blind = !idle && !detected && h.level == Coverage.blind;
    final degraded = !idle && !detected && h.level == Coverage.degraded;
    final starting = !idle && !detected && h.level == Coverage.starting;
    final color = idle
        ? OutrideColors.muted
        : detected
            ? OutrideColors.amber
            : blind
                ? OutrideColors.red
                : degraded
                    ? OutrideColors.orange
                    : starting
                        ? OutrideColors.muted
                        : OutrideColors.green;
    final icon = idle
        ? Icons.pause_circle_outline
        : detected
            ? Icons.warning_amber_rounded
            : blind
                ? Icons.sensors_off
                : degraded
                    ? Icons.error_outline
                    : starting
                        ? Icons.hourglass_empty
                        : Icons.shield_outlined;
    final title = idle
        ? 'PAUSED'
        : detected
            ? 'DETECTED'
            : blind
                ? 'NO DATA'
                : degraded
                    ? 'DEGRADED'
                    : starting
                        ? 'STARTING'
                        : 'CLEAR';
    final subtitle = idle
        ? 'PRESS START TO BEGIN MONITORING'
        : detected
            ? '${disturbed.length} LINK DIRECTION(S) DISTURBED'
            : blind
                ? 'NOT MONITORING - CLEAR CANNOT BE ASSUMED'
                : degraded
                    ? degradedSubtitle(h)
                    : starting
                        ? 'WAITING FOR LINK DATA'
                        : 'MONITORING ${h.liveLinks} LINK DIRECTION(S)';
    final showReasons = !idle && h.reasons.isNotEmpty;
    final live = !state.settings.simulatedMode;
    return OutridePanel(
      glow: idle ? null : color,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('PERIMETER STATUS', style: OutrideType.section()),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 4),
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
                        color: live ? OutrideColors.green : OutrideColors.orange,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      live ? 'LIVE' : 'SIM',
                      style: OutrideType.chip(
                        live ? OutrideColors.green : OutrideColors.orange,
                      ).copyWith(fontSize: 10),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(icon, color: color, size: 52),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  title,
                  style: OutrideType.readout(40, color)
                      .copyWith(letterSpacing: 5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(subtitle, style: OutrideType.section(11)),
          if (detected) ...[
            const SizedBox(height: 8),
            Text(
              disturbed.join('  ·  '),
              style: OutrideType.rowValue(OutrideColors.amber)
                  .copyWith(fontSize: 11),
            ),
            const SizedBox(height: 6),
            Text(
              'HEURISTIC DETECTION — LINK DISTURBANCE CONFIRMED, '
              'NOT IDENTIFICATION. SIZE AND AI LABELS ARE ESTIMATES.',
              style: OutrideType.section(10).copyWith(
                  height: 1.6, color: OutrideColors.muted),
            ),
          ],
          if (showReasons) ...[
            const SizedBox(height: 8),
            for (final r in h.reasons.take(4))
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  r,
                  style: OutrideType.rowValue(
                    blind ? OutrideColors.red : OutrideColors.orange,
                  ).copyWith(fontSize: 11),
                ),
              ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              ElevatedButton(
                onPressed: state.polling ? state.stop : state.start,
                child: Text(state.polling ? 'STOP' : 'START'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: state.toggleAlerts,
                icon: Icon(
                  state.alertsEnabled ? Icons.volume_up : Icons.volume_off,
                  size: 18,
                ),
                label: Text(state.alertsEnabled ? 'ALERTS ON' : 'MUTED'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// v0.28.0 Fleet chip: one-line fleet status, tap opens the
  /// Fleet screen. `FLEET 3 · 2 SENSING` when joined, `NOT IN A
  /// FLEET` otherwise. Purple accent, same as the Fleet entry in
  /// Settings.
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
                color:
                    inFleet ? OutrideColors.green : OutrideColors.muted,
                size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                state.fleetSummary,
                style: OutrideType.chip(inFleet
                    ? OutrideColors.green
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

  /// v0.27.1 soft build-age banner. Amber, plain text, no button and
  /// no dismiss — it stays until the build is updated, which is the
  /// point. It never touches detection, health, or the alert panel.
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

  /// v0.26.0 phone-tier banner + Hunt entry point. The Hunt screen
  /// is pushed, not a tab, so the main tab bar stays untouched.
  /// Hunt is reachable from here even when the tier is inactive —
  /// the banner itself is tier-gated, the mode is not — via the
  /// button below (mesh users can hunt a phone-visible emitter too).
  Widget _phoneTierBanner(BuildContext context) {
    final tier = state.phoneTier;
    return OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${tier.modeLabel} · ${tier.rangeLabel}',
            style: OutrideType.section().copyWith(
              color: OutrideColors.purple,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            // v0.26.0 fix-pass: the source list renders from the
            // tier's actual availableSources — never a hardcoded
            // claim of all five when one is switched off.
            tier.availableSources.isEmpty
                ? 'PHONE SCANS ONLY — NO PHONE SOURCES CURRENTLY '
                    'AVAILABLE. NO MESH HARDWARE ATTACHED, SO THERE '
                    'IS NO AREA COVERAGE. NOTHING HEARD IS NOT '
                    'NOTHING PRESENT.'
                : 'PHONE SCANS ONLY — ${tier.availableSources.map((s) => s.label.toUpperCase()).join(', ')}. '
                    'NO MESH HARDWARE ATTACHED, SO THERE IS NO AREA '
                    'COVERAGE. NOTHING HEARD IS NOT NOTHING PRESENT.',
            style: OutrideType.section(10).copyWith(height: 1.6),
          ),
          if (tier.unavailableReason != null) ...[
            const SizedBox(height: 6),
            Text(
              tier.unavailableReason!.toUpperCase(),
              style: OutrideType.section(10).copyWith(
                color: OutrideColors.orange,
              ),
            ),
          ],
          const SizedBox(height: 10),
          ElevatedButton.icon(
            icon: const Icon(Icons.whatshot, color: OutrideColors.purple),
            label: const Text('OPEN HUNT — PROXIMITY ONLY'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => HuntScreen(state: state),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _controlRow(BuildContext context) {
    final live = !state.settings.simulatedMode;
    return OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('SOURCE', style: OutrideType.section()),
          const SizedBox(height: 10),
          _dataRow(
            live ? 'RADIO' : 'MODE',
            live ? state.settings.radioIp : 'SIMULATED LINK DATA',
            OutrideColors.blue,
          ),
          const SizedBox(height: 6),
          _dataRow('STATUS', state.connectionLabel, OutrideColors.muted),
          if (state.cotStatusLine != null) ...[
            const SizedBox(height: 6),
            _dataRow('COT', state.cotStatusLine!, OutrideColors.purple),
          ],
          if (state.error != null) ...[
            const SizedBox(height: 6),
            Text(state.error!,
                style: OutrideType.rowValue(OutrideColors.red)),
          ],
          // v0.26.0: Hunt entry for everyone, not just phone-tier
          // users — a mesh operator can still hunt a phone-visible
          // emitter. The phone-tier banner above is the tier-gated
          // surface; this button is the always-visible one.
          const SizedBox(height: 10),
          OutlinedButton.icon(
            icon: const Icon(Icons.whatshot, color: OutrideColors.purple),
            label: const Text('HUNT — PROXIMITY ONLY'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => HuntScreen(state: state),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _latestDetection() {
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
                  Text('LATEST DETECTION', style: OutrideType.section()),
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
    final sizeColor = eventSizeColor(e.sizeEstimate);
    return OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('LATEST DETECTION', style: OutrideType.section()),
              const Spacer(),
              OutrideChip(label: 'SIZE ${e.sizeEstimate}', color: sizeColor),
            ],
          ),
          const SizedBox(height: 12),
          _dataRow('TIME', fmtEventTime(e.timestamp), OutrideColors.onDark),
          const SizedBox(height: 6),
          _dataRow('LINK', shortLinkKey(e.linkKey), OutrideColors.onDark),
          const SizedBox(height: 6),
          _dataRow('DIP',
              '-${e.dipDepth.toStringAsFixed(0)} EST', OutrideColors.red),
          const SizedBox(height: 6),
          _dataRow('LASTED', e.durationLabel, OutrideColors.onDark),
          const SizedBox(height: 6),
          _dataRow(
              'AI CLASSIFY',
              e.aiLabel == null
                  ? '—'
                  : e.aiConfidence == null
                      ? '${e.aiLabel} EST'
                      : '${e.aiLabel} ${(e.aiConfidence! * 100).toStringAsFixed(0)}% EST',
              OutrideColors.purple),
          const SizedBox(height: 10),
          Text('SIZE AND AI LABELS ARE HEURISTIC ESTIMATES, NOT IDENTIFICATION. '
              'THE CLASSIFIER WAS TRAINED ON SYNTHETIC DATA.',
              style: OutrideType.section(9)),
        ],
      ),
    );
  }

  /// Label / value technical row, RuView style.
  Widget _dataRow(String label, String value, Color color) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 110, child: Text(label, style: OutrideType.rowLabel())),
        Expanded(
            child: Text(value, style: OutrideType.rowValue(color))),
      ],
    );
  }

  Widget _timelineStrip(BuildContext context) {
    final evts = timelineEvents(state.events);
    return OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('EVENT TIMELINE', style: OutrideType.section()),
              const Spacer(),
              Text(
                  evts.length < state.events.length
                      ? 'SHOWING ${evts.length} OF ${state.events.length} EVENTS'
                      : '${state.events.length} EVENTS',
                  style: OutrideType.section(10)),
            ],
          ),
          const SizedBox(height: 10),
          if (evts.isEmpty)
            Text('NO EVENTS YET', style: OutrideType.rowLabel())
          else ...[
            SizedBox(
              height: 56,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: evts.length,
                itemBuilder: (ctx, i) {
                  final e = evts[i];
                  return InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => openEvidenceSheet(context, state, e),
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: eventSizeColor(e.sizeEstimate),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(fmtEventTime(e.timestamp),
                              style: OutrideType.section(9)),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(fmtEventTime(evts.first.timestamp),
                    style: OutrideType.section(9)),
                Text('SIZE: S/M/L (EST)',
                    style: OutrideType.section(9)),
                Text(fmtEventTime(evts.last.timestamp),
                    style: OutrideType.section(9)),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _spectrumCard() {
    if (!state.hasSdrDriver) return const SizedBox.shrink();
    final bands = state.sdrBands;
    final disturbed = state.disturbedLinks.toSet();
    return OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('SPECTRUM BANDS', style: OutrideType.section()),
              const Spacer(),
              Text('ENERGY dBFS', style: OutrideType.section(10)),
            ],
          ),
          const SizedBox(height: 10),
          if (bands.isEmpty)
            Text('WAITING FOR SWEEP DATA',
                style: OutrideType.rowLabel()),
          for (final b in bands) _bandRow(b, disturbed),
          const SizedBox(height: 6),
          Text(
            'BAND-MEDIAN ENERGY, NOT A WATERFALL. LEVELS ARE ESTIMATES '
            '(dBFS, RECEIVER-RELATIVE — NOT dBm).',
            style: OutrideType.section(9),
          ),
        ],
      ),
    );
  }

  Widget _bandRow(SdrBand b, Set<String> disturbed) {
    // Same virtual link key the tripwire uses, so disturbance state
    // agrees between the panel and the detector.
    final linkKey = 'sdr:${b.radio} → sdr:band-${b.band}';
    final hot = disturbed.contains(linkKey);
    final color = hot ? OutrideColors.amber : OutrideColors.blue;
    // Bar scale: -100..-20 dBFS.
    double frac(double db) => ((db + 100) / 80).clamp(0.0, 1.0);
    final spanMhz = b.spanMhz ?? b.bwMhz;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(b.band.toUpperCase(),
                  style:
                      OutrideType.rowValue(OutrideColors.onDark)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${b.centerMhz.toStringAsFixed(1)} MHz · '
                  '${spanMhz.toStringAsFixed(1)} MHz SPAN'
                  '${b.sigHint != null ? ' · ${b.sigHint}' : ''}',
                  style: OutrideType.rowLabel()
                      .copyWith(fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '${b.energyDbfs.toStringAsFixed(1)} EST',
                style: OutrideType.rowValue(color)
                    .copyWith(fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 5),
          SizedBox(
            height: 10,
            child: LayoutBuilder(
              builder: (ctx, c) {
                return Stack(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: OutrideColors.surface2,
                        borderRadius: BorderRadius.circular(5),
                      ),
                    ),
                    FractionallySizedBox(
                      widthFactor: frac(b.energyDbfs),
                      child: Container(
                        decoration: BoxDecoration(
                          color: color.withAlpha(170),
                          borderRadius:
                              BorderRadius.circular(5),
                        ),
                      ),
                    ),
                    // Noise-floor marker (10th-percentile PSD).
                    Positioned(
                      left: (c.maxWidth * frac(b.noiseDbfs) - 1)
                          .clamp(0.0, c.maxWidth),
                      top: 0,
                      bottom: 0,
                      child: Container(
                          width: 2,
                          color: OutrideColors.muted),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
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
        'AND POSITION NEED 3+ MESH NODES; THOSE READOUTS UNLOCK AS RADIOS JOIN.',
        style: OutrideType.section(10).copyWith(height: 1.6),
      ),
    );
  }
}
