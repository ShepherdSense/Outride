/// Motion layer (v0.30.0 refinement): durations + curves, one place.
///
/// Smooth and deliberate, never bouncy or gimmicky, never anything
/// that slows the operator down (Solora is the model: crossfades and
/// slides, no springs). Every animated widget in this stream reads
/// these constants — durations and curves are settled per the
/// 2026-11-25 refined direction, so a refinement is a change here,
/// not a hunt through widgets.
///
/// Ranges (brief): 150–300 ms, [Curves.easeInOut] or equivalent.
/// [pulse] is the slow live-dot pulse, deliberately outside that
/// range — a dot that throbs at 250 ms would read as an alarm.
library;

import 'package:flutter/material.dart';

/// Central motion constants for the v0.30.0 refinement layer.
abstract final class OutrideMotion {
  /// Fast: value changes, press feedback, pill colour flips.
  static const Duration fast = Duration(milliseconds: 150);

  /// Standard: state transitions, tab/screen crossfades, triage
  /// confirmation, alert rows sliding in.
  static const Duration standard = Duration(milliseconds: 250);

  /// Chart playhead sweep on new data.
  static const Duration playhead = Duration(milliseconds: 300);

  /// Slow live-dot pulse period (see [LiveDot]).
  static const Duration pulse = Duration(milliseconds: 1600);

  /// The one curve for this layer: deliberate, not bouncy.
  static const Curve curve = Curves.easeInOut;

  /// Entering rows/tabs slide from slightly below, fading in.
  /// Small on purpose (6% of the widget's height) — a full slide
  /// would feel like navigation, not a state change.
  static const Offset slideBegin = Offset(0, 0.06);

  /// Shared AnimatedSwitcher transition: fade + a small slide.
  /// Used by tab transitions and value changes.
  static Widget fadeSlideTransition(
      Widget child, Animation<double> animation) {
    final slide = Tween<Offset>(begin: slideBegin, end: Offset.zero)
        .animate(CurvedAnimation(parent: animation, curve: curve));
    return FadeTransition(
      opacity: animation,
      child: SlideTransition(position: slide, child: child),
    );
  }
}
