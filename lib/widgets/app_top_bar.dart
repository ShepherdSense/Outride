/// App top bar (v0.30.0): brand lockup + SIMULATED / LIVE pill.
///
/// Extracted from `main.dart`'s AppBar so the bar is testable on its
/// own (the AppBar lives in main.dart, which transitively imports
/// the Settings screen and the whole app state). The widget is pure:
/// it takes the mode as input and owns no state.
///
/// Brand lockup: [icon mark] OUTRIDE — the amber Aussie-head mark
/// (`assets/icon/outride_mark_header.png`, derived from the 1024 px
/// launcher source) at header-text height (~20 px, a small mark,
/// not a badge), 8 px gap to the all-white wordmark.
///
/// Styling (2026-11-25 refinement): dark near-black ground, hairline
/// border, small uppercase letterspaced label. The pill reads the
/// mode as a status, not a primary action: LIVE is green, SIMULATED
/// is muted grey. The warm-amber accent is reserved for the filled
/// primary button and the selected tab and does not appear here;
/// green/red/amber status colours stay status-only.
///
/// Motion: the pill's colour and label animate on a mode change
/// (quick colour + label change, [OutrideMotion.standard]) — the
/// primary-state-change pattern from the motion brief — so a
/// SIMULATED → LIVE flip transitions instead of jumping.
library;

import 'package:flutter/material.dart';

import '../theme.dart';
import 'outride_motion.dart';

/// The app's top bar: brand lockup left, mode pill right.
///
/// [simulated] true renders the muted SIMULATED pill; false renders
/// the green LIVE pill. The pill is shrink-wrapped and the row
/// keeps the pill pinned right with a [Spacer] — the pill must never
/// clip or overflow at any viewport width (see
/// test/top_bar_pills_desktop_test.dart).
class AppTopBar extends StatelessWidget {
  const AppTopBar({super.key, required this.simulated});

  final bool simulated;

  @override
  Widget build(BuildContext context) {
    final pillColor =
        simulated ? OutrideColors.muted : OutrideColors.green;
    return Row(
      children: [
        // Brand lockup: amber Aussie-head mark + OUTRIDE wordmark.
        Image.asset(
          'assets/icon/outride_mark_header.png',
          width: 20,
          height: 20,
        ),
        const SizedBox(width: 8),
        RichText(
          text: TextSpan(
            style: OutrideType.section(20).copyWith(
              color: OutrideColors.onDark,
              letterSpacing: 1,
              fontWeight: FontWeight.w800,
            ),
            children: const [
              TextSpan(text: 'OUT'),
              TextSpan(
                text: 'RIDE',
                style: TextStyle(color: OutrideColors.onDark),
              ),
            ],
          ),
        ),
        const Spacer(),
        AnimatedContainer(
          duration: OutrideMotion.standard,
          curve: OutrideMotion.curve,
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: simulated
                ? Colors.transparent
                : OutrideColors.green.withValues(alpha: 0.12),
            border: Border.all(color: pillColor),
            borderRadius: BorderRadius.circular(999),
          ),
          child: AnimatedSwitcher(
            duration: OutrideMotion.standard,
            switchInCurve: OutrideMotion.curve,
            switchOutCurve: OutrideMotion.curve,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: child,
            ),
            child: Text(
              simulated ? 'SIMULATED' : 'LIVE',
              key: ValueKey<bool>(simulated),
              style: TextStyle(
                color: pillColor,
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
