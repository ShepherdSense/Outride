/// Tripwire state indicator (v0.30.0 motion layer): the armed →
/// tripped → confirmed → cleared state machine, made visible.
///
/// Driven by stream C's `TripState` (`lib/services/tripwire.dart`,
/// `stateFor()`): the widget takes the current state value and the
/// pill's colour transitions ([AnimatedContainer],
/// [OutrideMotion.standard]) while the label crossfades
/// ([AnimatedSwitcher]) — a state change is a visible transition,
/// never a flip. Confirmed also swaps the dot for a short check
/// (the "short glow/check" from the motion brief). Colours follow
/// the status discipline: muted grey for armed (a state, not a
/// primary action — the accent is reserved for the filled primary
/// button and the selected tab), amber for tripped (elevated), red
/// for confirmed (alert), green for cleared.
library;

import 'package:flutter/material.dart';

import '../services/tripwire.dart';
import '../theme.dart';
import 'live_dot.dart';
import 'outride_motion.dart';

/// Per-state display: label + status colour.
({String label, Color color}) _phaseDisplay(TripState phase) =>
    switch (phase) {
      TripState.armed => (
          label: 'ARMED',
          color: OutrideColors.muted,
        ),
      TripState.tripped => (
          label: 'TRIPPED',
          color: OutrideColors.amber,
        ),
      TripState.confirmed => (
          label: 'CONFIRMED',
          color: OutrideColors.red,
        ),
      TripState.cleared => (
          label: 'CLEARED',
          color: OutrideColors.green,
        ),
    };

class TripStateIndicator extends StatelessWidget {
  const TripStateIndicator({super.key, required this.phase});

  final TripState phase;

  @override
  Widget build(BuildContext context) {
    final display = _phaseDisplay(phase);
    final color = display.color;
    return AnimatedContainer(
      duration: OutrideMotion.standard,
      curve: OutrideMotion.curve,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedSwitcher(
            duration: OutrideMotion.standard,
            switchInCurve: OutrideMotion.curve,
            switchOutCurve: OutrideMotion.curve,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: child,
            ),
            child: phase == TripState.confirmed
                ? Icon(Icons.check, key: const ValueKey('check'),
                    color: color, size: 13)
                : LiveDot(
                    key: ValueKey('dot-$phase'),
                    color: color,
                    size: 7,
                    pulsing: phase == TripState.tripped,
                  ),
          ),
          const SizedBox(width: 7),
          AnimatedSwitcher(
            duration: OutrideMotion.standard,
            switchInCurve: OutrideMotion.curve,
            switchOutCurve: OutrideMotion.curve,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: child,
            ),
            child: Text(
              display.label,
              key: ValueKey(display.label),
              style: OutrideType.chip(color).copyWith(fontSize: 10),
            ),
          ),
        ],
      ),
    );
  }
}
