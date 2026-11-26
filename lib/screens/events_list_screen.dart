import 'package:flutter/material.dart';

import '../models/link_sample.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/animated_value_text.dart';
import '../widgets/outride_motion.dart';
import '../widgets/slide_in_row.dart';
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
      // v0.29.1: the list must listen to AppState itself. This screen
      // is a pushed route, so it sits outside every destination's
      // ListenableBuilder (and main.dart has no top-level listener):
      // before this, triageEvent updated the record and notified, but
      // nothing in this route rebuilt, so ACK / FALSE ALARM taps never
      // moved the counters. Wrapping the body here also lets new
      // events appear while the list is open.
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(12),
          children: [EventsListCard(state: state)],
        ),
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
          // Header stacks (v0.29.2 review): title and counts on
          // separate lines. A side-by-side Row split the width
          // 50/50, so the counts string (~176 px at the
          // letterspaced mono type) truncated at 320–400 px with
          // double-digit counts. Stacked, both fit at 320 px.
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('CROSSING EVENTS', style: OutrideType.section()),
              const SizedBox(height: 2),
              // Counts crossfade on triage taps (motion layer).
              AnimatedValueText(
                value: 'ACK ${stats['acked']} · FA ${stats['falseAlarm']} · '
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
                      _TriageButton(
                        label: 'ACK',
                        color: OutrideColors.green,
                        active: acked,
                        onTap: () =>
                            state.triageEvent(e, AppState.triageAcked),
                      ),
                      const SizedBox(width: 8),
                      _TriageButton(
                        label: 'FALSE ALARM',
                        color: OutrideColors.red,
                        active: falseAlarm,
                        onTap: () => state.triageEvent(
                            e, AppState.triageFalseAlarm),
                      ),
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
    // New rows slide in from above when they first mount (motion
    // layer); the key means only genuinely new events animate —
    // a rebuilt row keeps its state and does not re-slide.
    return SlideInRow(
      key: ValueKey(AppState.triageKeyFor(e)),
      child: Opacity(opacity: acked ? 0.55 : 1.0, child: row),
    );
  }
}

/// Triage toggle button with animated confirmation (motion layer):
/// a quick scale pulse on tap (press feedback) and an
/// [AnimatedContainer] tint/border transition when the verdict
/// becomes active. Tapping the active verdict again clears it.
class _TriageButton extends StatefulWidget {
  const _TriageButton({
    required this.label,
    required this.color,
    required this.active,
    required this.onTap,
  });

  final String label;
  final Color color;
  final bool active;
  final VoidCallback onTap;

  @override
  State<_TriageButton> createState() => _TriageButtonState();
}

class _TriageButtonState extends State<_TriageButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _press;

  @override
  void initState() {
    super.initState();
    _press = AnimationController(
      vsync: this,
      duration: OutrideMotion.fast,
    );
  }

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  void _handleTap() {
    // Verdict applies immediately; the pulse plays alongside it.
    widget.onTap();
    _press.forward().then((_) {
      if (mounted) _press.reverse();
    });
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: Tween<double>(begin: 1, end: 0.94).animate(
        CurvedAnimation(parent: _press, curve: OutrideMotion.curve),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: _handleTap,
        child: AnimatedContainer(
          duration: OutrideMotion.standard,
          curve: OutrideMotion.curve,
          padding:
              const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            border: Border.all(
                color: widget.active
                    ? widget.color
                    : OutrideColors.border),
            borderRadius: BorderRadius.circular(6),
            color: widget.active
                ? widget.color.withAlpha(28)
                : Colors.transparent,
          ),
          child: Text(
            widget.label,
            style: OutrideType.chip(
                    widget.active ? widget.color : OutrideColors.muted)
                .copyWith(fontSize: 10),
          ),
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
