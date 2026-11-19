/// Tests for the Spectrum view: bar fraction math, pass
/// downsampling, allocation labels, and the no-driver setup hint.
///
/// A full widget test with a live driver is deliberately not here:
/// getting an SdrDriver into AppState requires start(), which
/// starts polling and binds a UDP socket — too heavy for a unit
/// test. What IS covered: the math the screen actually renders
/// (bar fractions, hottest-step-per-bucket downsampling) and the
/// setup hint the view degrades to when no driver is added,
/// including the "press Start" step — the one step that makes
/// anything listen.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:outride/models/spectrum_sweep.dart';
import 'package:outride/screens/spectrum_screen.dart';
import 'package:outride/services/radio_driver.dart';
import 'package:outride/state/app_state.dart';

String _sweepStep({
  required double center,
  required int sweepId,
  required int stepIndex,
  List<Map<String, dynamic>>? peaks,
}) {
  final peaksJson = peaks == null
      ? '[]'
      : '[${peaks.map((p) => '{"freq_mhz":${p['freq_mhz']},"dbfs":${p['dbfs']}}').join(',')}]';
  final bins = List.filled(32, -90.0).join(',');
  return '{"v":1,"kind":"sweep_step","radio":"rtlsdr0",'
      '"sweep_id":$sweepId,"step_index":$stepIndex,'
      '"step_count":3,"center_mhz":$center,"span_mhz":1.92,'
      '"energy_dbfs":-80.0,"noise_dbfs":-100.0,'
      '"bins_dbfs":[$bins],"peaks":$peaksJson,"t":1729123456.0}';
}

SweepStep _step(double center, double energy) => SweepStep(
      receivedAt: DateTime.now(),
      radio: 'rtlsdr0',
      sweepId: 0,
      stepIndex: 0,
      stepCount: 1,
      centerMhz: center,
      spanMhz: 1.92,
      energyDbfs: energy,
      noiseDbfs: -100.0,
      binsDbfs: const [-90.0],
      peaks: const [],
    );

void main() {
  group('sweepBarFraction', () {
    test('floor and ceiling map to the bar ends', () {
      expect(sweepBarFraction(-110.0), 0.0);
      expect(sweepBarFraction(-30.0), 1.0);
      expect(sweepBarFraction(-70.0), 0.5);
    });

    test('values clamp to the bar', () {
      expect(sweepBarFraction(-10.0), 1.0); // hotter than ceiling
      expect(sweepBarFraction(-150.0), 0.0); // below floor
    });
  });

  group('spectrumDisplaySteps', () {
    test('short passes pass through untouched', () {
      final steps = [_step(88.0, -90.0), _step(90.0, -80.0)];
      expect(spectrumDisplaySteps(steps), steps);
    });

    test('long passes downsample to 60 rows, hottest per bucket', () {
      // 120 steps: 2 per bucket. Even-index steps are hot (-50),
      // odd-index steps are quiet (-100).
      final steps = List.generate(
          120, (i) => _step(24.0 + i * 2.0, i.isEven ? -50.0 : -100.0));
      final shown = spectrumDisplaySteps(steps);
      expect(shown, hasLength(60));
      // Every kept row is a hot step: max-pool, never mean-pool.
      expect(shown.every((s) => s.energyDbfs == -50.0), isTrue);
      // First bucket keeps the first hot step, last bucket the last.
      expect(shown.first.centerMhz, 24.0);
      expect(shown.last.centerMhz, 24.0 + 118 * 2.0);
    });

    test('a full 872-step V3 pass downsamples to 60 rows', () {
      final steps = List.generate(
          872, (i) => _step(24.0 + i * 2.0, -90.0 + (i % 10)));
      expect(spectrumDisplaySteps(steps), hasLength(60));
    });
  });

  group('allocationHint', () {
    test('known bands label, unknown bands do not', () {
      expect(allocationHint(98.0), 'FM broadcast');
      expect(allocationHint(121.5), 'Airband');
      expect(allocationHint(146.0), '2 m amateur');
      expect(allocationHint(157.0), 'Marine VHF');
      expect(allocationHint(433.0), 'UHF / 70 cm');
      expect(allocationHint(915.0), 'ISM 915');
      expect(allocationHint(1090.0), 'ADS-B');
      expect(allocationHint(10.0), 'HF');
      expect(allocationHint(500.0), isNull);
      expect(allocationHint(2400.0), isNull);
    });
  });

  group('fmtFreq', () {
    test('MHz below 1 GHz, GHz at/above', () {
      expect(fmtFreq(915.0), '915.0 MHz');
      expect(fmtFreq(1090.0), '1.090 GHz');
      expect(fmtFreq(1766.0), '1.766 GHz');
    });
  });

  group('SpectrumScreen without a driver', () {
    testWidgets('setup hint renders, names the Start step, no overflow',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SpectrumScreen(state: state))),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('NO SDR DRIVER'), findsOneWidget);
      expect(find.text('SPECTRUM'), findsOneWidget);
      expect(find.text('EXPERIMENTAL'), findsOneWidget);
      // The hint must name the step that makes anything listen.
      expect(
          find.textContaining('then press Start'), findsOneWidget);
      // And the bridge command that produces the survey.
      expect(find.textContaining('--wideband'), findsOneWidget);
      // Honest-scope note is on the view itself.
      expect(find.textContaining('receive-only ears'), findsOneWidget);
      expect(find.textContaining('never an identification'),
          findsOneWidget);
    });
  });

  group('SpectrumScreen with a driver (populated view)', () {
    testWidgets('steps + peaks render at 360 px, peaks deduped, no overflow',
        (tester) async {
      // Review S6: only the no-driver hint was pumped before — the
      // populated rows were never rendered in a test, which is
      // exactly how the Fetch header overflow slipped through.
      // attachDriverForTest adds a poller without starting it, so
      // no socket is bound and no polling runs.
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState();
      addTearDown(state.dispose);
      final d = SdrDriver(host: '127.0.0.1', port: 49161);
      state.attachDriverForTest(d);
      // Two overlapping steps (0.5 MHz step, 1.92 MHz span) carrying
      // the SAME tone: the peaks card must show it once (S5 dedupe),
      // not once per step.
      d.datagramForTest(_sweepStep(
        center: 915.0,
        sweepId: 0,
        stepIndex: 0,
        peaks: [
          {'freq_mhz': 915.14, 'dbfs': -48.3},
        ],
      ));
      d.datagramForTest(_sweepStep(
        center: 915.5,
        sweepId: 0,
        stepIndex: 1,
        peaks: [
          {'freq_mhz': 915.14, 'dbfs': -48.3},
        ],
      ));
      d.datagramForTest(_sweepStep(
        center: 1090.0,
        sweepId: 0,
        stepIndex: 2,
        peaks: [
          {'freq_mhz': 1090.15, 'dbfs': -59.1},
        ],
      ));
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SpectrumScreen(state: state))),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('SPECTRUM'), findsOneWidget);
      expect(find.text('EXPERIMENTAL'), findsOneWidget);
      expect(find.textContaining('DETECTED PEAKS'), findsOneWidget);
      // The shared 915.14 tone appears once despite two steps.
      expect(find.text('915.1 MHz'), findsOneWidget);
      expect(find.text('ISM 915'), findsOneWidget);
      expect(find.text('ADS-B'), findsOneWidget);
      // Status card counts the pass.
      expect(find.textContaining('Steps in current pass'), findsOneWidget);
      // The spectrum card sits below the fold in a ListView (lazy
      // build): scroll it into view before asserting its rows.
      await tester.scrollUntilVisible(
        find.textContaining('ENERGY BY FREQUENCY'),
        200,
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('ENERGY BY FREQUENCY'), findsOneWidget);
      // Step rows show their centers.
      expect(find.text('915.0 MHz'), findsOneWidget);
      expect(find.text('915.5 MHz'), findsOneWidget);
    });
  });
}
