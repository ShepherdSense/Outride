/// Fleet dialer — the 4-digit PIN pad (spec §7).
///
/// Pure PIN state ([FleetDialerState]) plus the pad widget
/// ([FleetDialerPad]) and the four-dot display ([FleetPinDots]).
/// No socket, no clock: unit-testable without a network. The pad
/// emits digits only — a 5th digit is impossible by construction
/// (the state ignores it), and there is no keyboard, no IP field,
/// no second app, no terminal.
library;

import 'package:flutter/material.dart';

import '../theme.dart';

/// PIN entry state: up to 4 digits, auto-submit on the 4th.
/// Digits are kept in memory only — the raw PIN is never stored.
class FleetDialerState {
  String _digits = '';

  /// Entered digits so far (0..4 chars, digits only).
  String get digits => _digits;

  int get length => _digits.length;

  bool get isEmpty => _digits.isEmpty;

  /// True once 4 digits are entered — the screen auto-submits.
  bool get isComplete => _digits.length == 4;

  /// Add one digit. Non-digits and a 5th digit are ignored
  /// (returns false); accepted digits return true.
  bool addDigit(String d) {
    if (!RegExp(r'^[0-9]$').hasMatch(d)) return false;
    if (_digits.length >= 4) return false;
    _digits += d;
    return true;
  }

  /// Remove the last entered digit. No-op when empty.
  void backspace() {
    if (_digits.isEmpty) return;
    _digits = _digits.substring(0, _digits.length - 1);
  }

  /// Clear all entered digits (e.g. after a wrong PIN).
  void clear() {
    _digits = '';
  }
}

/// Four filled dots as digits are entered (spec §7).
class FleetPinDots extends StatelessWidget {
  const FleetPinDots({super.key, required this.digits});

  final String digits;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < 4; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < digits.length
                    ? OutrideColors.purple
                    : Colors.transparent,
                border: Border.all(
                  color: i < digits.length
                      ? OutrideColors.purple
                      : OutrideColors.border,
                  width: 2,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Dialer pad: 1–9, then 0 with a backspace key. Big tired-operator
/// targets, purple accent, dark mode. The pad only reports taps;
/// [FleetDialerState] (owned by the screen) decides what counts.
class FleetDialerPad extends StatelessWidget {
  const FleetDialerPad({
    super.key,
    required this.digits,
    required this.onDigit,
    required this.onBackspace,
    this.enabled = true,
  });

  /// Digits entered so far (drives the dots).
  final String digits;

  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FleetPinDots(digits: digits),
        const SizedBox(height: 16),
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                for (var i = 0; i < row.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(child: _key(row[i], () => onDigit(row[i]))),
                ],
              ],
            ),
          ),
        Row(
          children: [
            const Expanded(child: SizedBox()),
            const SizedBox(width: 8),
            Expanded(child: _key('0', () => onDigit('0'))),
            const SizedBox(width: 8),
            Expanded(
              child: _keyWidget(
                const Icon(Icons.backspace_outlined,
                    color: OutrideColors.onDark),
                onBackspace,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _key(String label, VoidCallback onTap) => _keyWidget(
        Text(label,
            style: OutrideType.readout(26, OutrideColors.onDark)),
        onTap,
      );

  Widget _keyWidget(Widget child, VoidCallback onTap) {
    return SizedBox(
      height: 56,
      child: OutlinedButton(
        onPressed: enabled ? onTap : null,
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: OutrideColors.border),
          backgroundColor: OutrideColors.surface2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: child,
      ),
    );
  }
}
