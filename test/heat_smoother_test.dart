import 'package:flutter_test/flutter_test.dart';
import 'package:outride/screens/tracking.dart';

void main() {
  group('HeatSmoother (v0.30.1)', () {
    test('a new cell eases in from dim, then converges', () {
      final s = HeatSmoother();
      const cell = (x: 0.0, y: 0.0, v: 1.0);
      // First paint: 35% of the way from 0 to 1.
      expect(s.smooth([cell]).single.v, closeTo(0.35, 0.001));
      // Second paint: 35% of the remaining gap.
      expect(s.smooth([cell]).single.v, closeTo(0.5775, 0.001));
      // After many paints it converges on the measured value.
      var v = 0.0;
      for (var i = 0; i < 20; i++) {
        v = s.smooth([cell]).single.v;
      }
      expect(v, closeTo(1.0, 0.001));
    });

    test('a cell that drops out fades instead of vanishing', () {
      final s = HeatSmoother();
      const cell = (x: 0.0, y: 0.0, v: 1.0);
      for (var i = 0; i < 20; i++) {
        s.smooth([cell]);
      }
      // Gone from the feed: first ghost frame is 65% of full.
      final ghost = s.smooth(const []);
      expect(ghost, hasLength(1));
      expect(ghost.single.v, closeTo(0.65, 0.001));
      // It keeps decaying and is eventually dropped.
      var frames = s.smooth(const []);
      for (var i = 0; i < 10; i++) {
        frames = s.smooth(const []);
      }
      expect(frames, isEmpty);
    });

    test('cells ease independently', () {
      final s = HeatSmoother();
      const a = (x: 0.0, y: 0.0, v: 1.0);
      const b = (x: 5.0, y: 0.0, v: 0.5);
      final out = s.smooth([a, b]);
      expect(out, hasLength(2));
      expect(out.firstWhere((c) => c.x == 0.0).v, closeTo(0.35, 0.001));
      expect(out.firstWhere((c) => c.x == 5.0).v, closeTo(0.175, 0.001));
    });
  });
}
