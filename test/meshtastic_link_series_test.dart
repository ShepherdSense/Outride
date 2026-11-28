import 'package:flutter_test/flutter_test.dart';
import 'package:outride/services/meshtastic_link_series.dart';

MeshLinkSample _s(int from, int to, double snr, {DateTime? at}) =>
    MeshLinkSample(
      timestamp: at ?? DateTime.now(),
      fromNode: from,
      toNode: to,
      snr: snr,
    );

void main() {
  group('MeshLinkSeries ring buffer', () {
    test('records and returns a per-edge series', () {
      final s = MeshLinkSeries();
      final t = DateTime.now();
      s.record(_s(0x11111111, 0, 5.0, at: t));
      s.record(_s(0x11111111, 0, 6.0, at: t));
      s.record(_s(0x22222222, 0, -3.0, at: t));
      expect(s.sampleCount, 3);
      expect(s.edgeCount, 2);
      expect(s.seriesFor(0x11111111, 0).length, 2);
      expect(s.seriesFor(0x11111111, 0).first.snr, 5.0);
      expect(s.seriesFor(0x22222222, 0).length, 1);
      expect(s.seriesFor(0x33333333, 0), isEmpty);
      expect(
          s.edges,
          containsAll([
            (0x11111111, 0),
            (0x22222222, 0),
          ]));
    });

    test('caps at 512 samples per edge, dropping the oldest', () {
      final s = MeshLinkSeries();
      final base = DateTime.now();
      for (var i = 0; i < 600; i++) {
        s.record(_s(1, 0, i.toDouble(),
            at: base.add(Duration(seconds: i))));
      }
      final series = s.seriesFor(1, 0);
      expect(series.length, MeshLinkSeries.maxSamplesPerEdge);
      // First 88 dropped: oldest kept is i=88.
      expect(series.first.snr, 88.0);
      expect(series.last.snr, 599.0);
      expect(s.sampleCount, 512);
    });

    test('caps at 256 edges, dropping the stalest edge', () {
      final s = MeshLinkSeries();
      final base = DateTime.now();
      for (var i = 1; i <= 300; i++) {
        s.record(_s(i, 0, 1.0,
            at: base.add(Duration(seconds: i))));
      }
      expect(s.edgeCount, MeshLinkSeries.maxEdges);
      // Edges 1..44 were the stalest and got dropped.
      expect(s.seriesFor(1, 0), isEmpty);
      expect(s.seriesFor(44, 0), isEmpty);
      expect(s.seriesFor(45, 0), isNotEmpty);
      expect(s.seriesFor(300, 0), isNotEmpty);
    });

    test('prune drops old samples and empty edges', () {
      final s = MeshLinkSeries();
      final now = DateTime.now();
      s.record(_s(1, 0, 1.0, at: now.subtract(const Duration(hours: 2))));
      s.record(_s(1, 0, 2.0, at: now));
      s.record(_s(2, 0, 3.0, at: now.subtract(const Duration(hours: 2))));
      s.pruneOlderThan(const Duration(hours: 1), now: now);
      expect(s.seriesFor(1, 0).length, 1);
      expect(s.seriesFor(1, 0).first.snr, 2.0);
      expect(s.seriesFor(2, 0), isEmpty);
      expect(s.edgeCount, 1);
    });

    test('samples with no measurement at all are dropped', () {
      final s = MeshLinkSeries();
      s.record(MeshLinkSample(
        timestamp: DateTime.now(),
        fromNode: 1,
        toNode: 0,
      ));
      expect(s.sampleCount, 0);
    });
  });

  group('step-change detection', () {
    test('detects a synthetic step (shadowed link)', () {
      final s = MeshLinkSeries();
      final base = DateTime.now();
      // Baseline: 5 samples at +5 dB, then 5 at -5 dB (link shadowed).
      for (var i = 0; i < 5; i++) {
        s.record(_s(1, 0, 5.0, at: base.add(Duration(seconds: i))));
      }
      for (var i = 5; i < 10; i++) {
        s.record(_s(1, 0, -5.0, at: base.add(Duration(seconds: i))));
      }
      final step = s.detectStep(1, 0, window: 5, minStepDb: 3.0);
      expect(step, isNotNull);
      expect(step, closeTo(-10.0, 1e-9));
    });

    test('flat series detects no step (negative test)', () {
      // A detector that fired on a flat line would be useless (every
      // quiet link would alarm). This is a plain negative test: a
      // flat series must NOT produce a step. (Previously mislabeled
      // 'FAILING-BEFORE case' — it never demonstrated a pre-fix
      // failure; relabeled in the 2026-11-28 review fix round.)
      final s = MeshLinkSeries();
      final base = DateTime.now();
      for (var i = 0; i < 10; i++) {
        s.record(_s(1, 0, 5.0, at: base.add(Duration(seconds: i))));
      }
      expect(s.detectStep(1, 0, window: 5, minStepDb: 3.0), isNull);
    });

    test('small steps below the threshold are not reported', () {
      final s = MeshLinkSeries();
      final base = DateTime.now();
      for (var i = 0; i < 5; i++) {
        s.record(_s(1, 0, 5.0, at: base.add(Duration(seconds: i))));
      }
      for (var i = 5; i < 10; i++) {
        s.record(_s(1, 0, 6.0, at: base.add(Duration(seconds: i))));
      }
      // 1 dB step < 3 dB minimum: noise, not a step.
      expect(s.detectStep(1, 0, window: 5, minStepDb: 3.0), isNull);
    });

    test('too few samples returns null', () {
      final s = MeshLinkSeries();
      for (var i = 0; i < 9; i++) {
        s.record(_s(1, 0, i.isEven ? 5.0 : -5.0));
      }
      expect(s.detectStep(1, 0, window: 5), isNull);
    });

    test('degenerate window returns null instead of throwing', () {
      // detectStep(window: 0) used to throw RangeError from
      // sublist; a public method must return null.
      final s = MeshLinkSeries();
      final base = DateTime.now();
      for (var i = 0; i < 10; i++) {
        s.record(_s(1, 0, i < 5 ? 5.0 : -5.0,
            at: base.add(Duration(seconds: i))));
      }
      expect(s.detectStep(1, 0, window: 0), isNull);
      expect(s.detectStep(1, 0, window: -3), isNull);
      expect(s.detectStep(1, 0, window: 5, minStepDb: -1.0), isNull);
      expect(s.detectStep(1, 0, window: 5, minStepDb: double.nan),
          isNull);
      // The same series still detects with a valid window.
      expect(s.detectStep(1, 0, window: 5, minStepDb: 3.0),
          closeTo(-10.0, 1e-9));
    });

    test('non-finite SNR is dropped at record, never poisons detectStep',
        () {
      final s = MeshLinkSeries();
      final base = DateTime.now();
      for (var i = 0; i < 5; i++) {
        s.record(_s(1, 0, 5.0, at: base.add(Duration(seconds: i))));
      }
      // A NaN sample must not be stored (and must not make
      // detectStep return NaN).
      s.record(MeshLinkSample(
        timestamp: base.add(const Duration(seconds: 5)),
        fromNode: 1,
        toNode: 0,
        snr: double.nan,
      ));
      expect(s.sampleCount, 5);
      for (var i = 6; i < 11; i++) {
        s.record(_s(1, 0, -5.0, at: base.add(Duration(seconds: i))));
      }
      final step = s.detectStep(1, 0, window: 5, minStepDb: 3.0);
      expect(step, isNotNull);
      expect(step!.isFinite, isTrue);
      expect(step, closeTo(-10.0, 1e-9));
    });

    test('RSSI-only edges detect steps on RSSI', () {
      final s = MeshLinkSeries();
      final base = DateTime.now();
      for (var i = 0; i < 5; i++) {
        s.record(MeshLinkSample(
          timestamp: base.add(Duration(seconds: i)),
          fromNode: 1,
          toNode: 0,
          rssi: -90.0,
        ));
      }
      for (var i = 5; i < 10; i++) {
        s.record(MeshLinkSample(
          timestamp: base.add(Duration(seconds: i)),
          fromNode: 1,
          toNode: 0,
          rssi: -110.0,
        ));
      }
      final step = s.detectStep(1, 0, window: 5, minStepDb: 3.0);
      expect(step, closeTo(-20.0, 1e-9));
    });

    test('median is robust to one outlier in each window', () {
      final s = MeshLinkSeries();
      final base = DateTime.now();
      // Prior window median 5 despite one -50 outlier; recent
      // window median -5 despite one +50 outlier.
      for (final v in [5.0, 5.0, -50.0, 5.0, 5.0]) {
        s.record(_s(1, 0, v,
            at: base.add(Duration(seconds: s.sampleCount))));
      }
      for (final v in [-5.0, -5.0, 50.0, -5.0, -5.0]) {
        s.record(_s(1, 0, v,
            at: base.add(Duration(seconds: s.sampleCount))));
      }
      expect(s.detectStep(1, 0, window: 5, minStepDb: 3.0),
          closeTo(-10.0, 1e-9));
    });
  });

  group('MeshChannelUtilization', () {
    test('records latest per node', () {
      final u = MeshChannelUtilization();
      expect(u.latest(7), isNull);
      u.record(7, 12.5, 3.25);
      expect(u.latest(7)!.chUtil, 12.5);
      expect(u.latest(7)!.airUtil, 3.25);
      u.record(7, null, 4.0);
      expect(u.latest(7)!.chUtil, isNull);
      expect(u.latest(7)!.airUtil, 4.0);
    });

    test('caps at 256 entries, evicting the stalest', () {
      final u = MeshChannelUtilization();
      final base = DateTime.now();
      for (var i = 1; i <= 300; i++) {
        u.record(i, 1.0, null,
            at: base.add(Duration(seconds: i)));
      }
      expect(u.entryCount, MeshChannelUtilization.maxEntries);
      // Nodes 1..44 were stalest and got evicted.
      expect(u.latest(1), isNull);
      expect(u.latest(44), isNull);
      expect(u.latest(45), isNotNull);
      expect(u.latest(300), isNotNull);
    });

    test('pruneOlderThan drops stale entries', () {
      final u = MeshChannelUtilization();
      final now = DateTime.now();
      u.record(1, 1.0, null,
          at: now.subtract(const Duration(hours: 2)));
      u.record(2, 2.0, null, at: now);
      u.pruneOlderThan(const Duration(hours: 1), now: now);
      expect(u.latest(1), isNull);
      expect(u.latest(2), isNotNull);
    });

    test('non-finite values are dropped, not stored (re-review item 6)',
        () {
      // MeshLinkSeries.record filters non-finite measurements; the
      // utilization class is public too, and a NaN chUtil stored
      // here flows straight into the guard as
      // observedUtilizationPercent, making maySend compute NaN and
      // refuse forever.
      final u = MeshChannelUtilization();
      u.record(7, double.nan, null);
      expect(u.latest(7), isNull);
      expect(u.entryCount, 0);
      u.record(7, double.infinity, double.negativeInfinity);
      expect(u.latest(7), isNull);
      expect(u.entryCount, 0);
      // A sample with one finite field keeps only that field.
      u.record(7, double.nan, 4.0);
      expect(u.latest(7)!.chUtil, isNull);
      expect(u.latest(7)!.airUtil, 4.0);
      u.record(8, 12.5, double.nan);
      expect(u.latest(8)!.chUtil, 12.5);
      expect(u.latest(8)!.airUtil, isNull);
      // Finite values still record (and overwrite a filtered one).
      u.record(7, 2.5, 3.5);
      expect(u.latest(7)!.chUtil, 2.5);
      expect(u.latest(7)!.airUtil, 3.5);
    });
  });
}
