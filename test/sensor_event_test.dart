import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/models/sensor_observation.dart';
import 'package:outride/services/generic_sensor_driver.dart';
import 'package:outride/services/sensor_event.dart';
import 'package:outride/services/sensor_protocol.dart';

// Integer `t` (unix seconds) in every fixture: the parser converts to
// whole milliseconds and the encoder divides back, so the round-trip
// is exact and the test can demand map equality, not "close enough".
const _t = 1760000000;

/// Decode wire JSON through the typed surface, re-encode, and require
/// the exact same JSON map back (encode → decode → encode matches).
SensorEvent _expectRoundTrip(Map<String, dynamic> wire) {
  final event = SensorEvent.parseEvent(wire).when(
    ok: (e) => e,
    malformed: (w) => fail('expected ok, got malformed: $w for $wire'),
    ignored: () => fail('expected ok, got ignored for $wire'),
  );
  expect(event.toUdpJson(), equals(wire));
  return event;
}

void main() {
  // Round-trip scope: the six observation verbs delegate to the
  // legacy encoder (byte-identical output, asserted in the group
  // below); CSI/WIND use new encoders, proven here by round-trip.
  // Two edges: a CSI datagram omitting wind_gated gains the
  // fail-safe default on first encode (idempotent thereafter), and
  // lat/lon (0,0) is dropped by the parsers (pre-existing).
  group('SensorEvent JSON round-trip (wire format preserved)', () {
    test('RANGE', () {
      _expectRoundTrip({
        'type': 'sensor_obs',
        'obs': 'RANGE',
        'sensor': 'lidar1',
        'dist_m': 12.4,
        'angle_deg': 45.0,
        'lat': 35.0,
        'lon': -79.0,
        't': _t,
      });
    });

    test('BEARING', () {
      _expectRoundTrip({
        'type': 'sensor_obs',
        'obs': 'BEARING',
        'sensor': 'micarray',
        'bearing_deg': 137.0,
        'confidence': 0.8,
        't': _t,
      });
    });

    test('SPECTRUM', () {
      _expectRoundTrip({
        'type': 'sensor_obs',
        'obs': 'SPECTRUM',
        'sensor': 'mic1',
        'freq_hz': [120.0, 240.0, 480.0],
        'magnitudes': [0.2, 0.9, 0.15],
        't': _t,
      });
    });

    test('BINARY', () {
      _expectRoundTrip({
        'type': 'sensor_obs',
        'obs': 'BINARY',
        'sensor': 'pir1',
        'triggered': true,
        't': _t,
      });
    });

    test('ENERGY', () {
      _expectRoundTrip({
        'type': 'sensor_obs',
        'obs': 'ENERGY',
        'sensor': 'rf1',
        'level_db': -67.0,
        't': _t,
      });
    });

    test('MOTION', () {
      _expectRoundTrip({
        'type': 'sensor_obs',
        'obs': 'MOTION',
        'sensor': 'cam1',
        'zone': '3',
        'zone_label': 'north-fence',
        't': _t,
      });
    });

    test('CSI (full optionals)', () {
      _expectRoundTrip({
        'type': 'sensor_obs',
        'obs': 'CSI',
        'sensor': 'csi_ap_buffalo',
        'dev_hz': 12.4,
        'pairs_active': 19,
        'path_loss_db': 54.0,
        'link': 'ap:buffalo',
        'wind_ms': 1.8,
        'wind_gated': false,
        'lat': 35.0,
        'lon': -79.0,
        't': _t,
      });
    });

    test('WIND (full optionals)', () {
      _expectRoundTrip({
        'type': 'sensor_obs',
        'obs': 'WIND',
        'sensor': 'anem_1',
        'wind_ms': 4.2,
        'gust_ms': 6.1,
        'lat': 35.0,
        'lon': -79.0,
        't': _t,
      });
    });

    test('CSI/WIND without wind_gated: encode is idempotent', () {
      // A CSI datagram that omits wind_gated parses fail-safe (gated)
      // and the encoder always writes the field — so the FIRST encode
      // differs from the input, but encode → decode → encode is
      // stable. That is the honest round-trip for a defaulted field.
      final wire = {
        'type': 'sensor_obs',
        'obs': 'CSI',
        'sensor': 'csi_ap',
        'dev_hz': 5.0,
        't': _t,
      };
      final first = SensorEvent.parseEvent(wire).when(
        ok: (e) => e.toUdpJson(),
        malformed: (w) => fail('malformed: $w'),
        ignored: () => fail('ignored'),
      );
      expect(first['wind_gated'], isTrue);
      final second = SensorEvent.parseEvent(first).when(
        ok: (e) => e.toUdpJson(),
        malformed: (w) => fail('malformed: $w'),
        ignored: () => fail('ignored'),
      );
      expect(second, equals(first));
    });
  });

  group('SensorEvent vs legacy encoder (identical before/after)', () {
    test(
        'typed toUdpJson == SensorProtocol.toUdpJson for all six '
        'observation verbs', () {
      final wires = <Map<String, dynamic>>[
        {
          'type': 'sensor_obs',
          'obs': 'RANGE',
          'sensor': 'lidar1',
          'dist_m': 12.4,
          'angle_deg': 45.0,
          't': _t,
        },
        {
          'type': 'sensor_obs',
          'obs': 'BEARING',
          'sensor': 'micarray',
          'bearing_deg': 137.0,
          'confidence': 0.8,
          't': _t,
        },
        {
          'type': 'sensor_obs',
          'obs': 'SPECTRUM',
          'sensor': 'mic1',
          'freq_hz': [120.0, 240.0],
          'magnitudes': [0.2, 0.9],
          't': _t,
        },
        {
          'type': 'sensor_obs',
          'obs': 'BINARY',
          'sensor': 'pir1',
          'triggered': false,
          't': _t,
        },
        {
          'type': 'sensor_obs',
          'obs': 'ENERGY',
          'sensor': 'rf1',
          'level_db': -67.0,
          't': _t,
        },
        {
          'type': 'sensor_obs',
          'obs': 'MOTION',
          'sensor': 'cam1',
          'zone': '3',
          't': _t,
        },
      ];
      for (final wire in wires) {
        final legacy = SensorProtocol.parseUdpJson(wire).observation!;
        final event = SensorEvent.parseEvent(wire).when(
          ok: (e) => e,
          malformed: (w) => fail('malformed: $w'),
          ignored: () => fail('ignored'),
        );
        expect(event.toUdpJson(), equals(SensorProtocol.toUdpJson(legacy)),
            reason: 'typed encoder diverged from legacy for ${wire['obs']}');
      }
    });
  });

  group('SensorEvent.fromObservation variant mapping', () {
    test('each SensorObsType lands in its own variant', () {
      final at = DateTime.fromMillisecondsSinceEpoch(_t * 1000, isUtc: true);
      expect(
          SensorEvent.fromObservation(SensorObservation(
              type: SensorObsType.range,
              sensorId: 's',
              timestamp: at,
              distanceM: 1.0)),
          isA<SensorRangeEvent>());
      expect(
          SensorEvent.fromObservation(SensorObservation(
              type: SensorObsType.bearing,
              sensorId: 's',
              timestamp: at,
              bearingDeg: 10.0)),
          isA<SensorBearingEvent>());
      expect(
          SensorEvent.fromObservation(SensorObservation(
              type: SensorObsType.spectrum,
              sensorId: 's',
              timestamp: at,
              freqHz: [100.0],
              magnitudes: [1.0])),
          isA<SensorSpectrumEvent>());
      expect(
          SensorEvent.fromObservation(SensorObservation(
              type: SensorObsType.binary,
              sensorId: 's',
              timestamp: at,
              triggered: true)),
          isA<SensorBinaryEvent>());
      expect(
          SensorEvent.fromObservation(SensorObservation(
              type: SensorObsType.energy,
              sensorId: 's',
              timestamp: at,
              levelDb: -70.0)),
          isA<SensorEnergyEvent>());
      expect(
          SensorEvent.fromObservation(SensorObservation(
              type: SensorObsType.motion, sensorId: 's', timestamp: at)),
          isA<SensorMotionEvent>());
    });
  });

  group('SensorEventParseResult outcomes', () {
    test('unknown verb is ignored, not malformed', () {
      final r = SensorEvent.parseEvent({
        'type': 'sensor_obs',
        'obs': 'QUANTUM',
        'sensor': 'q1',
        't': _t,
      });
      expect(r, isA<SensorEventIgnored>());
    });

    test('non-sensor_obs datagram is ignored', () {
      final r = SensorEvent.parseEvent({
        'type': 'beacon',
        'obs': 'RANGE',
        'sensor': 'lidar1',
        't': _t,
      });
      expect(r, isA<SensorEventIgnored>());
    });

    test('known verb with bad payload is malformed with a warning', () {
      final badRange = SensorEvent.parseEvent({
        'type': 'sensor_obs',
        'obs': 'RANGE',
        'sensor': 'lidar1',
        't': _t,
      });
      expect(badRange, isA<SensorEventMalformed>());
      badRange.when(
        ok: (_) => fail('expected malformed'),
        malformed: (w) => expect(w, isNotEmpty),
        ignored: () => fail('expected malformed'),
      );

      final badCsi = SensorEvent.parseEvent({
        'type': 'sensor_obs',
        'obs': 'CSI',
        'sensor': 'csi_ap',
        't': _t, // dev_hz missing
      });
      expect(badCsi, isA<SensorEventMalformed>());

      final badWind = SensorEvent.parseEvent({
        'type': 'sensor_obs',
        'obs': 'WIND',
        'sensor': 'anem_1',
        'wind_ms': -1.0,
        't': _t,
      });
      expect(badWind, isA<SensorEventMalformed>());
    });
  });

  group('GenericSensorDriver typed dispatch (datagramForTest)', () {
    test('CSI + WIND ingest, unknown verb skipped, malformed counted', () {
      final d = GenericSensorDriver();
      // Driver-side: use a CURRENT timestamp — the store prunes CSI
      // older than 30 s / WIND older than 5 min on the next ingest.
      final nowS = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      d.datagramForTest(jsonEncode({
        'type': 'sensor_obs',
        'obs': 'CSI',
        'sensor': 'csi_ap',
        'dev_hz': 12.4,
        'wind_gated': false,
        't': nowS,
      }));
      d.datagramForTest(jsonEncode({
        'type': 'sensor_obs',
        'obs': 'WIND',
        'sensor': 'anem_1',
        'wind_ms': 4.2,
        't': nowS,
      }));
      d.datagramForTest(jsonEncode({
        'type': 'sensor_obs',
        'obs': 'ENERGY',
        'sensor': 'rf1',
        'level_db': -67.0,
        't': nowS,
      }));
      // Unknown verb: skipped, never counted malformed (§1c).
      d.datagramForTest(jsonEncode({
        'type': 'sensor_obs',
        'obs': 'QUANTUM',
        'sensor': 'q1',
        't': _t,
      }));
      // Known verb, bad payload: counted malformed.
      d.datagramForTest(jsonEncode({
        'type': 'sensor_obs',
        'obs': 'RANGE',
        'sensor': 'lidar1',
        't': _t,
      }));
      // Not our datagram at all: ignored silently.
      d.datagramForTest('{"type":"beacon","node":"x"}');
      d.datagramForTest('not json at all');

      expect(d.ingestedCount, 3);
      expect(d.malformedCount, 1);
      expect(d.latestCsi().keys, contains('csi_ap'));
      expect(d.latestWind().keys, contains('anem_1'));
      expect(d.latestPerSensor().keys, contains('rf1'));
    });
  });
}
