/// CSI session loader + shared CSI amplitude/phase-window feature
/// helpers (B7, B12, B-W1–B-W4).
///
/// EXPERIMENTAL — bench-only library, never wired into the live
/// tracker or the app UI. Benches read files and compute; they do
/// not sense, do not alert, do not join fleets.
///
/// CSI SESSION SCHEMA (the one new format this build authorizes —
/// a plain CSV in the exact pattern of the existing BenchSession
/// format, producible by hardware Draco already has: two ESP32 dev
/// boards + a logging PC; see the design doc §2.5):
///
///   File: `csi_sessions/<session>.csv`, one row per (packet,
///   subcarrier):
///     t_iso,link_id,subcarrier,amp,phase
///   - t_iso: ISO-8601 UTC timestamp of the packet, e.g.
///     2026-11-23T10:00:00.000Z. All rows sharing one t_iso are
///     one packet.
///   - link_id: link identifier, e.g. `tx1>rx1`. One file holds
///     one link (extra link_ids are rejected, not silently mixed).
///   - subcarrier: integer subcarrier index as reported by the
///     ESP32 CSI API (e.g. -28..28 for 20 MHz, 52 used subcarriers;
///     or 0..63 for the raw buffer index — either is accepted, but
///     the file must be consistent: the subcarrier SET must not
///     change between packets).
///   - amp: linear amplitude, unitless, as reported by the ESP32
///     CSI API. Must be finite and >= 0.
///   - phase: radians, as reported (-pi..pi). Must be finite.
///
///   Sidecar: `csi_sessions/<session>.meta.json`:
///     {"geometry": {"tx": [x, y], "rx": [x, y],
///                    "separation_m": 3.0},
///      "room": "lab", "type": "present|absent|moving|still|fan-on",
///      "ambient_calibration_s": 60, "sample_rate_hz": 100,
///      "channel": 1, "bandwidth_mhz": 20,
///      "source": "esp32-s3 ..."}
///   `type` labels the session for scoring (present/absent/moving/
///   still/fan-on). `ambient_calibration_s` is the leading vacant
///   window the disturbance baseline is taken from. `channel` /
///   `bandwidth_mhz` record the Wi-Fi channel and bandwidth the
///   capture ran on (when known — optional; a capture that does not
///   report them omits them). The sidecar is
///   REQUIRED for a scored run: without it the loader accepts the
///   CSV but the bench reports the session unscored with the reason
///   `missing <session>.meta.json sidecar`.
///
///   GOLDEN-FILE TEST STAYS OPEN: parsing one REAL ESP32 CSI capture
///   is untested — no real capture exists in the workspace. Do not
///   fake one; the test is written when a real capture lands.
///
///   Malformed files are REJECTED with a reason (listed in
///   [CsiSessionLoad.rejected]), exactly like [parseSessionCsv].
///
/// WHAT THIS IS NOT (honest scope, design R5/R6):
/// - The app has NO in-app CSI recorder and NO raw-CSI ingest path.
///   The Sensor Protocol UDP 49160 `CSI` verb carries only a 1 s
///   aggregated Hz-deviation motion observation (CsiObservation:
///   devHz, pairsActive, link) — NOT per-subcarrier amp/phase.
///   CSI sessions therefore come ONLY as externally recorded CSVs
///   copied into `csi_sessions/`. The bench recorder's `csi_summary`
///   section holds those aggregates for context; it is NOT a CSI
///   session and never feeds these benches.
/// - Single-antenna S3 phase is swamped by CFO/SFO offsets (dual-WiFi
///   note). Phase-based arms (B7 SVM, B12 detrended phase, B-W3
///   phase variance) compute phase statistics anyway — that is the
///   bench's job, it may measure failure — and their rows carry the
///   caveat that phase-based arms are expected weak on S3 SISO.
/// - Fingerprinting stays REJECTED (per-site calibration walk
///   incompatible with dismounted ops) — detection scoring only.
library;

import 'dart:io';
import 'dart:math' as math;

/// The literal skip string, shared by every bench harness.
const String kBenchPending = 'measurement pending — no recorded data';

/// Where recorded CSI sessions live (app documents dir).
const String defaultCsiSessionsDirName = 'csi_sessions';

/// One CSI packet: one t_iso, all subcarriers.
class CsiPacket {
  const CsiPacket({
    required this.t,
    required this.linkId,
    required this.amp,
    required this.phase,
  });

  final DateTime t;
  final String linkId;

  /// Subcarrier index -> linear amplitude.
  final Map<int, double> amp;

  /// Subcarrier index -> phase, radians.
  final Map<int, double> phase;

  /// Subcarrier indexes present in this packet, sorted.
  List<int> get subcarriers {
    final s = amp.keys.toList()..sort();
    return s;
  }

  double get meanAmp {
    if (amp.isEmpty) return double.nan;
    return amp.values.fold(0.0, (a, b) => a + b) / amp.length;
  }
}

/// One recorded CSI session: packets in time order.
class CsiSession {
  CsiSession({required this.name, required List<CsiPacket> packets})
      : _packets = packets;

  final String name;
  final List<CsiPacket> _packets;

  List<CsiPacket> get packets => List.unmodifiable(_packets);

  /// Session type from the meta sidecar (`present`, `absent`,
  /// `moving`, `still`, `fan-on`), or null when no sidecar was read.
  String? type;

  /// Room label from the meta sidecar (held-out-room scoring).
  String? room;

  /// TX/RX separation in metres from the meta sidecar.
  double? separationM;

  /// Counted breathing reference (breaths/min) from the meta sidecar
  /// (B-W4 only; null when the session carries no reference).
  double? breathingBpmRef;

  /// Leading vacant-calibration seconds from the meta sidecar.
  double ambientCalibrationS = 0;

  /// Wi-Fi channel the capture ran on, from the meta sidecar
  /// (null when the capture does not report it).
  int? channel;

  /// Channel bandwidth in MHz, from the meta sidecar (null when
  /// the capture does not report it).
  double? bandwidthMhz;

  /// Packet timestamps, ascending.
  List<DateTime> get times {
    final out = [for (final p in _packets) p.t]..sort();
    return out;
  }

  /// Duration in seconds (last packet minus first), 0 when < 2.
  double get durationS {
    if (_packets.length < 2) return 0;
    return _packets.last.t.difference(_packets.first.t).inMicroseconds /
        1e6;
  }
}

/// Parse one CSI session CSV. Throws [FormatException] with the
/// reason when the file is not a CSI session.
CsiSession parseCsiCsv(String name, String content) {
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
  for (final col in ['t_iso', 'link_id', 'subcarrier', 'amp', 'phase']) {
    if (!idx.containsKey(col)) {
      throw FormatException('missing required column $col');
    }
  }
  final byPacket = <String, Map<int, (double, double)>>{};
  final packetLink = <String, String>{};
  final packetTime = <String, DateTime>{};
  String? linkId;
  Set<int>? subcarrierSet;
  for (var li = 1; li < lines.length; li++) {
    final f = _splitCsv(lines[li]);
    if (f.length < header.length) {
      throw FormatException(
          'short row ${li + 1}: ${f.length} fields, '
          'expected ${header.length}');
    }
    final t = DateTime.tryParse(f[idx['t_iso']!].trim());
    final sub = int.tryParse(f[idx['subcarrier']!].trim());
    final amp = double.tryParse(f[idx['amp']!].trim());
    final phase = double.tryParse(f[idx['phase']!].trim());
    final lid = f[idx['link_id']!].trim();
    if (t == null || sub == null || amp == null || phase == null) {
      throw FormatException('unparseable row ${li + 1}');
    }
    if (!amp.isFinite || amp < 0) {
      throw FormatException('row ${li + 1}: amp must be finite and >= 0');
    }
    if (!phase.isFinite) {
      throw FormatException('row ${li + 1}: phase must be finite');
    }
    if (lid.isEmpty) {
      throw FormatException('row ${li + 1}: empty link_id');
    }
    if (linkId == null) {
      linkId = lid;
    } else if (lid != linkId) {
      throw FormatException(
          'row ${li + 1}: mixed link_id ($lid vs $linkId) — '
          'one file holds one link');
    }
    final key = f[idx['t_iso']!].trim();
    (byPacket[key] ??= {})[sub] = (amp, phase);
    packetLink[key] = lid;
    packetTime[key] = t;
  }
  if (byPacket.isEmpty) throw const FormatException('no data rows');
  final packets = <CsiPacket>[];
  final keys = byPacket.keys.toList()
    ..sort((a, b) => packetTime[a]!.compareTo(packetTime[b]!));
  for (final k in keys) {
    final subs = byPacket[k]!.keys.toSet();
    if (subcarrierSet == null) {
      subcarrierSet = subs;
    } else if (subs.length != subcarrierSet.length ||
        !subs.containsAll(subcarrierSet)) {
      throw FormatException(
          'packet $k: subcarrier set changed mid-file — '
          'the subcarrier set must not change between packets');
    }
    packets.add(CsiPacket(
      t: packetTime[k]!,
      linkId: packetLink[k]!,
      amp: {for (final e in byPacket[k]!.entries) e.key: e.value.$1},
      phase: {for (final e in byPacket[k]!.entries) e.key: e.value.$2},
    ));
  }
  return CsiSession(name: name, packets: packets);
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

/// Result of scanning a CSI sessions directory.
class CsiSessionLoad {
  const CsiSessionLoad({required this.sessions, required this.rejected});

  final List<CsiSession> sessions;

  /// File name -> rejection reason.
  final Map<String, String> rejected;
}

/// Load every *.csv CSI session under [dir]. A missing directory is
/// not an error — it is the normal "no recorded data" state. The
/// `<session>.meta.json` sidecar is read when present (type +
/// ambient calibration); a missing sidecar does NOT reject the
/// session — the bench reports it unscored instead.
CsiSessionLoad loadCsiSessions(Directory dir) {
  if (!dir.existsSync()) {
    return const CsiSessionLoad(sessions: [], rejected: {});
  }
  final sessions = <CsiSession>[];
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
      final session = parseCsiCsv(name, f.readAsStringSync());
      final metaFile = File(
          '${f.path.substring(0, f.path.length - 4)}.meta.json');
      if (metaFile.existsSync()) {
        try {
          final meta = _parseMeta(metaFile.readAsStringSync());
          session.type = meta['type'] as String?;
          session.room = meta['room'] as String?;
          session.separationM = meta['separation_m'] as double?;
          session.breathingBpmRef = meta['breathing_bpm_ref'] as double?;
          session.channel = meta['channel'] as int?;
          session.bandwidthMhz = meta['bandwidth_mhz'] as double?;
          final calib = meta['ambient_calibration_s'];
          if (calib is num) session.ambientCalibrationS = calib.toDouble();
        } catch (_) {
          // A broken sidecar never rejects the session; the bench
          // reports it unscored with this reason.
          session.type = null;
        }
      }
      sessions.add(session);
    } on FormatException catch (e) {
      rejected[name] = e.message;
    } on FileSystemException catch (e) {
      rejected[name] = e.message;
    }
  }
  return CsiSessionLoad(sessions: sessions, rejected: rejected);
}

/// Minimal JSON-object parse for the meta sidecar (no new deps).
/// Only string/number top-level values are read.
Map<String, Object?> _parseMeta(String content) {
  final out = <String, Object?>{};
  String? str(String key) {
    final m = RegExp('"$key"\\s*:\\s*"([^"]+)"').firstMatch(content);
    return m?.group(1);
  }

  double? num(String key) {
    final m = RegExp('"$key"\\s*:\\s*([0-9.]+)').firstMatch(content);
    return m == null ? null : double.tryParse(m.group(1)!);
  }

  final type = str('type');
  if (type != null) out['type'] = type;
  final room = str('room');
  if (room != null) out['room'] = room;
  final calib = num('ambient_calibration_s');
  if (calib != null) out['ambient_calibration_s'] = calib;
  final sep = num('separation_m');
  if (sep != null) out['separation_m'] = sep;
  final bpm = num('breathing_bpm_ref');
  if (bpm != null) out['breathing_bpm_ref'] = bpm;
  final channel = num('channel');
  if (channel != null) out['channel'] = channel.toInt();
  final bw = num('bandwidth_mhz');
  if (bw != null) out['bandwidth_mhz'] = bw;
  return out;
}

// --- Shared windowed features ------------------------------------------

/// One fixed-length window of packets.
class CsiWindow {
  const CsiWindow({required this.packets, required this.start});

  final List<CsiPacket> packets;
  final DateTime start;

  int get count => packets.length;
}

/// Slice [packets] into non-overlapping windows of [windowS] seconds.
List<CsiWindow> windowPackets(List<CsiPacket> packets, double windowS) {
  if (packets.isEmpty || windowS <= 0) return [];
  final out = <CsiWindow>[];
  var start = packets.first.t;
  var current = <CsiPacket>[];
  for (final p in packets) {
    if (p.t.difference(start).inMicroseconds / 1e6 >= windowS &&
        current.isNotEmpty) {
      out.add(CsiWindow(packets: current, start: start));
      start = p.t;
      current = [];
    }
    current.add(p);
  }
  if (current.isNotEmpty) out.add(CsiWindow(packets: current, start: start));
  return out;
}

/// Mean + variance of a list of finite values.
(double, double) meanVar(List<double> xs) {
  if (xs.isEmpty) return (double.nan, double.nan);
  final m = xs.fold(0.0, (a, b) => a + b) / xs.length;
  final v = xs.fold(0.0, (a, b) => (b - m) * (b - m)) / xs.length;
  return (m, v);
}

/// Windowed amplitude features: mean amplitude (over packets x
/// subcarriers) and its variance, per window.
List<(double, double)> ampMeanVarWindows(
    List<CsiPacket> packets, double windowS) {
  return [
    for (final w in windowPackets(packets, windowS))
      meanVar([for (final p in w.packets) p.meanAmp]),
  ];
}

/// Detrended phase: per subcarrier, remove the best-fit line over
/// the window (CFO/SFO drift removal — the phase that remains is
/// the disturbance signal, such as it is on S3 SISO), then the
/// variance of the residual across packets x subcarriers.
double detrendedPhaseVar(List<CsiPacket> packets) {
  if (packets.length < 3) return double.nan;
  final subs = packets.first.subcarriers;
  if (subs.isEmpty) return double.nan;
  final residuals = <double>[];
  final n = packets.length.toDouble();
  for (final s in subs) {
    final ys = [for (final p in packets) p.phase[s] ?? 0.0];
    // Unwrap phase so a -pi/pi crossing does not read as a jump.
    final unwrapped = _unwrap(ys);
    var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0;
    for (var i = 0; i < unwrapped.length; i++) {
      final x = i.toDouble(), y = unwrapped[i];
      sx += x;
      sy += y;
      sxx += x * x;
      sxy += x * y;
    }
    final denom = n * sxx - sx * sx;
    final slope = denom == 0 ? 0.0 : (n * sxy - sx * sy) / denom;
    final intercept = (sy - slope * sx) / n;
    for (var i = 0; i < unwrapped.length; i++) {
      residuals.add(unwrapped[i] - (intercept + slope * i));
    }
  }
  return meanVar(residuals).$2;
}

List<double> _unwrap(List<double> ys) {
  final out = <double>[ys.first];
  var offset = 0.0;
  for (var i = 1; i < ys.length; i++) {
    var d = ys[i] - ys[i - 1];
    if (d > math.pi) {
      offset -= 2 * math.pi;
    } else if (d < -math.pi) {
      offset += 2 * math.pi;
    }
    out.add(ys[i] + offset);
  }
  return out;
}

/// Ambient baseline from the leading [calibrationS] seconds of a
/// session: mean + variance of per-packet mean amplitude. Windows
/// after the baseline are scored as disturbance = (meanAmp -
/// baselineMean) / baselineStd (z-score; NaN when the baseline is
/// degenerate).
class AmbientBaseline {
  const AmbientBaseline({required this.mean, required this.std});

  final double mean;
  final double std;

  bool get valid => mean.isFinite && std.isFinite && std > 0;
}

AmbientBaseline ambientBaseline(CsiSession session) {
  final calibS = session.ambientCalibrationS > 0
      ? session.ambientCalibrationS
      : 60.0;
  final first = session.packets.first.t;
  final base = [
    for (final p in session.packets)
      if (p.t.difference(first).inMicroseconds / 1e6 < calibS) p.meanAmp,
  ];
  final (m, v) = meanVar(base);
  return AmbientBaseline(mean: m, std: math.sqrt(v));
}

/// Z-scored disturbance per window (see [AmbientBaseline]).
List<double> disturbanceZ(
    CsiSession session, double windowS, AmbientBaseline base) {
  if (!base.valid) return [];
  return [
    for (final (m, _) in ampMeanVarWindows(session.packets, windowS))
      (m - base.mean) / base.std,
  ];
}
