/// Animated value text (v0.30.0 motion layer): a value that crossfades
/// when it changes instead of jumping.
///
/// Link/sensor rows re-render on every poll; a bare [Text] swap
/// flickers. Keying the text by its value inside an [AnimatedSwitcher]
/// fades the old value out and the new one in over
/// [OutrideMotion.fast] — visible, but short enough that a 1 Hz poll
/// never queues transitions behind itself.
library;

import 'package:flutter/material.dart';

import 'outride_motion.dart';

class AnimatedValueText extends StatelessWidget {
  const AnimatedValueText({
    super.key,
    required this.value,
    this.style,
    this.textAlign,
  });

  final String value;
  final TextStyle? style;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: OutrideMotion.fast,
      switchInCurve: OutrideMotion.curve,
      switchOutCurve: OutrideMotion.curve,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: child,
      ),
      child: Text(
        value,
        key: ValueKey(value),
        style: style,
        textAlign: textAlign,
      ),
    );
  }
}
