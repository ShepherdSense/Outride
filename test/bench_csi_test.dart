/// CSI session loader tests (bench_csi.dart): schema, rejection,
/// meta sidecar, windowed features.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/services/bench_csi.dart';

import 'bench_fixtures.dart';

const String _validCsi = '''
t_iso,link_id,subcarrier,amp,phase
2026-11-21T00:00:00.000Z,tx1>rx1,0,1.0,0.5
2026-11-21T00:00:00.000Z,tx1>rx1,1,1.1,0.51
2026-11-21T00:00:00.100Z,tx1>rx1,0,1.0,0.5
2026-11-21T00:00:00.100Z,tx1>rx1,1,1.1,0.51
''';

void main() {
  group('parseCsiCsv', () {
    test('parses one packet per t_iso with subcarriers', () {
      final s = parseCsiCsv('s.csv', _validCsi);
      expect(s.packets.length, 2);
      expect(s.packets.first.subcarriers, [0, 1]);
      expect(s.packets.first.meanAmp, closeTo(1.05, 1e-9));
    });

    test('missing column rejected with reason', () {
      expect(
        () => parseCsiCsv(
            's.csv', 't_iso,link_id,subcarrier,amp\n2026-11-21T00:00:00.000Z,tx1>rx1,0,1.0\n'),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('phase'))),
      );
    });

    test('mixed link_id rejected, never silently mixed', () {
      const bad = '''
t_iso,link_id,subcarrier,amp,phase
2026-11-21T00:00:00.000Z,tx1>rx1,0,1.0,0.5
2026-11-21T00:00:00.100Z,tx2>rx1,0,1.0,0.5
''';
      expect(
        () => parseCsiCsv('s.csv', bad),
        throwsA(isA<FormatException>().having(
            (e) => e.message, 'message', contains('mixed link_id'))),
      );
    });

    test('subcarrier set changing mid-file rejected', () {
      const bad = '''
t_iso,link_id,subcarrier,amp,phase
2026-11-21T00:00:00.000Z,tx1>rx1,0,1.0,0.5
2026-11-21T00:00:00.000Z,tx1>rx1,1,1.1,0.51
2026-11-21T00:00:00.100Z,tx1>rx1,0,1.0,0.5
''';
      expect(
        () => parseCsiCsv('s.csv', bad),
        throwsA(isA<FormatException>().having((e) => e.message,
            'message', contains('subcarrier set changed'))),
      );
    });

    test('negative amp rejected', () {
      const bad = '''
t_iso,link_id,subcarrier,amp,phase
2026-11-21T00:00:00.000Z,tx1>rx1,0,-1.0,0.5
''';
      expect(
        () => parseCsiCsv('s.csv', bad),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('loadCsiSessions', () {
    test('missing dir is the normal no-data state, not an error',
        () async {
      final dir =
          await Directory.systemTemp.createTemp('bench_csi_missing');
      try {
        final load = loadCsiSessions(dir);
        expect(load.sessions, isEmpty);
        expect(load.rejected, isEmpty);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('valid session + meta sidecar: type and calibration read',
        () async {
      final dir =
          await Directory.systemTemp.createTemp('bench_csi_meta');
      try {
        await writeCsiSession(
          dir,
          'present.csv',
          type: 'present',
          ampMean: steadyAmp(20, 1.0),
          ambientCalibrationS: 1.0,
          room: 'lab',
          channel: 6,
          bandwidthMhz: 20,
        );
        final load = loadCsiSessions(dir);
        expect(load.sessions.length, 1);
        expect(load.sessions.first.type, 'present');
        expect(load.sessions.first.room, 'lab');
        expect(load.sessions.first.ambientCalibrationS, 1.0);
        expect(load.sessions.first.channel, 6);
        expect(load.sessions.first.bandwidthMhz, 20.0);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('malformed file listed in rejected with reason', () async {
      final dir =
          await Directory.systemTemp.createTemp('bench_csi_rej');
      try {
        await File('${dir.path}/bad.csv')
            .writeAsString('t_iso,link_id\n2026-11-21T00:00:00Z,x\n');
        final load = loadCsiSessions(dir);
        expect(load.sessions, isEmpty);
        expect(load.rejected.keys, contains('bad.csv'));
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('windowed features', () {
    test('detrended phase var is ~0 for a linear phase ramp', () {
      final packets = [
        for (var i = 0; i < 10; i++)
          CsiPacket(
            t: DateTime.utc(2026, 11, 21).add(
                Duration(milliseconds: i * 100)),
            linkId: 'tx1>rx1',
            amp: {0: 1.0, 1: 1.0},
            phase: {0: 0.1 * i, 1: 0.1 * i},
          ),
      ];
      expect(detrendedPhaseVar(packets), closeTo(0.0, 1e-9));
    });

    test('ambient baseline + disturbance z-score', () async {
      final dir =
          await Directory.systemTemp.createTemp('bench_csi_z');
      try {
        await writeCsiSession(
          dir,
          's.csv',
          type: 'present',
          ampMean: steppedAmp(40, 1.0, 0.5, 15),
          ambientCalibrationS: 1.0,
        );
        final load = loadCsiSessions(dir);
        final s = load.sessions.first;
        final base = ambientBaseline(s);
        expect(base.valid, isTrue);
        final z = disturbanceZ(s, 1.0, base);
        expect(z.length, greaterThan(1));
        // Windows after the step disturb far above baseline.
        expect(z.last, greaterThan(3.0));
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
