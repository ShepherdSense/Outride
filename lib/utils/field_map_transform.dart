/// World (meters) <-> screen (pixels) transform for the field map.
///
/// Extracted from tracking.dart (v0.28.0) so the tile-pack layer and
/// tests can use it without importing the whole Tracking screen.
/// Pure geometry: no AppState, no sensors.
library;

import 'dart:math' as math;
import 'dart:ui';

class FieldMapTransform {
  FieldMapTransform({required this.scale, required this.ox, required this.oy});

  final double scale;
  final double ox;
  final double oy;

  Offset toScreen(double x, double y) =>
      Offset(ox + x * scale, oy - y * scale);
  double toWorldX(double sx) => (sx - ox) / scale;
  double toWorldY(double sy) => (oy - sy) / scale;

  factory FieldMapTransform.fit(Size size, List<math.Point<double>> pts,
      {double zoom = 1.0}) {
    var minX = -40.0, maxX = 40.0, minY = -40.0, maxY = 40.0;
    if (pts.isNotEmpty) {
      minX = pts.map((p) => p.x).reduce(math.min);
      maxX = pts.map((p) => p.x).reduce(math.max);
      minY = pts.map((p) => p.y).reduce(math.min);
      maxY = pts.map((p) => p.y).reduce(math.max);
      final padX = math.max(12.0, (maxX - minX) * 0.18);
      final padY = math.max(12.0, (maxY - minY) * 0.18);
      minX -= padX;
      maxX += padX;
      minY -= padY;
      maxY += padY;
    }
    final scale = math.min(size.width / (maxX - minX),
            size.height / (maxY - minY)) *
        zoom;
    final ox = size.width / 2 - (minX + maxX) / 2 * scale;
    final oy = size.height / 2 + (minY + maxY) / 2 * scale;
    return FieldMapTransform(scale: scale, ox: ox, oy: oy);
  }

  /// Centers ([centerX], [centerY]) in world meters on the middle
  /// of [size] at the given [scale] — follow mode (v0.28.0 live
  /// GPS). `toScreen(centerX, centerY)` is exactly the screen
  /// center. The scale normally comes from [fit] for the same view,
  /// so zoom level is preserved and only the center moves.
  factory FieldMapTransform.centered({
    required Size size,
    required double centerX,
    required double centerY,
    required double scale,
  }) =>
      FieldMapTransform(
        scale: scale,
        ox: size.width / 2 - centerX * scale,
        oy: size.height / 2 + centerY * scale,
      );
}
