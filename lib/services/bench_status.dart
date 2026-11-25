/// Bench input readiness for the Sensors-row pill (`N of M READY`).
///
/// The pill counts harnesses whose required input is present and
/// valid — not harnesses that exist. The scan runs when the Bench
/// screen opens (and after every run) and publishes here; the
/// Sensors row listens to [benchReadyCount] and shows the last
/// scan. Before any scan the honest value is 0: no input has been
/// seen yet, so nothing is READY.
///
/// RF-track entries are ready when ≥1 valid RF session exists AND
/// its node geometry is present (a session without nodes cannot be
/// replayed). CSI entries are ready when ≥2 valid labeled CSI
/// sessions exist — B7/B12 need ≥2 labeled sessions (leave-one-
/// session-out cannot run on one) and B-W1/B-W4 need both classes,
/// so a single CSI session marks nothing READY. The B20 entry is
/// ready when ≥1 energy session exists that can score the
/// crossover (≥1 measured compute segment AND ≥1 measured
/// communicate segment). The B5 group rides B1's input (see
/// [benchRunnableEntryCount]).
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'bench_csi.dart';
import 'bench_energy.dart';
import 'bench_record.dart';
import 'fusion_bench_harness.dart';

/// Last scanned ready count (0 before the first scan).
final ValueNotifier<int> benchReadyCount = ValueNotifier<int>(0);

/// Scan the app documents dir for bench inputs and publish the
/// ready count. Never throws — a failed scan publishes 0.
Future<void> refreshBenchReadiness() async {
  try {
    final docs = await getApplicationDocumentsDirectory();
    final rfDir = Directory('${docs.path}/$defaultSessionsDirName');
    final csiDir =
        Directory('${docs.path}/$defaultCsiSessionsDirName');
    final rf = loadSessions(rfDir);
    var rfReady = false;
    for (final s in rf.sessions) {
      if (s.polls.length < 2) continue;
      final nodes = BenchRecorder.loadBenchNodes(rfDir, s.name);
      if (nodes.isNotEmpty) {
        rfReady = true;
        break;
      }
    }
    final csi = loadCsiSessions(csiDir);
    final labeledCsi = csi.sessions
        .where((s) => s.packets.length >= 10 && s.type != null)
        .toList();
    // ≥2 labeled sessions (ideally both classes — B-W1/B-W4 need a
    // positive and a negative class; a single session can score
    // nothing leave-one-out).
    final csiReady = labeledCsi.length >= 2;
    final energyDir =
        Directory('${docs.path}/$defaultEnergySessionsDirName');
    final energy = loadEnergySessions(energyDir);
    final energyReady =
        energy.sessions.any(energySessionIsScorable);
    var ready = 0;
    if (rfReady) {
      // RF-track entries: B1, B4, B9, B10, B11, B14 (+ B5 riding B1).
      ready += 6;
    }
    if (csiReady) {
      // CSI entries: B7, B12, B-W1–B-W4.
      ready += 6;
    }
    if (energyReady) {
      // Energy entry: B20.
      ready += 1;
    }
    benchReadyCount.value = ready;
  } catch (_) {
    benchReadyCount.value = 0;
  }
}

/// Input summary counts for the Bench screen header (never
/// hard-coded): RF sessions, rejected RF files, CSI sessions,
/// rejected CSI files, energy sessions, rejected energy files.
Future<({
  int rfSessions,
  int rfRejected,
  int csiSessions,
  int csiRejected,
  int energySessions,
  int energyRejected,
})> scanBenchInputs() async {
  final docs = await getApplicationDocumentsDirectory();
  final rfDir = Directory('${docs.path}/$defaultSessionsDirName');
  final csiDir = Directory('${docs.path}/$defaultCsiSessionsDirName');
  final energyDir =
      Directory('${docs.path}/$defaultEnergySessionsDirName');
  final rf = loadSessions(rfDir);
  final csi = loadCsiSessions(csiDir);
  final energy = loadEnergySessions(energyDir);
  return (
    rfSessions: rf.sessions.length,
    rfRejected: rf.rejected.length,
    csiSessions: csi.sessions.length,
    csiRejected: csi.rejected.length,
    energySessions: energy.sessions.length,
    energyRejected: energy.rejected.length,
  );
}

/// The documents-dir bench sessions directory (for the Bench screen
/// runners).
Future<Directory> benchSessionsDir() async {
  final docs = await getApplicationDocumentsDirectory();
  return Directory('${docs.path}/$defaultSessionsDirName');
}

/// The documents-dir CSI sessions directory.
Future<Directory> csiSessionsDir() async {
  final docs = await getApplicationDocumentsDirectory();
  return Directory('${docs.path}/$defaultCsiSessionsDirName');
}

/// The documents-dir energy sessions directory.
Future<Directory> energySessionsDir() async {
  final docs = await getApplicationDocumentsDirectory();
  return Directory('${docs.path}/$defaultEnergySessionsDirName');
}
