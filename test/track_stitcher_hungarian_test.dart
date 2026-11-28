// Batch handoff association (TrackStitcher.checkHandoffs) —
//
// HAND-BUILT UNIT CASES. Every probability below is invented by
// hand to exercise the assignment logic (greedy vs Hungarian,
// single-detection equivalence, gating). These are unit tests,
// never measurements: no MLP ran, no bench session exists, and
// nothing here is a claim about real-world stitch accuracy.
import 'package:flutter_test/flutter_test.dart';
import 'package:outride/services/track_stitcher.dart';

DriverDetection _det(
  String driver,
  DateTime tFirst, {
  DateTime? tLast,
  double x = 0,
  double y = 0,
}) =>
    DriverDetection(
      driverId: driver,
      tFirst: tFirst,
      tLast: tLast ?? tFirst,
      x: x,
      y: y,
      firstX: x,
      firstY: y,
      peakDip: 10,
      nLinks: 3,
    );

/// Greedy per-row-max baseline, mirroring what repeated
/// checkHandoff() calls do: each new detection in driver order
/// takes its best still-unassigned closed detection at/above
/// threshold. Test-only comparison baseline — NOT production code.
double _greedyTotal(
  Map<(String, String), double> probs,
  List<String> news,
  List<String> olds,
) {
  final used = <String>{};
  var total = 0.0;
  for (final n in news) {
    var best = 0.0;
    String? bestOld;
    for (final o in olds) {
      if (used.contains(o)) continue;
      final p = probs[(o, n)] ?? 0.0;
      if (p >= TrackStitcher.stitchThreshold && p > best) {
        best = p;
        bestOld = o;
      }
    }
    if (bestOld != null) {
      used.add(bestOld);
      total += best;
    }
  }
  return total;
}

void main() {
  final now = DateTime(2026, 11, 25, 12, 0, 0);

  TrackStitcher buildStitcher(
    Map<(String, String), double> probs, {
    required List<String> news,
    required List<String> olds,
  }) {
    final s = TrackStitcher.withProbabilities(probs);
    for (final n in news) {
      s.openForTest[n] = _det(n, now.subtract(const Duration(seconds: 10)));
    }
    for (final o in olds) {
      s.closedForTest
          .add(_det(o, now.subtract(const Duration(minutes: 2)),
              tLast: now.subtract(const Duration(seconds: 60))));
    }
    return s;
  }

  group('checkHandoffs batch association', () {
    test('(a) 2x2: Hungarian beats greedy per-row-max', () {
      // Hand-built probabilities (rows = new, cols = closed):
      //            cX     cY
      //   nA     0.99   0.98
      //   nB     0.97   0.66
      // Greedy in driver order: nA grabs cX (0.99), leaving nB
      // with cY (0.66) — total 1.65. The global optimum swaps
      // them: nA->cY (0.98) + nB->cX (0.97) — total 1.95.
      const probs = {
        ('cX', 'nA'): 0.99,
        ('cY', 'nA'): 0.98,
        ('cX', 'nB'): 0.97,
        ('cY', 'nB'): 0.66,
      };
      const news = ['nA', 'nB'];
      const olds = ['cX', 'cY'];
      final greedy = _greedyTotal(probs, news, olds);
      expect(greedy, closeTo(1.65, 1e-9));

      final s = buildStitcher(probs, news: news, olds: olds);
      final out = s.checkHandoffs(now: now);
      expect(out.length, 2);
      final total =
          out.fold<double>(0.0, (sum, a) => sum + a.confidence);
      expect(total, closeTo(1.95, 1e-9));
      expect(total, greaterThan(greedy));
      expect(
        out.map((a) => (a.newDriver, a.fromDriver)).toSet(),
        {('nA', 'cY'), ('nB', 'cX')},
      );
      // Each side used at most once.
      expect(out.map((a) => a.newDriver).toSet().length, 2);
      expect(out.map((a) => a.fromDriver).toSet().length, 2);
    });

    test('(b) single new detection: batch equals greedy checkHandoff', () {
      const probs = {
        ('cX', 'nA'): 0.90,
        ('cY', 'nA'): 0.80,
      };
      final s = buildStitcher(probs, news: ['nA'], olds: ['cX', 'cY']);
      final single = s.checkHandoff(now: now, activeDriver: 'nA');
      final batch = s.checkHandoffs(now: now);
      expect(single, isNotNull);
      expect(batch.length, 1);
      expect(batch.single.newDriver, 'nA');
      expect(batch.single.fromDriver, single!.fromDriver);
      expect(batch.single.confidence, closeTo(single.confidence, 1e-9));
      expect(batch.single.fromDriver, 'cX');
      expect(batch.single.confidence, closeTo(0.90, 1e-9));
    });

    test('(c) gating: below-threshold pairs are never assigned', () {
      // Every pair below threshold: nothing assigned.
      final s1 = buildStitcher(
        {('cX', 'nA'): 0.50},
        news: ['nA'],
        olds: ['cX'],
      );
      expect(s1.checkHandoffs(now: now), isEmpty);

      // One above, one below, one closed slot: the below-threshold
      // pair must not be assigned even though a slot is free for it
      // (the Hungarian would otherwise pair the leftover row).
      final s2 = buildStitcher(
        {('cX', 'nA'): 0.90, ('cX', 'nB'): 0.50},
        news: ['nA', 'nB'],
        olds: ['cX'],
      );
      final out2 = s2.checkHandoffs(now: now);
      expect(out2.length, 1);
      expect(out2.single.newDriver, 'nA');
      expect(out2.single.fromDriver, 'cX');

      // Just below the 0.65 threshold is still gated.
      final s3 = buildStitcher(
        {('cX', 'nA'): 0.649},
        news: ['nA'],
        olds: ['cX'],
      );
      expect(s3.checkHandoffs(now: now), isEmpty);
    });

    test('empty state assigns nothing', () {
      final s = TrackStitcher.withProbabilities(const {});
      expect(s.checkHandoffs(now: now), isEmpty);
    });

    test('same-driver closed detection never stitches to its own new', () {
      final s = buildStitcher(
        {('d1', 'd1'): 0.99},
        news: ['d1'],
        olds: ['d1'],
      );
      expect(s.checkHandoffs(now: now), isEmpty);
    });

    test('rectangular: more closed than new assigns at most one per new',
        () {
      const probs = {
        ('cX', 'nA'): 0.90,
        ('cY', 'nA'): 0.80,
        ('cZ', 'nA'): 0.70,
      };
      final s = buildStitcher(
        probs,
        news: ['nA'],
        olds: ['cX', 'cY', 'cZ'],
      );
      final out = s.checkHandoffs(now: now);
      expect(out.length, 1);
      expect(out.single.fromDriver, 'cX');
      expect(out.single.confidence, closeTo(0.90, 1e-9));
    });
  });
}
