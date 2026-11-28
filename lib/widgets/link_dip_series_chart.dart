/// Per-link dip time series (FL Chart), v0.30.0.
///
/// One link's dip — deviation from its rolling baseline, radio units
/// (estimate; only deltas are meaningful) — plotted against time,
/// with the link's trip threshold as a dashed line. Lives on the
/// Radios & Links screen, below the per-link health rows. The
/// link×time heatmap stays a custom canvas (untouched) — this is the
/// single-link series view, not a redesign.
///
/// Honest units: dip values come from Silvus radio-internal units;
/// the chart shows the raw deviation, never a distance or a
/// position. The threshold line is the link's own trip threshold
/// (see [LinkSample.effectiveThreshold]) when one was attached to
/// the samples, otherwise it is omitted.
///
/// Styling (2026-11-25 refinement): dark near-black ground, hairline
/// grid/borders, muted grey axis text. The series is a calm muted
/// grey — NOT the warm-amber accent, which would collide with the
/// amber trip-threshold line and with amber status (the accent is
/// reserved for the filled primary button and the selected tab).
/// Amber appears only for the trip threshold (status: elevated).
/// All colours live in [LinkDipSeriesStyle] as named constants so
/// the palette is a one-place change.
///
/// Motion: a playhead — a thin near-white vertical line at the newest
/// sample — sweeps to the new value when samples arrive
/// ([OutrideMotion.playhead]), instead of the line just extending.
/// The sweep is the chart's "new value" transition (Solora model);
/// the first render places the playhead with no sweep.
library;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../models/link_sample.dart';
import '../theme.dart';
import 'outride_motion.dart';

/// Pure mapping from samples to chart spots: x = seconds since the
/// first sample, y = dip in radio units. Testable without pumping a
/// widget; the widget is a thin render of this.
List<FlSpot> dipSeriesSpots(List<LinkSample> samples) {
  if (samples.isEmpty) return const [];
  final t0 = samples.first.timestamp;
  return [
    for (final s in samples)
      FlSpot(s.timestamp.difference(t0).inMilliseconds / 1000.0, s.dip),
  ];
}

/// Wall-clock label for an x value (seconds since [first]) on the
/// bottom axis, HH:MM:SS local time.
String dipSeriesTimeLabel(DateTime first, double seconds) {
  final t = first.add(Duration(milliseconds: (seconds * 1000).round()));
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

/// First finite trip threshold found in [samples], or null when no
/// sample carries one (raw samples that haven't been through the
/// tripwire yet have threshold NaN).
double? dipSeriesThreshold(List<LinkSample> samples) {
  for (final s in samples) {
    if (!s.threshold.isNaN) return s.threshold;
  }
  return null;
}

/// Chart palette for the dip series. Named constants, one place —
/// the cue list refines the palette here, not in the widget body.
abstract final class LinkDipSeriesStyle {
  /// The dip line: muted grey, calm on the near-black ground.
  /// Deliberately NOT the accent (see file doc).
  static const Color series = OutrideColors.dim;

  /// Fill under the line: the same grey, barely there.
  static final Color seriesFill =
      OutrideColors.dim.withValues(alpha: 0.10);

  /// Trip threshold line: amber, status only (elevated).
  static const Color threshold = OutrideColors.amber;

  /// Hairline grid + panel border.
  static final Color grid =
      OutrideColors.border.withValues(alpha: 0.6);

  /// Muted grey axis text.
  static const Color axisText = OutrideColors.muted;

  /// Tooltip background.
  static const Color tooltipBackground = OutrideColors.surface2;

  /// Playhead line: near-white "now" marker, brighter than the
  /// muted-grey series so the newest sample reads at a glance.
  static const Color playhead = OutrideColors.onDark;
}

/// FL Chart line chart of one link's dip over time, with a sweeping
/// playhead at the newest sample.
///
/// Empty [samples] renders a "NO SAMPLES YET" placeholder instead of
/// an empty chart — a chart with no data would read as a flat zero
/// line, which would be a false reading.
class LinkDipSeriesChart extends StatefulWidget {
  const LinkDipSeriesChart({
    super.key,
    required this.samples,
    this.threshold,
  });

  final List<LinkSample> samples;

  /// Trip threshold to draw as a dashed line, radio units. When
  /// null no threshold line is drawn.
  final double? threshold;

  @override
  State<LinkDipSeriesChart> createState() => _LinkDipSeriesChartState();
}

class _LinkDipSeriesChartState extends State<LinkDipSeriesChart> {
  /// Last-x the playhead rested at before the latest update. The
  /// playhead sweeps from here to the new last-x; initialised to
  /// the current last-x so the first render does not sweep.
  late double _prevLastX;

  @override
  void initState() {
    super.initState();
    final spots = dipSeriesSpots(widget.samples);
    _prevLastX = spots.isEmpty ? 0 : spots.last.x;
  }

  @override
  void didUpdateWidget(LinkDipSeriesChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldSpots = dipSeriesSpots(oldWidget.samples);
    if (oldSpots.isNotEmpty) _prevLastX = oldSpots.last.x;
  }

  @override
  Widget build(BuildContext context) {
    final samples = widget.samples;
    if (samples.isEmpty) {
      return const SizedBox(
        height: 180,
        child: Center(
          child: Text('NO SAMPLES YET', style: TextStyle(
            fontFamily: OutrideType.mono,
            fontSize: 11,
            letterSpacing: 1.6,
            color: OutrideColors.muted,
          )),
        ),
      );
    }
    final spots = dipSeriesSpots(samples);
    final first = samples.first.timestamp;
    final lastX = spots.last.x;
    // Pad the x range so the playhead sits just inside the right
    // edge instead of on it.
    final maxX = lastX + (lastX <= 0 ? 1.0 : lastX * 0.05);
    final threshold = widget.threshold;
    var minY = spots.map((s) => s.y).reduce((a, b) => a < b ? a : b);
    var maxY = spots.map((s) => s.y).reduce((a, b) => a > b ? a : b);
    if (threshold != null) {
      if (threshold < minY) minY = threshold;
      if (threshold > maxY) maxY = threshold;
    }
    // Pad the y range so a flat series still renders as a line, not
    // a degenerate zero-height chart.
    if ((maxY - minY).abs() < 1e-9) {
      minY -= 1;
      maxY += 1;
    } else {
      final pad = (maxY - minY) * 0.1;
      minY -= pad;
      maxY += pad;
    }
    final bottomInterval = maxX / 4;
    return SizedBox(
      height: 180,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: _prevLastX, end: lastX),
        duration: OutrideMotion.playhead,
        curve: OutrideMotion.curve,
        builder: (context, playheadX, _) => LineChart(
          _chartData(
            spots: spots,
            first: first,
            maxX: maxX,
            minY: minY,
            maxY: maxY,
            bottomInterval: bottomInterval,
            threshold: threshold,
            playheadX: playheadX,
          ),
        ),
      ),
    );
  }

  LineChartData _chartData({
    required List<FlSpot> spots,
    required DateTime first,
    required double maxX,
    required double minY,
    required double maxY,
    required double bottomInterval,
    required double? threshold,
    required double playheadX,
  }) {
    return LineChartData(
      minX: 0,
      maxX: maxX,
      minY: minY,
      maxY: maxY,
      lineBarsData: [
        LineChartBarData(
          spots: spots,
          isCurved: false,
          color: LinkDipSeriesStyle.series,
          barWidth: 2,
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(
            show: true,
            color: LinkDipSeriesStyle.seriesFill,
          ),
        ),
      ],
      extraLinesData: ExtraLinesData(
        horizontalLines: [
          if (threshold != null)
            HorizontalLine(
              y: threshold,
              color: LinkDipSeriesStyle.threshold,
              strokeWidth: 1,
              dashArray: const [6, 4],
              label: HorizontalLineLabel(
                show: true,
                alignment: Alignment.topRight,
                style: const TextStyle(
                  fontFamily: OutrideType.mono,
                  fontSize: 9,
                  color: LinkDipSeriesStyle.threshold,
                ),
                labelResolver: (_) => 'TRIP',
              ),
            ),
        ],
        verticalLines: [
          VerticalLine(
            x: playheadX,
            color: LinkDipSeriesStyle.playhead,
            strokeWidth: 1,
          ),
        ],
      ),
      gridData: FlGridData(
        show: true,
        drawVerticalLine: false,
        horizontalInterval: (maxY - minY) / 4,
        getDrawingHorizontalLine: (_) => FlLine(
          color: LinkDipSeriesStyle.grid,
          strokeWidth: 1,
        ),
      ),
      borderData: FlBorderData(
        show: true,
        border: Border.all(
          color: OutrideColors.border,
          width: 1,
        ),
      ),
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(
          sideTitles: SideTitles(showTitles: false),
        ),
        rightTitles: const AxisTitles(
          sideTitles: SideTitles(showTitles: false),
        ),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 36,
            interval: (maxY - minY) / 4,
            getTitlesWidget: (value, _) => Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Text(
                value.toStringAsFixed(0),
                textAlign: TextAlign.right,
                style: const TextStyle(
                  fontFamily: OutrideType.mono,
                  fontSize: 9,
                  color: LinkDipSeriesStyle.axisText,
                ),
              ),
            ),
          ),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 22,
            interval: bottomInterval <= 0 ? null : bottomInterval,
            getTitlesWidget: (value, _) => Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                dipSeriesTimeLabel(first, value),
                style: const TextStyle(
                  fontFamily: OutrideType.mono,
                  fontSize: 9,
                  color: LinkDipSeriesStyle.axisText,
                ),
              ),
            ),
          ),
        ),
      ),
      lineTouchData: LineTouchData(
        touchTooltipData: LineTouchTooltipData(
          getTooltipColor: (_) => LinkDipSeriesStyle.tooltipBackground,
          getTooltipItems: (touchedSpots) => [
            for (final s in touchedSpots)
              LineTooltipItem(
                'dip ${s.y.toStringAsFixed(0)} (est.)\n'
                '${dipSeriesTimeLabel(first, s.x)}',
                const TextStyle(
                  fontFamily: OutrideType.mono,
                  fontSize: 10,
                  color: OutrideColors.onDark,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
