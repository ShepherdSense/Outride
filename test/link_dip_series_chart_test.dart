/// Widget + unit tests for the per-link dip time series chart
/// (FL Chart, v0.30.0) on the Radios & Links screen.
///
/// The sample data below is a TEST FIXTURE — synthetic values made
/// up for rendering checks, never measurements. No test here asserts
/// anything about real link data.
library;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:outride/models/link_sample.dart';
import 'package:outride/widgets/link_dip_series_chart.dart';

/// TEST FIXTURE: four synthetic samples, 10 s apart, dip rising
/// through the (also synthetic) threshold of 10 radio units.
List<LinkSample> _fixtureSamples() {
  final t0 = DateTime(2026, 11, 25, 12, 0, 0);
  return [
    LinkSample(
        timestamp: t0, fromNode: 'A', toNode: 'B', dip: 2, threshold: 10),
    LinkSample(
        timestamp: t0.add(const Duration(seconds: 10)),
        fromNode: 'A',
        toNode: 'B',
        dip: 5,
        threshold: 10),
    LinkSample(
        timestamp: t0.add(const Duration(seconds: 20)),
        fromNode: 'A',
        toNode: 'B',
        dip: 12,
        threshold: 10),
    LinkSample(
        timestamp: t0.add(const Duration(seconds: 30)),
        fromNode: 'A',
        toNode: 'B',
        dip: 4,
        threshold: 10),
  ];
}

void main() {
  group('dipSeriesSpots (pure mapping)', () {
    test('x is seconds since the first sample, y is the dip', () {
      final spots = dipSeriesSpots(_fixtureSamples());
      expect(spots, [
        const FlSpot(0, 2),
        const FlSpot(10, 5),
        const FlSpot(20, 12),
        const FlSpot(30, 4),
      ]);
    });

    test('empty samples map to no spots', () {
      expect(dipSeriesSpots(const []), isEmpty);
    });
  });

  group('dipSeriesThreshold', () {
    test('returns the first finite threshold', () {
      expect(dipSeriesThreshold(_fixtureSamples()), 10);
    });

    test('null when no sample carries a threshold', () {
      final samples = [
        LinkSample(timestamp: DateTime(2026, 11, 25), fromNode: 'A', toNode: 'B'),
        LinkSample(
            timestamp: DateTime(2026, 11, 25, 0, 0, 1),
            fromNode: 'A',
            toNode: 'B'),
      ];
      expect(dipSeriesThreshold(samples), isNull);
    });
  });

  group('dipSeriesTimeLabel', () {
    test('formats wall-clock HH:MM:SS', () {
      final first = DateTime(2026, 11, 25, 12, 0, 0);
      expect(dipSeriesTimeLabel(first, 0), '12:00:00');
      expect(dipSeriesTimeLabel(first, 75), '12:01:15');
    });
  });

  group('LinkDipSeriesChart widget', () {
    testWidgets('renders a LineChart for fixture samples',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LinkDipSeriesChart(
              samples: _fixtureSamples(),
              threshold: 10,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(LineChart), findsOneWidget);
      expect(find.text('NO SAMPLES YET'), findsNothing);
    });

    testWidgets('empty samples show the placeholder, not an empty chart',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LinkDipSeriesChart(samples: []),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('NO SAMPLES YET'), findsOneWidget);
      expect(find.byType(LineChart), findsNothing);
    });

    testWidgets('renders without a threshold line when none is given',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LinkDipSeriesChart(samples: _fixtureSamples()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(LineChart), findsOneWidget);
    });

    testWidgets('new samples sweep the playhead, chart still renders',
        (tester) async {
      final firstThree = _fixtureSamples().sublist(0, 3);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LinkDipSeriesChart(
              samples: firstThree,
              threshold: 10,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(LineChart), findsOneWidget);
      // One more sample arrives: the playhead sweeps to the new
      // last-x instead of the line just extending.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LinkDipSeriesChart(
              samples: _fixtureSamples(),
              threshold: 10,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(LineChart), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
