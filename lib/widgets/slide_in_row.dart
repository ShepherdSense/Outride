/// Slide-in row (v0.30.0 motion layer): a list row that slides in
/// from just above, fading in, when it first mounts.
///
/// New alerts arrive at the top of the list; a row that just appears
/// is easy to miss, and a row that bounces is noise. This is the
/// middle: a short ([OutrideMotion.standard]) fade + 8 px slide from
/// above, once, on mount. Key the row by its event so only genuinely
/// new rows animate — reordered or rebuilt rows must not re-slide.
library;

import 'package:flutter/material.dart';

import 'outride_motion.dart';

class SlideInRow extends StatelessWidget {
  const SlideInRow({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: OutrideMotion.standard,
      curve: OutrideMotion.curve,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * -8),
          child: child,
        ),
      ),
      child: child,
    );
  }
}
