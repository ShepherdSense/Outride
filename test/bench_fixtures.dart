/// Shared MECHANICS-ONLY fixtures for the bench harness tests.
///
/// These fixtures verify that harnesses RUN — parsing, estimation,
/// fusion, scoring — and produce finite, structurally consistent
/// output. Their numbers are NEVER bench results and are never
/// reported as such; the benches measure only recorded sessions.
/// All CSVs here are hand-built (RF) or programmatically generated
/// from explicit formulas (CSI) and labeled as fixtures.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:outride/models/tracking.dart';

/// 3-node RF-track fixture (same shape as the B1 harness test
/// fixture): 3 nodes, 5 polls, truth walking (10,10) → (30,10).
const String kBenchFixtureCsv = '''
t_iso,link_key,from_node,to_node,snr_db,dip_db,truth_x,truth_y,truth_id
2026-11-21T00:00:00Z,n0>n1,n0,n1,20.0,12.0,10.0,10.0,A
2026-11-21T00:00:00Z,n1>n2,n1,n2,20.0,4.0,10.0,10.0,A
2026-11-21T00:00:00Z,n2>n0,n2,n0,20.0,8.0,10.0,10.0,A
2026-11-21T00:00:01Z,n0>n1,n0,n1,20.0,13.0,15.0,10.0,A
2026-11-21T00:00:01Z,n1>n2,n1,n2,20.0,5.0,15.0,10.0,A
2026-11-21T00:00:01Z,n2>n0,n2,n0,20.0,7.0,15.0,10.0,A
2026-11-21T00:00:02Z,n0>n1,n0,n1,20.0,12.0,20.0,10.0,A
2026-11-21T00:00:02Z,n1>n2,n1,n2,20.0,7.0,20.0,10.0,A
2026-11-21T00:00:02Z,n2>n0,n2,n0,20.0,6.5,20.0,10.0,A
2026-11-21T00:00:03Z,n0>n1,n0,n1,20.0,10.0,25.0,10.0,A
2026-11-21T00:00:03Z,n1>n2,n1,n2,20.0,9.0,25.0,10.0,A
2026-11-21T00:00:03Z,n2>n0,n2,n0,20.0,5.0,25.0,10.0,A
2026-11-21T00:00:04Z,n0>n1,n0,n1,20.0,8.0,30.0,10.0,A
2026-11-21T00:00:04Z,n1>n2,n1,n2,20.0,3.0,30.0,10.0,A
2026-11-21T00:00:04Z,n2>n0,n2,n0,20.0,4.0,30.0,10.0,A
''';

/// Recorder-format CSV (no dip_db / truth columns): NOT a bench
/// session — must be rejected, never scored.
const String kBenchRecorderCsv = '''
t_iso,link_key,from_node,to_node,snr_db
2026-11-21T00:00:00Z,n0>n1,n0,n1,20.0
''';

/// One-poll RF session: parses, but too short to score (< 2 polls).
const String kBenchOnePollCsv = '''
t_iso,link_key,from_node,to_node,snr_db,dip_db,truth_x,truth_y,truth_id
2026-11-21T00:00:00Z,n0>n1,n0,n1,20.0,12.0,10.0,10.0,A
''';

Map<String, NodePosition> benchFixtureNodes() => {
      'n0': NodePosition(nodeId: 'n0', x: 0, y: 0),
      'n1': NodePosition(nodeId: 'n1', x: 40, y: 0),
      'n2': NodePosition(nodeId: 'n2', x: 20, y: 35),
    };

/// Write an RF session CSV into [dir].
Future<File> writeRfSession(Directory dir, String name, String csv) async {
  final f = File('${dir.path}/$name');
  await f.writeAsString(csv);
  return f;
}

/// Generate a CSI session CSV + meta sidecar.
///
/// [ampMean] gives the per-packet mean amplitude (one value per
/// packet); [phaseMean] the per-packet mean phase. Subcarriers are
/// derived deterministically (amp ±0.02 by subcarrier, phase
/// +0.01/subcarrier) so the file is a valid CSI session, not a
/// measurement of anything.
Future<File> writeCsiSession(
  Directory dir,
  String name, {
  required String type,
  required List<double> ampMean,
  List<double>? phaseMean,
  double stepS = 0.1,
  int subcarriers = 4,
  double ambientCalibrationS = 1.0,
  String room = 'lab',
  double separationM = 3.0,
  double? breathingBpmRef,
  int? channel,
  double? bandwidthMhz,
  // Per-subcarrier amplitude spread around ampMean (default 0.02).
  // Pass 0.0 for spectrally flat sessions: every packet's meanAmp is
  // then exactly ampMean[i], so a steady series has exactly zero
  // variance (no floating-point-epsilon spectral peak for the
  // B-W4 DFT to claim on).
  double subcarrierSpread = 0.02,
}) async {
  final buf = StringBuffer();
  buf.writeln('t_iso,link_id,subcarrier,amp,phase');
  final base = DateTime.utc(2026, 11, 21, 0, 0, 0);
  final phases = phaseMean ?? List.filled(ampMean.length, 0.5);
  for (var i = 0; i < ampMean.length; i++) {
    final t = base.add(Duration(milliseconds: (i * stepS * 1000).round()));
    for (var s = 0; s < subcarriers; s++) {
      final amp = (ampMean[i] + (s - subcarriers / 2) * subcarrierSpread)
          .clamp(0.01, double.infinity);
      final phase = phases[i] + s * 0.01;
      buf.writeln(
          '${t.toIso8601String()},tx1>rx1,$s,${amp.toStringAsFixed(4)},'
          '${phase.toStringAsFixed(4)}');
    }
  }
  final f = File('${dir.path}/$name');
  await f.writeAsString(buf.toString());
  final meta = StringBuffer()
    ..writeln('{')
    ..writeln('  "geometry": {"tx": [0, 0], "rx": [$separationM, 0], '
        '"separation_m": $separationM},')
    ..writeln('  "room": "$room",')
    ..writeln('  "type": "$type",')
    ..writeln('  "ambient_calibration_s": $ambientCalibrationS,')
    ..writeln('  "sample_rate_hz": ${1 / stepS},')
    ..writeln('  "source": "test fixture (hand-built, not a measurement)"');
  if (breathingBpmRef != null) {
    meta.writeln('  ,"breathing_bpm_ref": $breathingBpmRef');
  }
  if (channel != null) {
    meta.writeln('  ,"channel": $channel');
  }
  if (bandwidthMhz != null) {
    meta.writeln('  ,"bandwidth_mhz": $bandwidthMhz');
  }
  meta.writeln('}');
  await File('${dir.path}/${name.replaceAll('.csv', '.meta.json')}')
      .writeAsString(meta.toString());
  return f;
}

/// Steady amplitude series (no disturbance): [count] packets at
/// [level] with ±[jitter] deterministic wobble.
List<double> steadyAmp(int count, double level, [double jitter = 0.005]) =>
    [
      for (var i = 0; i < count; i++)
        level + jitter * math.sin(i * 0.7),
    ];

/// Disturbed amplitude series: baseline [level], disturbance of
/// [depth] starting at packet [from] (a step — a person crossing).
List<double> steppedAmp(
  int count,
  double level,
  double depth,
  int from, [
  double jitter = 0.01,
]) =>
    [
      for (var i = 0; i < count; i++)
        level +
            (i >= from ? depth : 0.0) +
            jitter * math.sin(i * 0.7),
    ];

/// Breathing amplitude series: [bpm] breaths/min sinusoid at [rate]
/// Hz sampling over [seconds] seconds.
List<double> breathingAmp(double bpm, double seconds, double rate) {
  final count = (seconds * rate).round();
  final fHz = bpm / 60.0;
  return [
    for (var i = 0; i < count; i++)
      1.0 + 0.1 * math.sin(2 * math.pi * fHz * i / rate),
  ];
}

/// Phase series with per-packet noise of amplitude [noise] (a
/// present person disturbs phase); steady 0.5 otherwise.
List<double> noisyPhase(int count, double noise) => [
      for (var i = 0; i < count; i++) 0.5 + noise * math.sin(i * 1.3),
    ];
