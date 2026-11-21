import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/services/fusion_bench.dart';

void main() {
  group('Gaussian2', () {
    test('SPD check and information round-trip', () {
      const g = Gaussian2(x: 1, y: 2, pxx: 4, pxy: 1, pyy: 9);
      expect(g.isSpd, isTrue);
      expect(g.determinant, 35.0);
      final back = gaussianFromInformation(g.information, g.informationVector);
      expect(back.x, closeTo(1.0, 1e-9));
      expect(back.y, closeTo(2.0, 1e-9));
      expect(back.pxx, closeTo(4.0, 1e-9));
      expect(back.pxy, closeTo(1.0, 1e-9));
      expect(back.pyy, closeTo(9.0, 1e-9));
    });

    test('non-SPD is detected', () {
      const g = Gaussian2(x: 0, y: 0, pxx: -1, pxy: 0, pyy: 1);
      expect(g.isSpd, isFalse);
      expect(() => g.information, throwsStateError);
    });
  });

  group('ciFuse', () {
    test('identical estimates fuse to themselves', () {
      const a = Gaussian2(x: 3, y: -2, pxx: 2, pxy: 0.5, pyy: 3);
      final r = ciFuse(a, a);
      expect(r.fused.x, closeTo(3.0, 1e-9));
      expect(r.fused.y, closeTo(-2.0, 1e-9));
      expect(r.fused.pxx, closeTo(2.0, 1e-9));
      expect(r.fused.pyy, closeTo(3.0, 1e-9));
      expect(r.omega, inInclusiveRange(0.0, 1.0));
    });

    test('unequal covariances pick an interior omega', () {
      // a tight in x, loose in y; b the opposite. Min-trace omega
      // is 0.5 by symmetry.
      const a = Gaussian2(x: 0, y: 0, pxx: 1, pxy: 0, pyy: 4);
      const b = Gaussian2(x: 10, y: 0, pxx: 4, pxy: 0, pyy: 1);
      final r = ciFuse(a, b);
      expect(r.omega, closeTo(0.5, 0.02));
      // a is tighter in x (Pxx 1 vs 4), so the fused mean weights
      // toward a: x = P_fxx * (1-omega) * Y_bxx * 10 = 1.6 * 1.25.
      expect(r.fused.x, closeTo(2.0, 0.1));
      expect(r.fused.trace, closeTo(3.2, 0.05));
      expect(r.fused.isSpd, isTrue);
    });

    test('non-SPD input is regularized, never throws', () {
      const a = Gaussian2(x: 0, y: 0, pxx: -1, pxy: 0, pyy: 1);
      const b = Gaussian2(x: 1, y: 1, pxx: 2, pxy: 0, pyy: 2);
      final r = ciFuse(a, b);
      expect(r.fused.isSpd, isTrue);
    });
  });

  group('iciFuse', () {
    test('identical estimates fuse to themselves', () {
      const a = Gaussian2(x: 3, y: -2, pxx: 2, pxy: 0.5, pyy: 3);
      final r = iciFuse(a, a);
      expect(r.fused.x, closeTo(3.0, 1e-9));
      expect(r.fused.y, closeTo(-2.0, 1e-9));
      expect(r.fused.pxx, closeTo(2.0, 1e-9));
      expect(r.fused.pyy, closeTo(3.0, 1e-9));
    });

    test('ICI trace beats CI trace on the unequal pair', () {
      const a = Gaussian2(x: 0, y: 0, pxx: 1, pxy: 0, pyy: 4);
      const b = Gaussian2(x: 10, y: 0, pxx: 4, pxy: 0, pyy: 1);
      final ci = ciFuse(a, b);
      final ici = iciFuse(a, b);
      expect(ici.fused.isSpd, isTrue);
      expect(ici.fused.trace, lessThan(ci.fused.trace));
      expect(ici.omega, inInclusiveRange(0.0, 1.0));
    });

    test('ICI never falls back: omega is always numeric, result always SPD', () {
      // The old test expected a CI fallback (NaN omega) for this
      // pair — extremely tight covariances, means 100 m apart. That
      // branch was dead: at omega=0 the ICI information matrix is
      // exactly Y_a and at omega=1 exactly Y_b, both SPD, so the
      // closed grid always yields a candidate (means don't affect
      // the information matrix at all). The true invariant is that
      // ICI always returns a numeric omega in [0,1] and an SPD
      // result — assert that, not the unreachable branch.
      const a = Gaussian2(x: 0, y: 0, pxx: 0.01, pxy: 0, pyy: 0.01);
      const b = Gaussian2(x: 100, y: 0, pxx: 0.01, pxy: 0, pyy: 0.01);
      final r = iciFuse(a, b);
      expect(r.omega.isNaN, isFalse);
      expect(r.omega, inInclusiveRange(0.0, 1.0));
      expect(r.fused.isSpd, isTrue);
    });

    test('ICI and CI omega always numeric over random SPD pairs', () {
      // The reviewer's check, as a regression test: 0 of 2,000
      // random SPD pairs lacked an SPD omega. 200 pairs here keep
      // the test fast; the endpoint guarantee is what makes it hold.
      final rand = math.Random(20261121);
      Gaussian2 randomSpd() {
        final pxx = 0.01 + rand.nextDouble() * 100;
        final pyy = 0.01 + rand.nextDouble() * 100;
        final maxPxy = math.sqrt(pxx * pyy) * 0.9;
        final pxy = (rand.nextDouble() * 2 - 1) * maxPxy;
        return Gaussian2(
          x: rand.nextDouble() * 200 - 100,
          y: rand.nextDouble() * 200 - 100,
          pxx: pxx,
          pxy: pxy,
          pyy: pyy,
        );
      }

      for (var i = 0; i < 200; i++) {
        final a = randomSpd();
        final b = randomSpd();
        expect(a.isSpd, isTrue);
        expect(b.isSpd, isTrue);
        final ici = iciFuse(a, b);
        expect(ici.omega.isNaN, isFalse, reason: 'ICI pair $i');
        expect(ici.omega, inInclusiveRange(0.0, 1.0),
            reason: 'ICI pair $i');
        expect(ici.fused.isSpd, isTrue, reason: 'ICI pair $i');
        final ci = ciFuse(a, b);
        expect(ci.omega.isNaN, isFalse, reason: 'CI pair $i');
        expect(ci.fused.isSpd, isTrue, reason: 'CI pair $i');
      }
    });
  });

  group('naiveFuse', () {
    test('adds information matrices outright', () {
      const a = Gaussian2(x: 0, y: 0, pxx: 1, pxy: 0, pyy: 1);
      const b = Gaussian2(x: 10, y: 0, pxx: 1, pxy: 0, pyy: 1);
      final r = naiveFuse(a, b);
      expect(r.fused.x, closeTo(5.0, 1e-9));
      expect(r.fused.pxx, closeTo(0.5, 1e-9));
      expect(r.fused.pyy, closeTo(0.5, 1e-9));
      expect(r.omega.isNaN, isTrue);
    });
  });

  group('weights and L-rule', () {
    test('Metropolis weights are doubly stochastic and symmetric', () {
      // 3-node line: 0-1-2.
      final w = metropolisWeights([
        [1],
        [0, 2],
        [1],
      ]);
      for (var i = 0; i < 3; i++) {
        final row = w[i].fold(0.0, (p, e) => p + e);
        var col = 0.0;
        for (var k = 0; k < 3; k++) {
          col += w[k][i];
        }
        expect(row, closeTo(1.0, 1e-9));
        expect(col, closeTo(1.0, 1e-9));
      }
      expect(w[0][1], closeTo(w[1][0], 1e-12));
      expect(w[0][0], closeTo(2 / 3, 1e-9)); // 1 - 1/(1+max(1,2))
    });

    test('centrality weights are doubly stochastic', () {
      final w = centralityWeights([
        [1],
        [0, 2],
        [1],
      ]);
      for (var i = 0; i < 3; i++) {
        final row = w[i].fold(0.0, (p, e) => p + e);
        var col = 0.0;
        for (var k = 0; k < 3; k++) {
          col += w[k][i];
        }
        expect(row, closeTo(1.0, 1e-6));
        expect(col, closeTo(1.0, 1e-6));
      }
      // After Sinkhorn the high-degree middle node SPREADS its
      // weight to its two neighbours, so its self-weight is the
      // smallest: w00 = 1/phi = 0.618, w11 = 0.236 (golden-ratio
      // arithmetic on the 3-node line). The invariant that matters
      // is the doubly-stochastic rows/columns above.
      expect(w[0][0], closeTo(0.6180339887, 1e-6));
      expect(w[1][1], lessThan(w[0][0]));
    });

    test('mesh diameter', () {
      expect(meshDiameter([[1], [0, 2], [1]]), 2);
      expect(meshDiameter([[1, 2], [0, 2], [0, 1]]), 1);
      expect(meshDiameter([[1], [0], []]), -1); // disconnected
      expect(meshDiameter([[]]), 0);
    });

    test('second-largest eigenvalue of the 2-node complete graph', () {
      final w = metropolisWeights([
        [1],
        [0],
      ]);
      expect(secondLargestEigenvalue(w), closeTo(0.0, 1e-6));
    });

    test('second-largest eigenvalue of a 6-node ring is in (0, 1)', () {
      final adj = List.generate(6, (i) => [(i + 5) % 6, (i + 1) % 6]);
      final w = metropolisWeights(adj);
      final l2 = secondLargestEigenvalue(w);
      expect(l2, greaterThan(0.0));
      expect(l2, lessThan(1.0));
    });

    test('L-rule: max(diameter, ln(N-1)/ln(1/lambda))', () {
      // N=6, lambda=0.5, diameter=2: ln5/ln2 = 2.32 -> 3.
      final r = fusionIterations(nodeCount: 6, lambda2: 0.5, diameter: 2);
      expect(r.iterations, 3);
      expect(r.disconnected, isFalse);
      // Diameter dominates.
      final r2 =
          fusionIterations(nodeCount: 6, lambda2: 0.1, diameter: 5);
      expect(r2.iterations, 5);
      // Single node.
      final r3 =
          fusionIterations(nodeCount: 1, lambda2: double.nan, diameter: 0);
      expect(r3.iterations, 1);
    });
  });

  group('consensusFuse', () {
    test('identical estimates are unchanged by consensus', () {
      const g = Gaussian2(x: 1, y: 2, pxx: 2, pxy: 0, pyy: 2);
      final w = metropolisWeights([
        [1],
        [0],
      ]);
      final r = consensusFuse(
        estimates: [g, g],
        weights: w,
        iterations: 3,
        rule: FusionRule.ici,
      );
      expect(r.length, 2);
      expect(r[0].x, closeTo(1.0, 1e-9));
      expect(r[0].pxx, closeTo(2.0, 1e-9));
    });

    test('naive consensus shrinks covariance (double-counts)', () {
      const a = Gaussian2(x: 0, y: 0, pxx: 4, pxy: 0, pyy: 4);
      const b = Gaussian2(x: 2, y: 0, pxx: 4, pxy: 0, pyy: 4);
      final w = metropolisWeights([
        [1],
        [0],
      ]);
      final r = consensusFuse(
        estimates: [a, b],
        weights: w,
        iterations: 1,
        rule: FusionRule.naive,
      );
      // Each node ends up with a tighter covariance than either
      // input — the overconfidence the naive arm is meant to show.
      expect(r[0].pxx, lessThan(4.0));
    });
  });

  group('scoring', () {
    test('NEES of a 1-sigma error is 1', () {
      const g = Gaussian2(x: 0, y: 0, pxx: 1, pxy: 0, pyy: 1);
      expect(nees(g, 1, 0), closeTo(1.0, 1e-9));
      expect(nees(g, 0, 0), closeTo(0.0, 1e-9));
      expect(nees(g, 3, 4), closeTo(25.0, 1e-9));
    });

    test('mean-NEES 95% bounds bracket the consistent value 2', () {
      final b = neesMeanBounds95(100);
      expect(b.low, lessThan(2.0));
      expect(b.high, greaterThan(2.0));
      expect(b.low, greaterThan(0.0));
    });

    test('RMSE of known errors', () {
      // sqrt((0 + 25) / 2) = sqrt(12.5).
      expect(
        rmse([(0.0, 0.0), (3.0, 4.0)], [(0.0, 0.0), (0.0, 0.0)]),
        closeTo(3.5355339059, 1e-9),
      );
    });
  });
}
