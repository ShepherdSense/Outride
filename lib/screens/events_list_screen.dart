import 'package:flutter/material.dart';

import '../models/link_sample.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'evidence_sheet.dart';

/// Full crossing-events list with triage, moved intact from the old
/// Alerts tab ([DashboardScreen]) when Picture replaced it: up to 30
/// events, tap-to-open evidence, ACK / FALSE ALARM triage, ACK / FA /
/// NEW counts. Triage never deletes the event. Reached from Picture
/// by tapping the LATEST EVENTS tail (or SEE ALL).
class EventsListScreen extends StatelessWidget {
  const EventsListScreen({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('CROSSING EVENTS')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [EventsListCard(state: state)],
      ),
    );
  }
}

/// The events card itself, shared by [EventsListScreen] and the old
/// dashboard (which still renders it when referenced).
class EventsListCard extends StatelessWidget {
  const EventsListCard({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final stats = state.triageStats;
    return OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('CROSSING EVENTS', style: OutrideType.section()),
              const Spacer(),
              Text(
                'ACK ${stats['acked']} · FA ${stats['falseAlarm']} · '
                'NEW ${stats['unreviewed']}',
                style: OutrideType.section(10),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (state.events.isEmpty)
            Text('NO CROSSINGS DETECTED YET',
                style: OutrideType.rowLabel()),
          for (final e in state.events.take(30)) _eventRow(context, e),
        ],
      ),
    );
  }

  /// One event row: tap for evidence, ACK / FALSE ALARM for triage.
  /// Acked rows dim; false alarms mute. Triage never deletes the event.
  Widget _eventRow(BuildContext context, CrossingEvent e) {
    final verdict = state.triage[AppState.triageKeyFor(e)];
    final acked = verdict == AppState.triageAcked;
    final falseAlarm = verdict == AppState.triageFalseAlarm;
    final aiConf = e.aiConfidence;
    final aiLabel = e.aiLabel == null
        ? '—'
        : aiConf == null
            ? 'AI ${e.aiLabel} EST'
            : 'AI ${e.aiLabel} ${(aiConf * 100).toStringAsFixed(0)}% EST';
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => openEvidenceSheet(context, state, e),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              falseAlarm
                  ? Icons.do_not_disturb_on_outlined
                  : Icons.warning_amber_rounded,
              color:
                  falseAlarm ? OutrideColors.muted : OutrideColors.amber,
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${fmtEventTime(e.timestamp)} · ${shortLinkKey(e.linkKey)} · $aiLabel',
                    style: OutrideType.rowValue(falseAlarm
                        ? OutrideColors.muted
                        : OutrideColors.onDark),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'SIZE ${e.sizeEstimate} EST · ${e.direction == 'rise' ? 'RISE +' : 'DIP -'}${e.dipDepth.toStringAsFixed(0)} EST · LASTED ${e.durationLabel}',
                    style: OutrideType.rowLabel().copyWith(
                        fontSize: 11,
                        color: falseAlarm ? OutrideColors.muted : null),
                  ),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      _triageBtn(e, AppState.triageAcked, 'ACK',
                          OutrideColors.green),
                      const SizedBox(width: 8),
                      _triageBtn(e, AppState.triageFalseAlarm,
                          'FALSE ALARM', OutrideColors.red),
                    ],
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right,
                color: OutrideColors.muted, size: 18),
          ],
        ),
      ),
    );
    return Opacity(opacity: acked ? 0.55 : 1.0, child: row);
  }

  /// Small triage toggle button. Active state is highlighted; tapping
  /// the active verdict again clears it.
  Widget _triageBtn(
      CrossingEvent e, String verdict, String label, Color color) {
    final active =
        state.triage[AppState.triageKeyFor(e)] == verdict;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => state.triageEvent(e, verdict),
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          border: Border.all(
              color: active ? color : OutrideColors.border),
          borderRadius: BorderRadius.circular(6),
          color:
              active ? color.withAlpha(28) : Colors.transparent,
        ),
        child: Text(
          label,
          style: OutrideType.chip(
                  active ? color : OutrideColors.muted)
              .copyWith(fontSize: 10),
        ),
      ),
    );
  }
}

/// Tap-to-open evidence sheet, shared by the events list and the
/// timeline strip.
void openEvidenceSheet(BuildContext context, AppState state, CrossingEvent e) {
  showModalBottomSheet(
    context: context,
    backgroundColor: OutrideColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => EvidenceSheet(event: e, state: state),
  );
}

/// HH:MM:SS, shared by the events list and the timeline strip.
String fmtEventTime(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
