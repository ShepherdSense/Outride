import 'package:flutter_test/flutter_test.dart';
import 'package:outride/services/fusion_bench.dart';
import 'package:outride/services/fusion_bench_association.dart';

const _g = Gaussian2(x: 0, y: 0, pxx: 1, pxy: 0, pyy: 1);

RfTrackState _rf({
  double x = 0,
  double y = 0,
  double vx = 1,
  double vy = 0,
  double dip = 10,
  Map<String, double> sig = const {},
}) =>
    RfTrackState(
      estimate: Gaussian2(x: x, y: y, pxx: 1, pxy: 0, pyy: 1),
      vx: vx,
      vy: vy,
      meanDipDb: dip,
      dropSignature: sig,
    );

CorrTrack _corr({
  String id = 'n1',
  double x = 0,
  double y = 0,
  double vx = 1,
  double vy = 0,
  double dip = 10,
  Map<String, double> sig = const {},
  String? truthId,
}) =>
    CorrTrack(
      id: id,
      x: x,
      y: y,
      vx: vx,
      vy: vy,
      meanDipDb: dip,
      dropSignature: sig,
      truthId: truthId,
    );

void main() {
  group('hungarian', () {
    test('2x2 picks the minimum total', () {
      expect(hungarian([
        [1.0, 2.0],
        [2.0, 1.0],
      ]), containsAll([(0, 0), (1, 1)]));
      expect(hungarian([
        [5.0, 1.0],
        [1.0, 5.0],
      ]), containsAll([(0, 1), (1, 0)]));
    });

    test('rectangular: more columns than rows', () {
      final pairs = hungarian([
        [9.0, 1.0, 9.0],
        [9.0, 9.0, 1.0],
      ]);
      expect(pairs, containsAll([(0, 1), (1, 2)]));
      expect(pairs.length, 2);
    });

    test('rectangular: more rows than columns transposes', () {
      final pairs = hungarian([
        [1.0, 9.0],
        [9.0, 1.0],
        [5.0, 5.0],
      ]);
      expect(pairs.length, 2);
      expect(pairs, containsAll([(0, 0), (1, 1)]));
    });

    test('empty input', () {
      expect(hungarian([]), isEmpty);
      expect(hungarian([[]]), isEmpty);
    });
  });

  group('mahalanobis2', () {
    test('3-4-5 triangle', () {
      expect(mahalanobis2(_g, 3, 4), closeTo(25.0, 1e-9));
      expect(mahalanobis2(_g, 0, 0), closeTo(0.0, 1e-9));
    });
  });

  group('dropSignatureSimilarity', () {
    test('identical signatures score 1, disjoint score 0', () {
      expect(
        dropSignatureSimilarity({'a': 10.0, 'b': 5.0}, {'a': 10.0, 'b': 5.0}),
        closeTo(1.0, 1e-9),
      );
      expect(
        dropSignatureSimilarity({'a': 10.0}, {'b': 10.0}),
        closeTo(0.0, 1e-9),
      );
      expect(dropSignatureSimilarity({}, {'a': 1.0}), 0.0);
    });
  });

  group('associationCost', () {
    test('kinematics-only is maha2 / gate', () {
      final rf = _rf();
      final corr = _corr(x: 3, y: 4);
      expect(
        associationCost(
            rf: rf, corr: corr, features: FeatureSet.kinematics),
        closeTo(25.0 / 9.21, 1e-9),
      );
    });

    test('dip difference adds cost', () {
      final rf = _rf(dip: 10);
      final close = _corr(dip: 10);
      final far = _corr(dip: 20);
      final cClose = associationCost(
          rf: rf, corr: close, features: FeatureSet.plusDip);
      final cFar = associationCost(
          rf: rf, corr: far, features: FeatureSet.plusDip);
      expect(cFar, greaterThan(cClose));
      expect(cFar - cClose, closeTo(10.0 / 5.0, 1e-9));
    });

    test('motion mismatch adds cost', () {
      final rf = _rf(vx: 2, vy: 0);
      final same = _corr(vx: 2, vy: 0);
      final opposite = _corr(vx: -2, vy: 0);
      final cSame = associationCost(
          rf: rf, corr: same, features: FeatureSet.plusDipAndMotion);
      final cOpp = associationCost(
          rf: rf, corr: opposite, features: FeatureSet.plusDipAndMotion);
      expect(cOpp, greaterThan(cSame));
    });
  });

  group('associate', () {
    test('picks the in-gate match, rejects the out-of-gate one', () {
      final assocs = associate(
        rfTracks: [_rf()],
        corrTracks: [_corr(id: 'near', x: 0.5, y: 0), _corr(id: 'far', x: 50, y: 0)],
        features: FeatureSet.kinematics,
      );
      expect(assocs.length, 1);
      expect(assocs.first.corrIndex, 0);
    });

    test('empty inputs associate nothing', () {
      expect(
        associate(
            rfTracks: [], corrTracks: [_corr()], features: FeatureSet.kinematics),
        isEmpty,
      );
      expect(
        associate(
            rfTracks: [_rf()], corrTracks: [], features: FeatureSet.kinematics),
        isEmpty,
      );
    });

    test('features break a kinematics tie toward the matching dip', () {
      // Two corroborators at the same spot: kinematics cannot tell
      // them apart, but the dip feature can.
      final rf = _rf(dip: 12);
      final a = _corr(id: 'a', x: 1, y: 0, dip: 12);
      final b = _corr(id: 'b', x: 1, y: 0, dip: 2);
      final kin = associate(
        rfTracks: [rf],
        corrTracks: [b, a],
        features: FeatureSet.kinematics,
      );
      // Kinematics-only: either is equally good (both cost the
      // same); the Hungarian picks the first minimum — the point is
      // the call succeeds and picks exactly one.
      expect(kin.length, 1);
      final feat = associate(
        rfTracks: [rf],
        corrTracks: [b, a],
        features: FeatureSet.plusDip,
      );
      expect(feat.length, 1);
      // Feature-aided picks 'a' (index 1, matching dip).
      expect(feat.first.corrIndex, 1);
    });
  });

  group('trajectorySimilarity (CATS)', () {
    List<TrackPoint> straight(double x0, double vx) => [
          for (var i = 0; i < 5; i++)
            TrackPoint(t: i.toDouble(), x: x0 + vx * i, y: 0, vx: vx, vy: 0),
        ];

    test('identical tracklets score ~1', () {
      expect(trajectorySimilarity(straight(0, 1), straight(0, 1)),
          closeTo(1.0, 1e-9));
    });

    test('opposite directions score low', () {
      expect(trajectorySimilarity(straight(0, 1), straight(0, -1)),
          lessThan(0.5));
    });

    test('non-overlapping tracklets score 0', () {
      final a = straight(0, 1);
      final b = [
        for (var i = 0; i < 5; i++)
          TrackPoint(t: 10.0 + i, x: i.toDouble(), y: 0, vx: 1, vy: 0),
      ];
      expect(trajectorySimilarity(a, b), 0.0);
    });
  });

  group('catsMatch', () {
    test('bidirectional best matches pair up', () {
      final sim = [
        [0.9, 0.2],
        [0.1, 0.8],
      ];
      expect(catsMatch(sim), containsAll([(0, 0), (1, 1)]));
    });

    test('one-way best does not match', () {
      // Row 0 wants col 0, but col 0 prefers row 1.
      final sim = [
        [0.6, 0.1],
        [0.9, 0.2],
      ];
      expect(catsMatch(sim), [(1, 0)]);
    });

    test('below-threshold pairs are rejected', () {
      expect(catsMatch([
        [0.4, 0.3],
        [0.2, 0.45],
      ]), isEmpty);
    });
  });
}
