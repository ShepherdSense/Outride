import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../theme.dart';

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
                    Text(
                      s.error ??
                          '${s.linkCount} LINKS',
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
                  Text(
                    'SNR ${state.history[k]!.last.snrLabel}  ·  DIP ${state.history[k]!.last.dipLabel}',
                    style: OutrideType.rowLabel().copyWith(fontSize: 11),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
