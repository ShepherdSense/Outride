/// B20 energy-crossover bench tests.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/services/bench_csi.dart' show kBenchPending;
import 'package:outride/services/bench_energy.dart';

const String _meta = '{"node": "esp32-s3 test rig", "uplink": "wifi", '
    '"rail_v": 5, "sample_rate_hz": 1000, "settling_pause_ms": 60, '
    '"source": "test fixture"}';

/// Build an energy CSV from (phase, sample count, current mA)
/// segments at 1 ms spacing, 5 V rail. Fixture currents are
/// arbitrary test values, not paper figures.
String _energyCsv(
  List<(String, int, double)> segments, {
  double voltageV = 5.0,
}) {
  final buf = StringBuffer('t_iso,phase,current_ma,voltage_v\n');
  var t = DateTime.utc(2026, 11, 25, 10, 0, 0);
  for (final (phase, n, ma) in segments) {
    for (var i = 0; i < n; i++) {
      buf.writeln('${t.toIso8601String()},$phase,$ma,$voltageV');
      t = t.add(const Duration(milliseconds: 1));
    }
  }
  return buf.toString();
}

Future<void> _writeSession(
  Directory dir,
  String name,
  String csv, {
  String meta = _meta,
}) async {
  await File('${dir.path}/$name').writeAsString(csv);
  await File('${dir.path}/${name.replaceAll('.csv', '')}.meta.json')
      .writeAsString(meta);
}

void main() {
  group('parseEnergyCsv', () {
    test('unknown phase is rejected', () {
      expect(
        () => parseEnergyCsv(
          'bad.csv',
          _energyCsv([('compute', 200, 100.0), ('bogus', 10, 50.0)]),
        ),
        throwsFormatException,
      );
    });

    test('non-increasing timestamps are rejected', () {
      const csv = 't_iso,phase,current_ma,voltage_v\n'
          '2026-11-25T10:00:00.000Z,compute,100,5\n'
          '2026-11-25T10:00:00.000Z,compute,100,5\n';
      expect(() => parseEnergyCsv('dup.csv', csv), throwsFormatException);
    });

    test('median interval outside the 1 kHz protocol is rejected', () {
      final buf = StringBuffer('t_iso,phase,current_ma,voltage_v\n');
      var t = DateTime.utc(2026, 11, 25, 10, 0, 0);
      for (var i = 0; i < 200; i++) {
        buf.writeln('${t.toIso8601String()},compute,100,5');
        t = t.add(const Duration(milliseconds: 5));
      }
      expect(
        () => parseEnergyCsv('slow.csv', buf.toString()),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('median sample interval'),
        )),
      );
    });
  });

  group('energySegments', () {
    test('settling exclusion drops the first 60 ms of a segment', () {
      final session = parseEnergyCsv(
        's.csv',
        _energyCsv([('compute', 200, 100.0)]),
      );
      final segs = energySegments(session);
      expect(segs.length, 1);
      expect(segs.first.samples.length, 200);
      // 200 ms segment, first 60 ms dropped -> 140 settled samples.
      expect(segs.first.settled.length, 140);
      expect(segs.first.isMeasured, isTrue);
      // 5 V x 100 mA = 500 mW over 0.140 s = 70 mJ.
      expect(segs.first.energyMj, closeTo(70.0, 1e-9));
    });

    test('a segment with fewer than 10 settled samples is not measured',
        () {
      final session = parseEnergyCsv(
        's.csv',
        _energyCsv([('compute', 65, 100.0)]),
      );
      final segs = energySegments(session);
      expect(segs.first.settled.length, 5);
      expect(segs.first.isMeasured, isFalse);
    });
  });

  group('runEnergyBench', () {
    test('no input → SKIPPED with the exact pending string', () async {
      final dir =
          await Directory.systemTemp.createTemp('bench_b20_empty');
      try {
        final outcome = runEnergyBench(dir);
        expect(outcome.skipped, isTrue);
        expect(outcome.skipReason, kBenchPending);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('rejected file listed with reason', () async {
      final dir = await Directory.systemTemp.createTemp('bench_b20_rej');
      try {
        await File('${dir.path}/bad.csv').writeAsString(
          't_iso,phase,current_ma\n2026-11-25T10:00:00.000Z,compute,100\n',
        );
        final outcome = runEnergyBench(dir);
        expect(outcome.skipped, isTrue);
        expect(outcome.rejected.keys, contains('bad.csv'));
        expect(outcome.rejected['bad.csv'],
            contains('missing required column voltage_v'));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('missing sidecar rejects the session with the reason stated',
        () async {
      final dir =
          await Directory.systemTemp.createTemp('bench_b20_nometa');
      try {
        await File('${dir.path}/s.csv').writeAsString(
          _energyCsv([('compute', 200, 100.0)]),
        );
        final outcome = runEnergyBench(dir);
        expect(outcome.skipped, isTrue);
        expect(outcome.rejected.keys, contains('s.csv'));
        expect(outcome.rejected['s.csv'], contains('meta.json'));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('sidecar with a non-protocol sample rate rejects the session',
        () async {
      final dir =
          await Directory.systemTemp.createTemp('bench_b20_rate');
      try {
        await _writeSession(
          dir,
          's.csv',
          _energyCsv([('compute', 200, 100.0)]),
          meta: '{"node": "esp32-s3 test rig", "uplink": "wifi", '
              '"rail_v": 5, "sample_rate_hz": 500, '
              '"settling_pause_ms": 60}',
        );
        final outcome = runEnergyBench(dir);
        expect(outcome.skipped, isTrue);
        expect(outcome.rejected['s.csv'], contains('sample_rate_hz'));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('sidecar with a non-protocol settling pause rejects the session',
        () async {
      final dir =
          await Directory.systemTemp.createTemp('bench_b20_settle30');
      try {
        await _writeSession(
          dir,
          's.csv',
          _energyCsv([('compute', 200, 100.0)]),
          meta: '{"node": "esp32-s3 test rig", "uplink": "wifi", '
              '"rail_v": 5, "sample_rate_hz": 1000, '
              '"settling_pause_ms": 30}',
        );
        final outcome = runEnergyBench(dir);
        expect(outcome.skipped, isTrue);
        expect(
            outcome.rejected['s.csv'], contains('settling_pause_ms'));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('sidecar missing rail_v rejects the session', () async {
      final dir =
          await Directory.systemTemp.createTemp('bench_b20_norail');
      try {
        await _writeSession(
          dir,
          's.csv',
          _energyCsv([('compute', 200, 100.0)]),
          meta: '{"node": "esp32-s3 test rig", "uplink": "wifi", '
              '"sample_rate_hz": 1000, "settling_pause_ms": 60}',
        );
        final outcome = runEnergyBench(dir);
        expect(outcome.skipped, isTrue);
        expect(outcome.rejected['s.csv'], contains('rail_v'));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('sidecar with rail_v <= 0 rejects the session', () async {
      final dir =
          await Directory.systemTemp.createTemp('bench_b20_rail0');
      try {
        await _writeSession(
          dir,
          's.csv',
          _energyCsv([('compute', 200, 100.0)]),
          meta: '{"node": "esp32-s3 test rig", "uplink": "wifi", '
              '"rail_v": 0, "sample_rate_hz": 1000, '
              '"settling_pause_ms": 60}',
        );
        final outcome = runEnergyBench(dir);
        expect(outcome.skipped, isTrue);
        expect(outcome.rejected['s.csv'], contains('rail_v'));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('runs on one minimal valid session and scores the three bars',
        () async {
      final dir = await Directory.systemTemp.createTemp('bench_b20_run');
      try {
        await _writeSession(
          dir,
          'fixture.csv',
          _energyCsv([
            ('compute', 200, 100.0),
            ('communicate', 200, 300.0),
          ]),
        );
        final outcome = runEnergyBench(dir);
        expect(outcome.skipped, isFalse);
        expect(outcome.sessionsRun, ['fixture.csv']);
        expect(outcome.verdicts.length, 3);
        expect(outcome.allPassed, isTrue);
        // Compute: 500 mW x 0.140 s = 70 mJ/epoch.
        expect(outcome.verdicts[0].passed, isTrue);
        expect(outcome.verdicts[0].detail, contains('70.000 mJ/epoch'));
        // Communicate: 1500 mW x 0.140 s = 210 mJ/turn.
        expect(outcome.verdicts[1].passed, isTrue);
        expect(outcome.verdicts[1].detail, contains('210.000 mJ/turn'));
        // Crossover: 210 / 70 = 3 epochs.
        expect(outcome.verdicts[2].passed, isTrue);
        expect(outcome.verdicts[2].detail, contains('3.000 epochs'));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('settling spike inside the first 60 ms does not count', () async {
      final dir =
          await Directory.systemTemp.createTemp('bench_b20_settle');
      try {
        // Compute segment: 60 samples at a 10x spike current
        // (settling), then 140 at the steady current.
        final buf = StringBuffer('t_iso,phase,current_ma,voltage_v\n');
        var t = DateTime.utc(2026, 11, 25, 10, 0, 0);
        void rows(int n, double ma, String phase) {
          for (var i = 0; i < n; i++) {
            buf.writeln('${t.toIso8601String()},$phase,$ma,5');
            t = t.add(const Duration(milliseconds: 1));
          }
        }

        rows(60, 1000.0, 'compute');
        rows(140, 100.0, 'compute');
        rows(200, 300.0, 'communicate');
        await _writeSession(dir, 'fixture.csv', buf.toString());
        final outcome = runEnergyBench(dir);
        expect(outcome.skipped, isFalse);
        // The spike is inside the settling window: compute energy
        // is still the steady 70 mJ/epoch, not the spiked value.
        expect(outcome.verdicts[0].detail, contains('70.000 mJ/epoch'));
        expect(outcome.allPassed, isTrue);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('compute-only session scores, crossover is N/A, not a pass',
        () async {
      final dir =
          await Directory.systemTemp.createTemp('bench_b20_half');
      try {
        await _writeSession(
          dir,
          'fixture.csv',
          _energyCsv([('compute', 200, 100.0)]),
        );
        final outcome = runEnergyBench(dir);
        expect(outcome.skipped, isFalse);
        expect(outcome.verdicts[0].passed, isTrue);
        expect(outcome.verdicts[1].passed, isFalse);
        expect(outcome.verdicts[2].notApplicable, isTrue);
        expect(outcome.allPassed, isFalse);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('energySessionIsScorable needs both arms measured', () {
      final both = parseEnergyCsv(
        's.csv',
        _energyCsv([('compute', 200, 100.0), ('communicate', 200, 300.0)]),
      );
      expect(energySessionIsScorable(both), isTrue);
      final one = parseEnergyCsv(
        's.csv',
        _energyCsv([('compute', 200, 100.0)]),
      );
      expect(energySessionIsScorable(one), isFalse);
    });
  });
}
