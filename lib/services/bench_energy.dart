/// B20 energy-crossover bench — compute-vs-communicate energy on
/// Shepherd's own ESP32-S3 node/uplink.
///
/// Source: Siam & Azzedin, Research Square preprint rs-11579488/v1
/// (lane 5+6 sweep, 2026-11-25). The bench replicates the paper's
/// ENERGY-MEASUREMENT PROTOCOL on Shepherd's own hardware and
/// derives Shepherd's own compute-vs-communicate crossover for
/// on-node adaptation. It does NOT import the paper's claimed
/// energy figures: those are setup-specific (their exchange size,
/// their link budget, their synthetic embeddings) and must never
/// appear as Shepherd numbers, expected results, constants,
/// defaults, test expectations, or comments anywhere in this bench.
/// The bench measures Shepherd's own numbers or reports
/// measurement pending — nothing else.
///
/// Protocol (from the sweep summary, implemented here):
/// - INA238 power monitor at 1 kHz on the 5 V rail.
/// - GPIO phase markers delimit the phases below.
/// - 60 ms settling pause after every phase switch: samples in
///   the first 60 ms of a phase segment are EXCLUDED from the
///   energy integration (the rail is still settling).
///
/// ENERGY SESSION SCHEMA (externally produced CSVs, same
/// file-copy pattern as the CSI sessions in `csi_sessions/` — no
/// in-app recorder exists for this input):
///
///   File: `energy_sessions/<session>.csv`, one row per 1 kHz
///   power sample:
///     t_iso,phase,current_ma,voltage_v
///   - t_iso: ISO-8601 UTC timestamp of the sample. Nominal 1 ms
///     spacing (1 kHz); the median inter-sample interval must fall
///     within 0.5–2.0 ms or the file is rejected.
///   - phase: GPIO-marker phase — one of `compute` (head-only SGD
///     epoch running), `communicate` (Wi-Fi/HTTP exchange in
///     flight), `idle`, `wake` (deep-sleep wake transient). Only
///     `compute` and `communicate` are scored for the crossover;
///     `idle`/`wake` are recorded and reported, never scored.
///   - current_ma: INA238 current in mA. Must be finite and >= 0.
///   - voltage_v: measured rail voltage in V. Must be finite and
///     > 0 (recorded per sample, never assumed).
///
///   Sidecar: `energy_sessions/<session>.meta.json` (REQUIRED —
///   a session without it is rejected with the reason stated):
///     {"node": "esp32-s3 ...", "uplink": "wifi",
///      "rail_v": 5, "sample_rate_hz": 1000,
///      "settling_pause_ms": 60, "source": "..."}
///   `node`/`uplink`/`source` are provenance-only (optional); only `rail_v`, `sample_rate_hz`, and `settling_pause_ms` are validated.
///   `sample_rate_hz` must be 1000 and `settling_pause_ms` must
///   be 60: this harness implements exactly the stated protocol,
///   and a capture run under different settings is a different
///   protocol, not a session for this bench.
///
/// Scoring: consecutive same-phase rows form a segment. The first
/// 60 ms of each segment is dropped (settling). Segment energy =
/// sum over retained samples of V × I × dt (mJ), dt from the
/// sample timestamps. A segment counts as measured only when it
/// retains at least [kEnergyMinSettledSamples] settled samples.
/// - Compute arm: mean energy per `compute` segment = energy per
///   head-only SGD epoch.
/// - Communicate arm: mean energy per `communicate` segment =
///   energy per Wi-Fi/HTTP exchange turn.
/// - Crossover = mean exchange energy per turn / mean compute
///   energy per epoch, in epochs: one exchange costs as much
///   energy as that many head-only epochs.
///
/// Pass bar: Shepherd's own crossover measured (head-only SGD
/// energy/epoch vs Wi-Fi/HTTP exchange energy/turn). The bar is
/// "measured", not a threshold on the value — any finite crossover
/// derived from recorded data passes; the value itself is
/// Shepherd's measurement, never compared against the paper's
/// claimed figures.
library;

import 'dart:io';

import 'bench_run.dart' show skippedOutcome;
import 'fusion_bench_harness.dart';

/// Where recorded energy sessions live (app documents dir).
const String defaultEnergySessionsDirName = 'energy_sessions';

/// Protocol sample rate (INA238 @ 1 kHz). The sidecar must declare
/// exactly this rate.
const int kEnergySampleRateHz = 1000;

/// Settling pause after every phase switch, in ms. Samples in the
/// first [kEnergySettlingMs] of a phase segment are excluded from
/// the energy integration.
const int kEnergySettlingMs = 60;

/// A phase segment counts as measured only when it retains at
/// least this many settled samples (10 ms at 1 kHz).
const int kEnergyMinSettledSamples = 10;

/// Median inter-sample interval bounds (ms) enforcing the 1 kHz
/// protocol, tolerant of logger jitter.
const double kEnergyMedianDtMinMs = 0.5;
const double kEnergyMedianDtMaxMs = 2.0;

/// Phases the GPIO markers delimit. Only `compute` and
/// `communicate` are scored for the crossover.
const Set<String> kEnergyPhases = {
  'compute',
  'communicate',
  'idle',
  'wake',
};

/// One 1 kHz power sample.
class EnergySample {
  const EnergySample({
    required this.t,
    required this.phase,
    required this.currentMa,
    required this.voltageV,
  });

  final DateTime t;
  final String phase;
  final double currentMa;
  final double voltageV;

  /// Instantaneous power in mW (V × mA).
  double get powerMw => voltageV * currentMa;
}

/// One recorded energy session: samples in time order.
class EnergySession {
  EnergySession({required this.name, required List<EnergySample> samples})
      : _samples = samples;

  final String name;
  final List<EnergySample> _samples;

  List<EnergySample> get samples => List.unmodifiable(_samples);

  /// Node identifier from the meta sidecar.
  String? node;

  /// Uplink identifier from the meta sidecar (e.g. `wifi`).
  String? uplink;
}

/// One phase segment: consecutive samples sharing a phase.
class EnergySegment {
  const EnergySegment({required this.phase, required this.samples});

  final String phase;
  final List<EnergySample> samples;

  /// Samples after the settling exclusion (first
  /// [kEnergySettlingMs] of the segment dropped).
  List<EnergySample> get settled {
    if (samples.isEmpty) return const [];
    final start = samples.first.t;
    return samples
        .where((s) =>
            s.t.difference(start).inMicroseconds >=
            kEnergySettlingMs * 1000)
        .toList();
  }

  /// True when the segment retains enough settled samples to
  /// count as a measurement.
  bool get isMeasured => settled.length >= kEnergyMinSettledSamples;

  /// Energy of the settled samples in mJ (V × I × dt, dt from the
  /// sample timestamps; the last sample carries the segment's
  /// median interval).
  double get energyMj {
    final kept = settled;
    if (kept.length < 2) return 0.0;
    final dts = <double>[];
    for (var i = 0; i < kept.length - 1; i++) {
      dts.add(kept[i + 1].t.difference(kept[i].t).inMicroseconds / 1e6);
    }
    final sorted = [...dts]..sort();
    final medianDt = sorted[sorted.length ~/ 2];
    var energy = 0.0;
    for (var i = 0; i < kept.length - 1; i++) {
      energy += kept[i].powerMw * dts[i];
    }
    energy += kept.last.powerMw * medianDt;
    return energy;
  }
}

/// Split a session's samples into consecutive same-phase segments.
List<EnergySegment> energySegments(EnergySession session) {
  final out = <EnergySegment>[];
  var currentPhase = '';
  var current = <EnergySample>[];
  void flush() {
    if (current.isNotEmpty) {
      out.add(EnergySegment(phase: currentPhase, samples: current));
      current = <EnergySample>[];
    }
  }

  for (final s in session.samples) {
    if (s.phase != currentPhase) {
      flush();
      currentPhase = s.phase;
    }
    current.add(s);
  }
  flush();
  return out;
}

/// Mean energy per measured segment of [phase] across [sessions],
/// with the segment count. (0.0, 0) when no segment measured.
({double meanMj, int segments}) energyPerSegment(
  List<EnergySession> sessions,
  String phase,
) {
  var total = 0.0;
  var count = 0;
  for (final session in sessions) {
    for (final seg in energySegments(session)) {
      if (seg.phase == phase && seg.isMeasured) {
        total += seg.energyMj;
        count++;
      }
    }
  }
  return (meanMj: count == 0 ? 0.0 : total / count, segments: count);
}

/// True when [session] can score the crossover: at least one
/// measured compute segment and one measured communicate segment.
bool energySessionIsScorable(EnergySession session) {
  var compute = false;
  var communicate = false;
  for (final seg in energySegments(session)) {
    if (!seg.isMeasured) continue;
    if (seg.phase == 'compute') compute = true;
    if (seg.phase == 'communicate') communicate = true;
  }
  return compute && communicate;
}

/// Parse one energy session CSV. Throws [FormatException] with the
/// reason when the file is not an energy session.
EnergySession parseEnergyCsv(String name, String content) {
  final lines = content
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && !l.startsWith('#'))
      .toList();
  if (lines.isEmpty) throw const FormatException('empty file');
  final header = _splitCsv(lines.first);
  final idx = <String, int>{
    for (var i = 0; i < header.length; i++) header[i].trim(): i,
  };
  for (final col in ['t_iso', 'phase', 'current_ma', 'voltage_v']) {
    if (!idx.containsKey(col)) {
      throw FormatException('missing required column $col');
    }
  }
  final samples = <EnergySample>[];
  for (var li = 1; li < lines.length; li++) {
    final f = _splitCsv(lines[li]);
    if (f.length < header.length) {
      throw FormatException(
          'short row ${li + 1}: ${f.length} fields, '
          'expected ${header.length}');
    }
    final t = DateTime.tryParse(f[idx['t_iso']!].trim());
    final phase = f[idx['phase']!].trim();
    final current = double.tryParse(f[idx['current_ma']!].trim());
    final voltage = double.tryParse(f[idx['voltage_v']!].trim());
    if (t == null || current == null || voltage == null) {
      throw FormatException('unparseable row ${li + 1}');
    }
    if (!kEnergyPhases.contains(phase)) {
      throw FormatException(
          'row ${li + 1}: unknown phase "$phase" — expected one of '
          '${kEnergyPhases.join(', ')}');
    }
    if (!current.isFinite || current < 0) {
      throw FormatException(
          'row ${li + 1}: current_ma must be finite and >= 0');
    }
    if (!voltage.isFinite || voltage <= 0) {
      throw FormatException(
          'row ${li + 1}: voltage_v must be finite and > 0');
    }
    if (samples.isNotEmpty && !t.isAfter(samples.last.t)) {
      throw FormatException(
          'row ${li + 1}: timestamps must be strictly increasing');
    }
    samples.add(EnergySample(
      t: t,
      phase: phase,
      currentMa: current,
      voltageV: voltage,
    ));
  }
  if (samples.isEmpty) throw const FormatException('no data rows');
  if (samples.length < 2) {
    throw const FormatException('too few samples — need at least 2');
  }
  final dts = <double>[];
  for (var i = 0; i < samples.length - 1; i++) {
    dts.add(samples[i + 1].t.difference(samples[i].t).inMicroseconds /
        1e6);
  }
  final sorted = [...dts]..sort();
  final medianDtMs = sorted[sorted.length ~/ 2] * 1000;
  if (medianDtMs < kEnergyMedianDtMinMs ||
      medianDtMs > kEnergyMedianDtMaxMs) {
    throw FormatException(
        'median sample interval ${medianDtMs.toStringAsFixed(2)} ms '
        'outside the 1 kHz protocol (0.50–2.00 ms)');
  }
  return EnergySession(name: name, samples: samples);
}

List<String> _splitCsv(String line) {
  final out = <String>[];
  final buf = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (ch == '"') {
      inQuotes = !inQuotes;
    } else if (ch == ',' && !inQuotes) {
      out.add(buf.toString());
      buf.clear();
    } else {
      buf.write(ch);
    }
  }
  out.add(buf.toString());
  return out;
}

/// Result of scanning an energy sessions directory.
class EnergySessionLoad {
  const EnergySessionLoad({required this.sessions, required this.rejected});

  final List<EnergySession> sessions;

  /// File name -> rejection reason.
  final Map<String, String> rejected;
}

/// Minimal JSON-object parse for the meta sidecar (no new deps).
/// Only string/number top-level values are read.
Map<String, Object?> _parseEnergyMeta(String content) {
  final out = <String, Object?>{};

  String? str(String key) {
    final m = RegExp('"$key"\\s*:\\s*"([^"]+)"').firstMatch(content);
    return m?.group(1);
  }

  double? num(String key) {
    final m = RegExp('"$key"\\s*:\\s*([0-9.]+)').firstMatch(content);
    return m == null ? null : double.tryParse(m.group(1)!);
  }

  final node = str('node');
  if (node != null) out['node'] = node;
  final uplink = str('uplink');
  if (uplink != null) out['uplink'] = uplink;
  final rail = num('rail_v');
  if (rail != null) out['rail_v'] = rail;
  final rate = num('sample_rate_hz');
  if (rate != null) out['sample_rate_hz'] = rate;
  final settling = num('settling_pause_ms');
  if (settling != null) out['settling_pause_ms'] = settling;
  return out;
}

/// Load every *.csv energy session under [dir]. A missing directory
/// is not an error — it is the normal "no recorded data" state.
/// The `<session>.meta.json` sidecar is REQUIRED: a session without
/// it is rejected with the reason stated (unlike the CSI loader,
/// where a missing sidecar leaves the session unscored — the
/// energy protocol is defined by the sidecar's declared rate and
/// settling pause, so a session that does not declare them is not
/// a session for this bench).
EnergySessionLoad loadEnergySessions(Directory dir) {
  if (!dir.existsSync()) {
    return const EnergySessionLoad(sessions: [], rejected: {});
  }
  final sessions = <EnergySession>[];
  final rejected = <String, String>{};
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.csv'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
    final name = f.uri.pathSegments.last;
    try {
      final session = parseEnergyCsv(name, f.readAsStringSync());
      final metaFile =
          File('${f.path.substring(0, f.path.length - 4)}.meta.json');
      if (!metaFile.existsSync()) {
        rejected[name] = 'missing $name sidecar: '
            '<session>.meta.json (node, uplink, rail_v, '
            'sample_rate_hz, settling_pause_ms) is required';
        continue;
      }
      final meta = _parseEnergyMeta(metaFile.readAsStringSync());
      final rate = meta['sample_rate_hz'];
      if (rate is! num || rate.toDouble() != kEnergySampleRateHz) {
        rejected[name] = 'sample_rate_hz must be '
            '$kEnergySampleRateHz (INA238 @ 1 kHz protocol)';
        continue;
      }
      final settling = meta['settling_pause_ms'];
      if (settling is! num ||
          settling.toDouble() != kEnergySettlingMs) {
        rejected[name] = 'settling_pause_ms must be $kEnergySettlingMs '
            '(protocol settling pause)';
        continue;
      }
      final rail = meta['rail_v'];
      if (rail is! num || rail.toDouble() <= 0) {
        rejected[name] = 'rail_v must be present and > 0';
        continue;
      }
      session.node = meta['node'] as String?;
      session.uplink = meta['uplink'] as String?;
      sessions.add(session);
    } on FormatException catch (e) {
      rejected[name] = e.message;
    } on FileSystemException catch (e) {
      rejected[name] = e.message;
    }
  }
  return EnergySessionLoad(sessions: sessions, rejected: rejected);
}

/// Run the B20 bench over the energy sessions under [sessionsDir].
///
/// Measurement ONLY: with no valid sessions this returns a SKIPPED
/// outcome with the exact pending string and measures nothing.
BenchOutcome runEnergyBench(Directory sessionsDir) {
  final load = loadEnergySessions(sessionsDir);
  if (load.sessions.isEmpty) return skippedOutcome(load.rejected);

  final compute = energyPerSegment(load.sessions, 'compute');
  final communicate = energyPerSegment(load.sessions, 'communicate');
  final crossover = compute.meanMj > 0
      ? communicate.meanMj / compute.meanMj
      : double.nan;
  final bothMeasured = compute.segments > 0 && communicate.segments > 0;

  return BenchOutcome(
    skipped: false,
    sessionsRun: [for (final s in load.sessions) s.name],
    rejected: load.rejected,
    verdicts: [
      BenchVerdict(
        bar: 'B20: head-only compute energy measured (≥1 settled '
            'compute segment)',
        passed: compute.segments > 0,
        detail: compute.segments == 0
            ? 'no settled compute segment in '
                '${load.sessions.length} session(s) — no SGD epoch '
                'energy measured'
            : 'mean ${compute.meanMj.toStringAsFixed(3)} mJ/epoch over '
                '${compute.segments} compute segment(s)',
      ),
      BenchVerdict(
        bar: 'B20: Wi-Fi/HTTP exchange energy measured (≥1 settled '
            'communicate segment)',
        passed: communicate.segments > 0,
        detail: communicate.segments == 0
            ? 'no settled communicate segment in '
                '${load.sessions.length} session(s) — no exchange '
                'energy measured'
            : 'mean ${communicate.meanMj.toStringAsFixed(3)} mJ/turn '
                'over ${communicate.segments} communicate segment(s)',
      ),
      BenchVerdict(
        bar: 'B20: Shepherd crossover measured (exchange energy per '
            'turn ÷ compute energy per epoch, in epochs)',
        notApplicable: !bothMeasured,
        passed: bothMeasured && crossover.isFinite && crossover > 0,
        detail: !bothMeasured
            ? 'N/A — crossover needs both arms measured '
                '(compute: ${compute.segments} segment(s), '
                'communicate: ${communicate.segments} segment(s))'
            : 'crossover ${crossover.toStringAsFixed(3)} epochs — one '
                'exchange ≈ ${crossover.toStringAsFixed(3)} epochs of '
                'head-only compute (${communicate.meanMj.toStringAsFixed(3)} '
                'mJ/turn ÷ ${compute.meanMj.toStringAsFixed(3)} mJ/epoch)',
      ),
    ],
  );
}
