/// Live dot (v0.30.0 motion layer): a small status dot that pulses
/// slowly when [pulsing], static otherwise.
///
/// The slow pulse ([OutrideMotion.pulse], 1600 ms) is the "live"
/// signal from the motion brief — a dot that throbs at 250 ms would
/// read as an alarm. Colour comes from the caller; the default is
/// green (a live dot is a status readout, and green is the
/// live/healthy status — the accent is reserved for the filled
/// primary button and the selected tab, so it is never the default
/// here). Green/red/amber are strictly for status.
library;

import 'package:flutter/material.dart';

import '../theme.dart';
import 'outride_motion.dart';

class LiveDot extends StatefulWidget {
  const LiveDot({
    super.key,
    this.color = OutrideColors.green,
    this.size = 7,
    this.pulsing = true,
  });

  final Color color;

  /// Dot diameter, logical pixels.
  final double size;

  /// True: slow opacity + scale pulse. False: a plain static dot.
  final bool pulsing;

  @override
  State<LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<LiveDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: OutrideMotion.pulse,
    );
    if (widget.pulsing) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(LiveDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pulsing && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.pulsing && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: widget.size,
      height: widget.size,
      decoration:
          BoxDecoration(color: widget.color, shape: BoxShape.circle),
    );
    if (!widget.pulsing) return dot;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_controller.value);
        return Opacity(
          opacity: 1.0 - 0.55 * t,
          child: Transform.scale(
            scale: 1.0 + 0.25 * t,
            child: child,
          ),
        );
      },
      child: dot,
    );
  }
}
