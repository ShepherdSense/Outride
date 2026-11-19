/// Spectrum view — wideband survey from the SDR bridge.
///
/// EXPERIMENTAL. Shows, all live from the bridge's `--wideband`
/// sweep_step packets over UDP 49161 (via the SdrDriver):
///   - per-step energy bars across the surveyed range
///     (24–1766 MHz on the RTL-SDR V3, ~2 MHz steps)
///   - detected peaks list: local maxima above the adaptive noise
///     floor (strongest first)
///
/// HONEST SCOPE (shown on the view itself): receive-only ears.
/// A peak is ENERGY, never an identification — it says "something
/// is transmitting here", never what it is. One radio reports
/// energy, not direction. A full V3 pass takes ~1–2 minutes, so a
/// fast hopper can slip between visits. Sweep steps are display
/// only: they never become tripwire links, so a survey can never
/// drive the tripwire, the tracker, or the merger.
///
/// When no SDR driver is added the view degrades to a setup hint —
/// absence of a driver is never presented as "nothing is happening".
library;

import 'package:flutter/material.dart';

import '../models/spectrum_sweep.dart';
import '../state/app_state.dart';
import '../theme.dart';

String _clock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:'
    '${t.minute.toString().padLeft(2, '0')}:'
    '${t.second.toString().padLeft(2, '0')}';

String _age(DateTime t, DateTime now) {
  final s = now.difference(t).inSeconds;
  if (s < 5) return 'just now';
  if (s < 60) return '${s}s ago';
  final m = s ~/ 60;
  if (m < 60) return '${m}m ago';
  return '${m ~/ 60}h ${m % 60}m ago';
}

/// Frequency label: MHz below 1 GHz, GHz at/above.
String fmtFreq(double mhz) => mhz >= 1000.0
    ? '${(mhz / 1000).toStringAsFixed(3)} GHz'
    : '${mhz.toStringAsFixed(1)} MHz';

/// Fraction of an energy bar a dBFS reading fills (0..1), clamped.
/// Display window -110 dBFS (floor) to -30 dBFS (hot). Testable in
/// isolation: -110 -> 0.0, -70 -> 0.5, -30 -> 1.0.
@visibleForTesting
double sweepBarFraction(double energyDbfs) =>
    ((energyDbfs + 110.0) / 80.0).clamp(0.0, 1.0);

/// Downsample a pass to at most [maxRows] display rows, keeping the
/// hottest step of each bucket (max-pool, never mean-pool, so a hot
/// narrow step is never washed out). Input must be center-sorted.
/// Testable in isolation.
@visibleForTesting
List<SweepStep> spectrumDisplaySteps(List<SweepStep> steps,
    {int maxRows = 60}) {
  if (steps.length <= maxRows) return steps;
  final out = <SweepStep>[];
  final bucketSize = steps.length / maxRows;
  for (var i = 0; i < maxRows; i++) {
    final lo = (i * bucketSize).floor();
    final hi = ((i + 1) * bucketSize).floor().clamp(lo + 1, steps.length);
    var hottest = steps[lo];
    for (var j = lo + 1; j < hi; j++) {
      if (steps[j].energyDbfs > hottest.energyDbfs) hottest = steps[j];
    }
    out.add(hottest);
  }
  return out;
}

/// Well-established allocation for a frequency, as a band label —
/// never an identification of what is transmitting. Null when the
/// band has no single obvious label.
String? allocationHint(double mhz) {
  if (mhz < 30.0) return 'HF';
  if (mhz >= 88.0 && mhz <= 108.0) return 'FM broadcast';
  if (mhz > 108.0 && mhz <= 137.0) return 'Airband';
  if (mhz >= 144.0 && mhz <= 148.0) return '2 m amateur';
  if (mhz >= 156.0 && mhz <= 162.0) return 'Marine VHF';
  if (mhz >= 400.0 && mhz <= 470.0) return 'UHF / 70 cm';
  if (mhz >= 902.0 && mhz <= 928.0) return 'ISM 915';
  if (mhz >= 1088.0 && mhz <= 1092.0) return 'ADS-B';
  return null;
}

class SpectrumScreen extends StatelessWidget {
  const SpectrumScreen({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final hasSdr = state.hasSdrDriver;
        final now = DateTime.now();
        final steps = state.sweepSteps;
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _header(),
            const SizedBox(height: 12),
            if (!hasSdr) ...[
              _setupHint(),
            ] else ...[
              _statusCard(steps, now),
              const SizedBox(height: 12),
              _peaksCard(steps),
              const SizedBox(height: 12),
              _spectrumCard(steps),
            ],
            const SizedBox(height: 12),
            const _ScopeNote(),
          ],
        );
      },
    );
  }

  Widget _header() {
    return const OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Wrap, not Row: title + chip must flow onto two lines on
          // a narrow phone instead of overflowing (same lesson as
          // the Fetch header fix).
          Wrap(
            spacing: 10,
            runSpacing: 6,
            children: [
              Text('SPECTRUM', style: TextStyle(
                fontFamily: OutrideType.mono,
                fontSize: 16,
                fontWeight: FontWeight.w700,
                letterSpacing: 3,
                color: OutrideColors.onDark,
              )),
              OutrideChip(
                  label: 'EXPERIMENTAL', color: OutrideColors.purple),
            ],
          ),
          SizedBox(height: 6),
          Text(
            'Wideband survey — energy across the band from the SDR '
            'bridge. One pass of the RTL-SDR V3 covers 24–1766 MHz.',
            style: TextStyle(
              fontFamily: OutrideType.mono,
              fontSize: 12,
              color: OutrideColors.muted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _setupHint() {
    return const OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('NO SDR DRIVER', style: TextStyle(
            fontFamily: OutrideType.mono,
            fontSize: 13,
            fontWeight: FontWeight.w700,
            letterSpacing: 2,
            color: OutrideColors.amber,
          )),
          SizedBox(height: 8),
          Text(
            'No survey is running. Add the driver, then start the '
            'bridge:\n\n'
            '1. Settings → Radios → add SDR, then press Start — the '
            'driver only listens while polling is running.\n'
            '2. On the bench PC (same PC the dongle is plugged into):\n'
            '   RUN_SDR_BRIDGE.bat --backend rtlsdr --wideband\n'
            '   (Zadig WinUSB driver + pip install pyrtlsdr, once.)\n'
            '3. A focus sweep revisits faster:\n'
            '   --wideband --wideband-focus 88-108,902-928,1090',
            style: TextStyle(
              fontFamily: OutrideType.mono,
              fontSize: 12,
              color: OutrideColors.onDark,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusCard(List<SweepStep> steps, DateTime now) {
    final drivers = state.sdrDrivers;
    var ingested = 0;
    var malformed = 0;
    for (final d in drivers) {
      ingested += d.sweepIngestedCount;
      malformed += d.sweepMalformedCount;
    }
    final last = steps.isEmpty
        ? null
        : steps
            .map((s) => s.receivedAt)
            .reduce((a, b) => a.isAfter(b) ? a : b);
    final range = steps.isEmpty
        ? '—'
        : '${fmtFreq(steps.first.centerMhz)} – '
            '${fmtFreq(steps.last.centerMhz)}';
    return OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('SURVEY — UDP 49161', style: OutrideType.section(11)),
          const SizedBox(height: 8),
          _kv('Steps in current pass', '${steps.length}'),
          _kv('Range covered', range),
          _kv('Steps ingested', '$ingested'),
          _kv('Malformed skipped', '$malformed'),
          _kv('Last step',
              last == null
                  ? '— none yet'
                  : '${_clock(last)} (${_age(last, now)})'),
        ],
      ),
    );
  }

  Widget _peaksCard(List<SweepStep> steps) {
    // Flatten (step, peak) pairs so each peak keeps its step's
    // noise floor for the "above floor" reading.
    final pairs = <({SweepStep step, SweepPeak peak})>[];
    for (final s in steps) {
      for (final p in s.peaks) {
        pairs.add((step: s, peak: p));
      }
    }
    pairs.sort((a, b) => b.peak.dbfs.compareTo(a.peak.dbfs));
    // Dedupe by frequency (review S5): with --wideband-step below
    // the span, neighbouring steps overlap, so one physical tone
    // appears in several steps as identical rows. Keep the strongest
    // per 10 kHz bucket — finer than a bin width (~60 kHz), so
    // distinct tones never collapse into one.
    final seen = <int>{};
    final top = <({SweepStep step, SweepPeak peak})>[];
    for (final pair in pairs) {
      if (seen.add((pair.peak.freqMhz * 100).round())) {
        top.add(pair);
      }
      if (top.length >= 20) break;
    }
    return OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('DETECTED PEAKS — STRONGEST FIRST',
                    style: OutrideType.section(11)),
              ),
              Text('${top.length} shown',
                  style: OutrideType.section(10)),
            ],
          ),
          const SizedBox(height: 8),
          if (top.isEmpty)
            const Text(
              'No peaks above the adaptive noise floor yet. A full '
              'pass takes ~1–2 minutes — wait for the sweep to cover '
              'the band, or run a focus sweep.',
              style: TextStyle(
                fontFamily: OutrideType.mono,
                fontSize: 12,
                color: OutrideColors.muted,
              ),
            )
          else
            for (final pair in top) _peakRow(pair.step, pair.peak),
          const SizedBox(height: 6),
          const Text(
            'A peak is energy at a frequency — never an '
            'identification. The band label names the allocation, '
            'not what is transmitting.',
            style: TextStyle(
              fontFamily: OutrideType.mono,
              fontSize: 11,
              color: OutrideColors.muted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _peakRow(SweepStep step, SweepPeak peak) {
    final band = allocationHint(peak.freqMhz);
    // Two lines (same pattern as the Fetch event rows): a single
    // Row with freq + band + two numbers overflowed by 45 px at
    // 360 px phone width, and shrinking the freq box alone only
    // bought 16 px — the numbers themselves are too wide to share
    // one line with the band label on a narrow phone.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 88,
                child: Text(fmtFreq(peak.freqMhz),
                    style: OutrideType.rowValue(OutrideColors.onDark)),
              ),
              Expanded(
                child: Text(
                  band ?? '—',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: OutrideType.mono,
                    fontSize: 11,
                    color: OutrideColors.muted,
                  ),
                ),
              ),
              Text(
                '${peak.dbfs.toStringAsFixed(1)} dBFS',
                style: OutrideType.rowValue(OutrideColors.amber),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.only(left: 88),
            child: Text(
              '+${peak.aboveFloor(step.noiseDbfs).toStringAsFixed(1)} dB above floor',
              style: const TextStyle(
                fontFamily: OutrideType.mono,
                fontSize: 10,
                color: OutrideColors.muted,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _spectrumCard(List<SweepStep> steps) {
    final shown = spectrumDisplaySteps(steps);
    return OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('ENERGY BY FREQUENCY — CURRENT PASS',
                    style: OutrideType.section(11)),
              ),
              Text('${shown.length} rows',
                  style: OutrideType.section(10)),
            ],
          ),
          const SizedBox(height: 8),
          if (shown.isEmpty)
            const Text(
              'Listening on UDP 49161 — no sweep steps yet. Start '
              'the bridge with --wideband and press Start on the '
              'SDR driver.',
              style: TextStyle(
                fontFamily: OutrideType.mono,
                fontSize: 12,
                color: OutrideColors.muted,
              ),
            )
          else ...[
            for (final s in shown) _stepRow(s),
            const SizedBox(height: 6),
            const Text(
              'Bars show median energy per step (dBFS, receiver-'
              'relative — not dBm). Full passes are downsampled to '
              '60 rows, hottest step per bucket, so a hot narrow '
              'step is never averaged away.',
              style: TextStyle(
                fontFamily: OutrideType.mono,
                fontSize: 11,
                color: OutrideColors.muted,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _stepRow(SweepStep s) {
    final frac = sweepBarFraction(s.energyDbfs);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Text(fmtFreq(s.centerMhz), style: OutrideType.rowLabel()),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final w = constraints.maxWidth;
                return Container(
                  height: 10,
                  decoration: BoxDecoration(
                    color: OutrideColors.surface2,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: OutrideColors.border),
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      width: w * frac,
                      height: 10,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(5),
                        color: (s.peaks.isNotEmpty
                                ? OutrideColors.amber
                                : OutrideColors.purple)
                            .withValues(alpha: 0.85),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 64,
            child: Text(
              s.energyDbfs.toStringAsFixed(1),
              textAlign: TextAlign.right,
              style: OutrideType.rowValue(
                  s.peaks.isNotEmpty ? OutrideColors.amber : OutrideColors.onDark),
            ),
          ),
          if (s.peaks.isNotEmpty) ...[
            const SizedBox(width: 6),
            OutrideChip(
                label: '${s.peaks.length} PEAK${s.peaks.length == 1 ? '' : 'S'}',
                color: OutrideColors.amber),
          ],
        ],
      ),
    );
  }

  Widget _kv(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: Text(label, style: OutrideType.rowLabel()),
          ),
          Expanded(
            child: Text(value, style: OutrideType.rowValue(OutrideColors.onDark)),
          ),
        ],
      ),
    );
  }
}

class _ScopeNote extends StatelessWidget {
  const _ScopeNote();

  @override
  Widget build(BuildContext context) {
    return const Text(
      'SCOPE: receive-only ears, 24 MHz–1.75 GHz on the RTL-SDR V3 — '
      'no 2.4 / 5.8 GHz, no direction-finding from a single antenna. '
      'A peak is energy at a frequency, never an identification of '
      'what is transmitting, and a survey is display only: it never '
      'drives the tripwire, the tracker, or the merger. A full pass '
      'takes ~1–2 minutes, so a fast hopper can slip between visits.',
      style: TextStyle(
        fontFamily: OutrideType.mono,
        fontSize: 11,
        color: OutrideColors.muted,
        height: 1.6,
      ),
    );
  }
}
