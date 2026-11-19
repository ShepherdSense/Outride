/// Wideband survey steps from the SDR bridge (`--wideband` mode).
///
/// The bridge steps the radio across a range (default 24–1766 MHz in
/// 2 MHz steps on the RTL-SDR V3) and ships one `sweep_step` packet
/// per step over UDP 49161 — the same transport as the band-energy
/// packets, a new packet kind:
///
///   {"v":1,"kind":"sweep_step","radio":"rtlsdr0","sweep_id":3,
///    "step_index":412,"step_count":872,"center_mhz":915.0,
///    "span_mhz":1.92,"energy_dbfs":-62.4,"noise_dbfs":-81.0,
///    "bins_dbfs":[-80.1,... 32 values, LOW to HIGH ...],
///    "peaks":[{"freq_mhz":915.14,"dbfs":-48.3}],"t":1729123456.789}
///
/// Display-only, by construction: sweep steps are stored in the
/// SdrDriver's sweep store and rendered on the Spectrum tab. They
/// never become LinkSamples, so a survey can never drive the
/// tripwire, the tracker, or the merger.
///
/// HONEST SCOPE: a peak is ENERGY, never an identification — it says
/// "something is transmitting here", never what it is. One radio
/// reports energy, not direction. A full V3 pass takes ~1–2 minutes,
/// so a fast hopper can slip between visits.
///
/// Parsing is LENIENT BY DESIGN (same contract as SensorProtocol and
/// FetchEvent): malformed input is skipped, never thrown. Unknown
/// fields are ignored; a future bridge revision must not break
/// today's app. Out-of-range values drop the FIELD (bins/peaks) or
/// the step, never crash ingest.
library;

import 'dart:convert';

/// One detected peak inside a sweep step: a local maximum above the
/// step's adaptive noise floor + margin. Energy only — never an
/// identification, never a direction.
class SweepPeak {
  const SweepPeak({required this.freqMhz, required this.dbfs});

  /// Absolute frequency of the peak, MHz.
  final double freqMhz;

  /// Peak level, dBFS (negative; closer to 0 = hotter).
  final double dbfs;

  /// dB above a noise floor. Null-safe helper for the view.
  double aboveFloor(double noiseDbfs) => dbfs - noiseDbfs;
}

/// One wideband survey step: the bridge's measurement at one tuned
/// center frequency.
class SweepStep {
  const SweepStep({
    required this.receivedAt,
    required this.radio,
    required this.sweepId,
    required this.stepIndex,
    required this.stepCount,
    required this.centerMhz,
    required this.spanMhz,
    required this.energyDbfs,
    required this.noiseDbfs,
    required this.binsDbfs,
    required this.peaks,
  });

  /// When Outride received it (the bridge's `t` is wall-clock send
  /// time; receive time is what staleness is judged on, like Fetch).
  final DateTime receivedAt;

  /// Bridge radio name, e.g. 'rtlsdr0'.
  final String radio;

  /// Pass number: increments each full sweep, so the app can group
  /// steps into passes.
  final int sweepId;

  /// This step's position in its pass (0-based).
  final int stepIndex;

  /// Steps in the pass (the plan size).
  final int stepCount;

  /// Tuned center frequency, MHz.
  final double centerMhz;

  /// Width actually measured, MHz (central 80% of the sample rate).
  final double spanMhz;

  /// Median PSD across the step's span, dBFS (negative).
  final double energyDbfs;

  /// Adaptive noise floor (20th-percentile PSD), dBFS.
  final double noiseDbfs;

  /// Max-pooled bins across the span, LOW to HIGH frequency.
  /// Max-pooled (never mean-pooled) so a narrow tone is never
  /// washed out of its bin.
  final List<double> binsDbfs;

  /// Local maxima above noise + margin, strongest first.
  final List<SweepPeak> peaks;

  /// Absolute frequency (MHz) of bin [i]: bins span the measured
  /// width evenly, LOW to HIGH.
  double binFreqMhz(int i) {
    if (binsDbfs.isEmpty) return centerMhz;
    final n = binsDbfs.length;
    final lo = centerMhz - spanMhz / 2;
    return lo + (i + 0.5) * spanMhz / n;
  }

  /// dB the step's median energy sits above its own noise floor.
  double get energyAboveFloor => energyDbfs - noiseDbfs;

  /// Max bins shipped per step by the bridge (defensive cap on ingest).
  static const int maxBins = 256;

  /// Max peaks shipped per step by the bridge (defensive cap on ingest).
  static const int maxPeaks = 64;

  /// Parse one decoded-JSON map. Returns null when it is not a
  /// sweep_step packet or when a required field is missing or
  /// non-finite. Out-of-span peaks are dropped (the bridge
  /// guarantees in-span peaks; a lying bridge must not draw a peak
  /// outside the measured span). Never throws. Unknown fields are
  /// ignored.
  static SweepStep? tryParseJson(Map<String, dynamic> j,
      {DateTime? receivedAt}) {
    try {
      return _parse(j, receivedAt ?? DateTime.now());
    } catch (_) {
      return null;
    }
  }

  /// Parse one JSON text line (UDP datagram body). Returns null when
  /// it is not a sweep_step packet. Never throws.
  static SweepStep? tryParseLine(String line, {DateTime? receivedAt}) {
    final t = line.trim();
    if (!t.startsWith('{')) return null;
    try {
      final j = jsonDecode(t);
      if (j is! Map<String, dynamic>) return null;
      return tryParseJson(j, receivedAt: receivedAt);
    } catch (_) {
      return null;
    }
  }

  static SweepStep? _parse(Map<String, dynamic> j, DateTime now) {
    if (j['v'] != 1 || j['kind'] != 'sweep_step') return null;

    double? fin(dynamic v) => v is num && v.isFinite ? v.toDouble() : null;

    final center = fin(j['center_mhz']);
    final span = fin(j['span_mhz']);
    final energy = fin(j['energy_dbfs']);
    final noise = fin(j['noise_dbfs']);
    if (center == null || span == null || energy == null || noise == null) {
      return null;
    }
    // Frequencies the bridge can actually tune (0.1 MHz–6 GHz);
    // a span must be positive and no wider than the center allows.
    if (center < 0.1 || center > 6000.0 || span <= 0 || span > 100.0) {
      return null;
    }
    // dBFS lives in [-200, 0] for any real capture; anything else is
    // corrupt data, not a hot band.
    bool saneDb(double v) => v >= -200.0 && v <= 0.0;
    if (!saneDb(energy) || !saneDb(noise)) return null;

    final binsRaw = j['bins_dbfs'];
    if (binsRaw is! List) return null;
    final bins = <double>[];
    for (final e in binsRaw) {
      if (bins.length >= maxBins) break;
      final v = fin(e);
      if (v != null && saneDb(v)) bins.add(v);
    }
    if (bins.isEmpty) return null;

    final peaksRaw = j['peaks'];
    final peaks = <SweepPeak>[];
    if (peaksRaw is List) {
      final lo = center - span / 2;
      final hi = center + span / 2;
      for (final e in peaksRaw) {
        if (peaks.length >= maxPeaks) break;
        if (e is! Map<String, dynamic>) continue;
        final f = fin(e['freq_mhz']);
        final d = fin(e['dbfs']);
        if (f == null || d == null || !saneDb(d)) continue;
        // A peak outside the measured span is not a peak in this
        // step — drop it, keep the step.
        if (f < lo - 0.001 || f > hi + 0.001) continue;
        peaks.add(SweepPeak(freqMhz: f, dbfs: d));
      }
      peaks.sort((a, b) => b.dbfs.compareTo(a.dbfs));
    }

    final sweepId = j['sweep_id'];
    final stepIndex = j['step_index'];
    final stepCount = j['step_count'];
    return SweepStep(
      receivedAt: now,
      radio: '${j['radio']}',
      sweepId: sweepId is num && sweepId.isFinite
          ? sweepId.toInt().clamp(0, 1000000000)
          : 0,
      stepIndex: stepIndex is num && stepIndex.isFinite
          ? stepIndex.toInt().clamp(0, 100000)
          : 0,
      stepCount: stepCount is num && stepCount.isFinite
          ? stepCount.toInt().clamp(1, 100000)
          : 1,
      centerMhz: center,
      spanMhz: span,
      energyDbfs: energy,
      noiseDbfs: noise,
      binsDbfs: bins,
      peaks: peaks,
    );
  }
}
