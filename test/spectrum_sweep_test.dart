/// Tests for the wideband sweep model: parsing of the bridge's
/// sweep_step packets, malformed input, missing/out-of-range fields,
/// and tolerance of unknown fields.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/models/spectrum_sweep.dart';

Map<String, dynamic> _step({
  double center = 915.0,
  double span = 1.92,
  double energy = -62.4,
  double noise = -81.0,
  List<double>? bins,
  List<Map<String, dynamic>>? peaks,
  int sweepId = 3,
  int stepIndex = 412,
  int stepCount = 872,
  String radio = 'rtlsdr0',
}) {
  return {
    'v': 1,
    'kind': 'sweep_step',
    'radio': radio,
    'sweep_id': sweepId,
    'step_index': stepIndex,
    'step_count': stepCount,
    'center_mhz': center,
    'span_mhz': span,
    'energy_dbfs': energy,
    'noise_dbfs': noise,
    'bins_dbfs': bins ?? List.filled(32, -80.0),
    'peaks': peaks ??
        [
          {'freq_mhz': 915.14, 'dbfs': -48.3},
        ],
    't': 1729123456.789,
  };
}

void main() {
  group('SweepStep.tryParseJson', () {
    test('valid sweep step parses with all fields', () {
      final s = SweepStep.tryParseJson(_step());
      expect(s, isNotNull);
      expect(s!.radio, 'rtlsdr0');
      expect(s.sweepId, 3);
      expect(s.stepIndex, 412);
      expect(s.stepCount, 872);
      expect(s.centerMhz, 915.0);
      expect(s.spanMhz, 1.92);
      expect(s.energyDbfs, -62.4);
      expect(s.noiseDbfs, -81.0);
      expect(s.binsDbfs, hasLength(32));
      expect(s.peaks, hasLength(1));
      expect(s.peaks.first.freqMhz, 915.14);
      expect(s.peaks.first.dbfs, -48.3);
      expect(s.energyAboveFloor, closeTo(18.6, 0.001));
      expect(s.peaks.first.aboveFloor(s.noiseDbfs), closeTo(32.7, 0.001));
    });

    test('wrong kind or version is rejected', () {
      final band = _step()..['kind'] = 'band';
      expect(SweepStep.tryParseJson(band), isNull);
      final v2 = _step()..['v'] = 2;
      expect(SweepStep.tryParseJson(v2), isNull);
      expect(SweepStep.tryParseJson({}), isNull);
    });

    test('missing required field is rejected', () {
      for (final key in [
        'center_mhz',
        'span_mhz',
        'energy_dbfs',
        'noise_dbfs',
        'bins_dbfs',
      ]) {
        final m = _step()..remove(key);
        expect(SweepStep.tryParseJson(m), isNull, reason: key);
      }
    });

    test('non-finite values are rejected, never thrown', () {
      final nanEnergy = _step()..['energy_dbfs'] = double.nan;
      expect(SweepStep.tryParseJson(nanEnergy), isNull);
      final infNoise = _step()..['noise_dbfs'] = double.infinity;
      expect(SweepStep.tryParseJson(infNoise), isNull);
      final nanCenter = _step()..['center_mhz'] = double.nan;
      expect(SweepStep.tryParseJson(nanCenter), isNull);
    });

    test('out-of-range frequencies and levels are rejected', () {
      expect(SweepStep.tryParseJson(_step(center: 0.0)), isNull);
      expect(SweepStep.tryParseJson(_step(center: 7000.0)), isNull);
      expect(SweepStep.tryParseJson(_step(span: 0.0)), isNull);
      expect(SweepStep.tryParseJson(_step(span: 500.0)), isNull);
      // dBFS lives in [-200, 0]; a positive reading is corrupt data.
      expect(SweepStep.tryParseJson(_step(energy: 5.0)), isNull);
      expect(SweepStep.tryParseJson(_step(energy: -250.0)), isNull);
      expect(SweepStep.tryParseJson(_step(noise: 1.0)), isNull);
    });

    test('empty bins list rejects the step', () {
      expect(SweepStep.tryParseJson(_step(bins: [])), isNull);
    });

    test('non-finite bins are dropped, step kept', () {
      final bins = List<double>.filled(32, -80.0);
      bins[0] = double.nan;
      bins[1] = double.infinity;
      final s = SweepStep.tryParseJson(_step(bins: bins));
      expect(s, isNotNull);
      expect(s!.binsDbfs, hasLength(30));
    });

    test('bins cap at 256', () {
      final s = SweepStep.tryParseJson(
          _step(bins: List.filled(300, -80.0)));
      expect(s, isNotNull);
      expect(s!.binsDbfs, hasLength(SweepStep.maxBins));
    });

    test('peaks sort strongest first', () {
      final s = SweepStep.tryParseJson(_step(peaks: [
        {'freq_mhz': 915.5, 'dbfs': -70.0},
        {'freq_mhz': 915.14, 'dbfs': -48.3},
        {'freq_mhz': 914.8, 'dbfs': -60.0},
      ]));
      expect(s, isNotNull);
      expect(
          s!.peaks.map((p) => p.dbfs).toList(), [-48.3, -60.0, -70.0]);
    });

    test('out-of-span peak is dropped, step kept', () {
      // Span 1.92 around 915.0 covers 914.04–915.96.
      final s = SweepStep.tryParseJson(_step(peaks: [
        {'freq_mhz': 915.14, 'dbfs': -48.3},
        {'freq_mhz': 920.0, 'dbfs': -40.0},
      ]));
      expect(s, isNotNull);
      expect(s!.peaks, hasLength(1));
      expect(s.peaks.first.freqMhz, 915.14);
    });

    test('non-finite peak level is dropped, step kept', () {
      final s = SweepStep.tryParseJson(_step(peaks: [
        {'freq_mhz': 915.14, 'dbfs': double.nan},
      ]));
      expect(s, isNotNull);
      expect(s!.peaks, isEmpty);
    });

    test('missing peaks field means no peaks, not a rejection', () {
      final m = _step()..remove('peaks');
      final s = SweepStep.tryParseJson(m);
      expect(s, isNotNull);
      expect(s!.peaks, isEmpty);
    });

    test('unknown fields are tolerated', () {
      final m = _step()
        ..['future_field'] = {'anything': true}
        ..['sig_hint'] = 'tone-915';
      expect(SweepStep.tryParseJson(m), isNotNull);
    });
  });

  group('SweepStep.tryParseLine', () {
    test('valid JSON line parses', () {
      const line =
          '{"v":1,"kind":"sweep_step","radio":"rtlsdr0","sweep_id":0,'
          '"step_index":0,"step_count":26,"center_mhz":88.0,'
          '"span_mhz":1.92,"energy_dbfs":-90.5,"noise_dbfs":-101.0,'
          '"bins_dbfs":[-90.0,-91.0],"peaks":[],"t":1.0}';
      final s = SweepStep.tryParseLine(line);
      expect(s, isNotNull);
      expect(s!.centerMhz, 88.0);
      expect(s.binsDbfs, hasLength(2));
    });

    test('non-JSON and wrong-shape lines return null', () {
      expect(SweepStep.tryParseLine('not json'), isNull);
      expect(SweepStep.tryParseLine(''), isNull);
      expect(SweepStep.tryParseLine('[1,2,3]'), isNull);
      expect(SweepStep.tryParseLine('{"v":1,"kind":"band"}'), isNull);
    });

    test('verbatim bridge output parses (Python ↔ Dart contract)', () {
      // Real line from `sdr_bridge.py --simulate --wideband
      // --wideband-focus 88-108,902-928,1090 --sweeps 1 --print`,
      // 2026-11-12. This is a SHAPE contract, not a byte contract:
      // it asserts the packet's structure, bins length, and peak —
      // never exact bin values, which drift a few tenths of a dB
      // with the simulated noise floor between runs. If the bridge
      // changes its packet shape, this test is the tripwire — update
      // both sides together.
      const line =
          '{"v": 1, "kind": "sweep_step", "radio": "simulate0", '
          '"sweep_id": 0, "step_index": 25, "step_count": 26, '
          '"center_mhz": 1090.0, "span_mhz": 3.2, '
          '"energy_dbfs": -110.6, "noise_dbfs": -111.9, '
          '"bins_dbfs": [-107.9, -108.0, -108.5, -107.8, -106.7, '
          '-107.7, -107.2, -106.9, -107.9, -107.9, -108.0, -107.0, '
          '-108.0, -106.7, -107.8, -106.5, -107.6, -59.1, -107.7, '
          '-108.0, -107.5, -107.9, -107.8, -107.0, -107.0, -107.9, '
          '-107.4, -107.7, -108.1, -107.5, -107.0, -108.7], '
          '"peaks": [{"freq_mhz": 1090.15, "dbfs": -59.1}], '
          '"t": 1794501645.159282}';
      final s = SweepStep.tryParseLine(line);
      expect(s, isNotNull);
      expect(s!.centerMhz, 1090.0);
      expect(s.spanMhz, 3.2);
      expect(s.binsDbfs, hasLength(32));
      expect(s.peaks, hasLength(1));
      expect(s.peaks.first.freqMhz, 1090.15);
      expect(s.peaks.first.dbfs, -59.1);
      // The tone sits in bin 17 of 32: 1090 - 1.6 + 17.5*0.1.
      expect(s.binFreqMhz(17), closeTo(1090.15, 0.01));
    });
  });

  group('SweepStep.binFreqMhz', () {
    test('bins span the measured width evenly, low to high', () {
      final s = SweepStep.tryParseJson(_step(
        center: 915.0,
        span: 1.92,
        bins: List.filled(32, -80.0),
        peaks: [],
      ))!;
      // First bin center: 915 - 0.96 + 0.03 = 914.07.
      expect(s.binFreqMhz(0), closeTo(914.07, 0.001));
      // Last bin center: 915 + 0.96 - 0.03 = 915.93.
      expect(s.binFreqMhz(31), closeTo(915.93, 0.001));
      // Bin centers increase monotonically.
      for (var i = 1; i < 32; i++) {
        expect(s.binFreqMhz(i), greaterThan(s.binFreqMhz(i - 1)));
      }
    });
  });
}
