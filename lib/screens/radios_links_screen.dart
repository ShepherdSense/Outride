import 'package:flutter/material.dart';

import '../models/link_sample.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/animated_value_text.dart';
import '../widgets/link_dip_series_chart.dart';
import '../widgets/trip_state_indicator.dart';

/// Radios + mesh-links status, moved intact from the old Alerts tab
/// ([DashboardScreen]) when Picture replaced it. Reached from Picture
/// via the compact radios/links row under the banner.
class RadiosLinksScreen extends StatelessWidget {
  const RadiosLinksScreen({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final disturbed = state.disturbedLinks;
    return Scaffold(
      appBar: AppBar(title: const Text('RADIOS & MESH LINKS')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          RadiosCard(state: state),
          const SizedBox(height: 12),
          LinksCard(state: state, disturbed: disturbed),
          const SizedBox(height: 12),
          LinkDipSeriesCard(state: state, disturbed: disturbed),
        ],
      ),
    );
  }
}

/// Per-radio status: which drivers are polling, their link counts,
/// and any errors. The banner fires if ANY driver detects.
class RadiosCard extends StatelessWidget {
  const RadiosCard({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final statuses = state.driverStatuses;
    return OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('RADIOS', style: OutrideType.section()),
              const Spacer(),
              Text(
                state.settings.simulatedMode
                    ? 'SIMULATED'
                    : '${statuses.length} DRIVER${statuses.length == 1 ? '' : 'S'}',
                style: OutrideType.section(10).copyWith(
                    color: OutrideColors.muted),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (!state.polling)
            Text('NOT POLLING — PRESS START.',
                style: OutrideType.section(10)
                    .copyWith(color: OutrideColors.muted))
          else if (statuses.isEmpty)
            Text('NO RADIOS ENABLED — ADD ONE IN SETTINGS.',
                style: OutrideType.section(10)
                    .copyWith(color: OutrideColors.orange))
          else
            for (final s in statuses)
              Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: s.error != null
                            ? OutrideColors.red
                            : driverColor(s.driverId),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        s.label,
                        style: OutrideType.rowValue(
                                OutrideColors.onDark)
                            .copyWith(fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // Link count crossfades on change (motion
                    // layer) instead of jumping each poll.
                    AnimatedValueText(
                      value: s.error ?? '${s.linkCount} LINKS',
                      style: OutrideType.section(10).copyWith(
                          color: s.error != null
                              ? OutrideColors.red
                              : OutrideColors.muted),
                    ),
                  ],
                ),
              ),
          if (state.polling) _takLinkRow(),
        ],
      ),
    );
  }

  /// TAK/CoT emit link state, same card as the radios. Only shown
  /// while polling; OFF is dimmed, LINKED/MULTICAST are neutral,
  /// RETRYING is amber.
  Widget _takLinkRow() {
    final link = state.cotLinkStatus;
    final color = link == 'LINKED' || link == 'MULTICAST'
        ? OutrideColors.muted
        : link == 'RETRYING'
            ? OutrideColors.orange
            : OutrideColors.muted.withValues(alpha: 0.5);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: link == 'LINKED'
                  ? OutrideColors.green
                  : link == 'RETRYING'
                      ? OutrideColors.orange
                      : OutrideColors.muted.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'TAK LINK',
              style: OutrideType.rowValue(OutrideColors.onDark)
                  .copyWith(fontSize: 12),
            ),
          ),
          Text(
            link,
            style: OutrideType.section(10).copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

/// Per-link dip time series (FL Chart, v0.30.0): one link's dip
/// against time, with its trip threshold. Sits below the health rows
/// as an additive section — the existing UI above is untouched, and
/// the link×time heatmap stays a custom canvas.
///
/// The picker defaults to the first disturbed link (the one the
/// operator most likely wants to inspect), else the first link with
/// history. Shows the link's recent samples (history is capped at
/// [AppState.maxHistory] = 120 per link).
class LinkDipSeriesCard extends StatefulWidget {
  const LinkDipSeriesCard(
      {super.key, required this.state, required this.disturbed});

  final AppState state;
  final List<String> disturbed;

  @override
  State<LinkDipSeriesCard> createState() => _LinkDipSeriesCardState();
}

class _LinkDipSeriesCardState extends State<LinkDipSeriesCard> {
  String? _selected;

  List<String> get _keys {
    final keys = widget.state.history.keys.toList()..sort();
    return keys;
  }

  String? get _effectiveSelection {
    final keys = _keys;
    if (keys.isEmpty) return null;
    if (_selected != null && keys.contains(_selected)) return _selected;
    for (final d in widget.disturbed) {
      if (keys.contains(d)) return d;
    }
    return keys.first;
  }

  @override
  Widget build(BuildContext context) {
    final keys = _keys;
    final selected = _effectiveSelection;
    final List<LinkSample> samples = selected == null
        ? const <LinkSample>[]
        : widget.state.history[selected]!;
    return OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('LINK DIP HISTORY', style: OutrideType.section()),
              const Spacer(),
              // Tripwire lifecycle for the selected link, animated
              // (v0.30.0 motion layer): armed → tripped → confirmed →
              // cleared visibly transitions instead of flipping.
              if (selected != null)
                TripStateIndicator(
                  phase: widget.state.tripwireStateFor(selected),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (keys.isEmpty)
            // Distinct from LinksCard's 'NO LINK DATA YET' (link
            // health rows): this card is the dip history, so its
            // empty state says so — two identical lines on one
            // screen would read as a duplicated widget.
            Text('NO DIP HISTORY YET', style: OutrideType.rowLabel())
          else ...[
            DropdownButton<String>(
              value: selected,
              isExpanded: true,
              dropdownColor: OutrideColors.surface2,
              style: OutrideType.rowValue(OutrideColors.onDark),
              items: [
                for (final k in keys)
                  DropdownMenuItem(
                    value: k,
                    child: Text(
                      shortLinkKey(k),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _selected = v);
              },
            ),
            const SizedBox(height: 8),
            LinkDipSeriesChart(
              samples: samples,
              threshold: dipSeriesThreshold(samples),
            ),
            const SizedBox(height: 8),
            Text(
              'DIP VS BASELINE, RADIO UNITS (EST.) — LAST ${samples.length} SAMPLES',
              style: OutrideType.section(10).copyWith(height: 1.6),
            ),
          ],
        ],
      ),
    );
  }
}

/// One compact row per link direction — health only, no charts.
class LinksCard extends StatelessWidget {
  const LinksCard(
      {super.key, required this.state, required this.disturbed});

  final AppState state;
  final List<String> disturbed;

  @override
  Widget build(BuildContext context) {
    final keys = state.history.keys.toList()..sort();
    return OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('MESH LINKS', style: OutrideType.section()),
          const SizedBox(height: 10),
          if (keys.isEmpty)
            Text('NO LINK DATA YET', style: OutrideType.rowLabel()),
          for (final k in keys)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: disturbed.contains(k)
                          ? OutrideColors.amber
                          : OutrideColors.green,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(shortLinkKey(k),
                        style: OutrideType.rowValue(OutrideColors.onDark)),
                  ),
                  // SNR / DIP crossfade on change (motion layer)
                  // instead of jumping each poll.
                  AnimatedValueText(
                    value:
                        'SNR ${state.history[k]!.last.snrLabel}  ·  DIP ${state.history[k]!.last.dipLabel}',
                    style:
                        OutrideType.rowLabel().copyWith(fontSize: 11),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
