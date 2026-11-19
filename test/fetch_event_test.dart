/// Tests for the Fetch (sensor ball) fused-event model:
/// parsing of the bench sketch's JSON, heartbeat, malformed input,
/// missing-GPS nulls, and tolerance of unknown fields.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/models/fetch_event.dart';

Map<String, dynamic> _event({
  double? magG = 1.02,
  double? micRms = 31772.0,
  bool accelTrip = false,
  bool micTrip = false,
  bool mmwaveTrip = true,
  bool bleTrip = false,
  bool wifiTrip = false,
  int? bleNearby = 15,
  int? wifiBeacons = 0,
  bool fix = false,
  int? sats = 0,
  double? lat,
  double? lon,
  String? lora = 'NOT_YET',
}) {
  return {
    'event': 'FUSED',
    'mag_g': magG,
    'mic_rms': micRms,
    'accel_trip': accelTrip,
    'mic_trip': micTrip,
    'mmwave_trip': mmwaveTrip,
    'ble_trip': bleTrip,
    'wifi_trip': wifiTrip,
    'ble_nearby': bleNearby,
    'wifi_beacons': wifiBeacons,
    'fix': fix,
    'sats': sats,
    'lat': lat,
    'lon': lon,
    'lora': lora,
  };
}

void main() {
  group('FetchEvent.tryParseJson', () {
    test('valid bench event parses with all fields', () {
      final e = FetchEvent.tryParseJson(_event());
      expect(e, isNotNull);
      expect(e!.magG, closeTo(1.02, 0.001));
      expect(e.micRms, 31772.0);
      expect(e.accelTrip, isFalse);
      expect(e.micTrip, isFalse);
      expect(e.mmwaveTrip, isTrue);
      expect(e.bleTrip, isFalse);
      expect(e.wifiTrip, isFalse);
      expect(e.bleNearby, 15);
      expect(e.wifiBeacons, 0);
      expect(e.gpsFix, isFalse);
      expect(e.sats, 0);
      expect(e.lat, isNull);
      expect(e.lon, isNull);
      expect(e.lora, 'NOT_YET');
      expect(e.trippedSensors, [FetchTripSensor.mmwave]);
      expect(e.anyTrip, isTrue);
    });

    test('GPS fix carries lat/lon; no-fix nulls them', () {
      final fixed = FetchEvent.tryParseJson(_event(
        fix: true,
        sats: 7,
        lat: 35.123456,
        lon: -79.012345,
      ));
      expect(fixed, isNotNull);
      expect(fixed!.gpsFix, isTrue);
      expect(fixed.sats, 7);
      expect(fixed.lat, closeTo(35.123456, 1e-6));
      expect(fixed.lon, closeTo(-79.012345, 1e-6));

      // fix:false with stale lat/lon fields present: the position is
      // dropped — a fix flag is the authority, not the numbers.
      final noFix = FetchEvent.tryParseJson(_event(
        fix: false,
        lat: 35.0,
        lon: -79.0,
      ));
      expect(noFix, isNotNull);
      expect(noFix!.gpsFix, isFalse);
      expect(noFix.lat, isNull);
      expect(noFix.lon, isNull);
    });

    test('missing GPS nulls are tolerated', () {
      final j = _event()..remove('lat')..remove('lon')..remove('sats');
      final e = FetchEvent.tryParseJson(j);
      expect(e, isNotNull);
      expect(e!.lat, isNull);
      expect(e.lon, isNull);
      expect(e.sats, isNull);
    });

    test('only ble_trip true', () {
      final e = FetchEvent.tryParseJson(_event(
        mmwaveTrip: false,
        bleTrip: true,
        bleNearby: 18,
      ));
      expect(e, isNotNull);
      expect(e!.trippedSensors, [FetchTripSensor.ble]);
      expect(e.tripped(FetchTripSensor.ble), isTrue);
      expect(e.tripped(FetchTripSensor.wifi), isFalse);
      expect(e.bleNearby, 18);
    });

    test('only wifi_trip true', () {
      final e = FetchEvent.tryParseJson(_event(
        mmwaveTrip: false,
        wifiTrip: true,
        wifiBeacons: 4,
      ));
      expect(e, isNotNull);
      expect(e!.trippedSensors, [FetchTripSensor.wifi]);
      expect(e.tripped(FetchTripSensor.wifi), isTrue);
      expect(e.tripped(FetchTripSensor.ble), isFalse);
      expect(e.wifiBeacons, 4);
    });

    test('all five tripwires can fire on one event', () {
      final e = FetchEvent.tryParseJson(_event(
        accelTrip: true,
        micTrip: true,
        mmwaveTrip: true,
        bleTrip: true,
        wifiTrip: true,
        magG: 1.71,
        micRms: 200000.0,
      ));
      expect(e, isNotNull);
      expect(e!.trippedSensors, [
        FetchTripSensor.accel,
        FetchTripSensor.mic,
        FetchTripSensor.mmwave,
        FetchTripSensor.ble,
        FetchTripSensor.wifi,
      ]);
      expect(e.anyTrip, isTrue);
    });

    test('older sketch events without ble_trip/wifi_trip default false', () {
      final j = _event()
        ..remove('ble_trip')
        ..remove('wifi_trip');
      final e = FetchEvent.tryParseJson(j);
      expect(e, isNotNull);
      expect(e!.bleTrip, isFalse);
      expect(e.wifiTrip, isFalse);
      expect(e.trippedSensors, [FetchTripSensor.mmwave]);
    });

    test('unknown fields are ignored', () {
      final j = _event()
        ..['future_field'] = 'whatever'
        ..['firmware'] = '1.2.3'
        ..['battery_mv'] = 3750;
      final e = FetchEvent.tryParseJson(j);
      expect(e, isNotNull);
      expect(e!.mmwaveTrip, isTrue);
    });

    test('wrong event type returns null', () {
      expect(FetchEvent.tryParseJson({'event': 'NOPE'}), isNull);
      expect(
          FetchEvent.tryParseJson({'gps': 'status', 'fix': false}),
          isNull);
      expect(FetchEvent.tryParseJson({'type': 'sensor_obs'}), isNull);
    });

    test('out-of-range coordinates return null; out-of-range gauges '
        'drop the field, keep the event', () {
      expect(FetchEvent.tryParseJson(_event(lat: 91.0, fix: true)), isNull);
      expect(FetchEvent.tryParseJson(_event(lon: -181.0, fix: true)),
          isNull);
      // A bad gauge value must not lose the trip report (B1): the
      // live sketch emits mag_g -1.000 when the BMI160 read fails,
      // and that event may carry a real mmWave trip.
      final badMag = FetchEvent.tryParseJson(_event(magG: -1.0));
      expect(badMag, isNotNull);
      expect(badMag!.magG, isNull);
      expect(badMag.mmwaveTrip, isTrue);
      final badMic = FetchEvent.tryParseJson(_event(micRms: -5.0));
      expect(badMic, isNotNull);
      expect(badMic!.micRms, isNull);
      expect(badMic.mmwaveTrip, isTrue);
      final hugeMic = FetchEvent.tryParseJson(_event(micRms: 200000000.0));
      expect(hugeMic, isNotNull);
      expect(hugeMic!.micRms, isNull);
    });

    test('failed accel read keeps a real trip report (B1 regression)', () {
      // The exact live-sketch failure: BMI160 misses one I2C read
      // (mag_g -1.000) at the same moment the mmWave OT1 fires.
      // That event must be ingested with its trip, not counted
      // malformed.
      final e = FetchEvent.tryParseJson(_event(
        magG: -1.0,
        mmwaveTrip: true,
      ));
      expect(e, isNotNull);
      expect(e!.magG, isNull);
      expect(e.trippedSensors, [FetchTripSensor.mmwave]);
      expect(e.anyTrip, isTrue);
    });

    test('fix:true without valid coordinates rejects the event', () {
      // A fix claim with a missing or out-of-range coordinate is
      // contradictory — the view would show FIX with nowhere to
      // point at, so the event is dropped, not half-kept.
      expect(FetchEvent.tryParseJson(_event(fix: true)), isNull);
      expect(
          FetchEvent.tryParseJson(
              _event(fix: true, lat: 35.0)), // lon missing
          isNull);
      expect(
          FetchGpsStatus.tryParseJson(
              {'gps': 'status', 'fix': true, 'sats': 3}),
          isNull);
    });

    test('(0,0) lat/lon is dropped, never plotted — and the fix claim '
        'goes with it', () {
      final e = FetchEvent.tryParseJson(_event(fix: true, lat: 0.0, lon: 0.0));
      expect(e, isNotNull);
      expect(e!.lat, isNull);
      expect(e.lon, isNull);
      // S1: no position, no fix claim — a consumer reading gpsFix
      // must never be told "FIX" with nowhere to point at.
      expect(e.gpsFix, isFalse);

      final s = FetchGpsStatus.tryParseJson(
          {'gps': 'status', 'fix': true, 'sats': 5, 'lat': 0.0, 'lon': 0.0});
      expect(s, isNotNull);
      expect(s!.lat, isNull);
      expect(s.lon, isNull);
      expect(s.gpsFix, isFalse);
      expect(s.sats, 5);
    });

    test('non-finite numbers drop the field, keep the event', () {
      // mag_g / mic_rms are optional gauges: a corrupt value drops
      // the field, it does not lose the trip report. (JSON has no NaN
      // literal, so this only arises from in-memory maps — but the
      // rule is the same for a wrong-typed value off the wire.)
      final j = _event()..['mag_g'] = double.nan;
      final e = FetchEvent.tryParseJson(j);
      expect(e, isNotNull);
      expect(e!.magG, isNull);
      expect(e.mmwaveTrip, isTrue);
      final j2 = _event()..['mic_rms'] = double.infinity;
      final e2 = FetchEvent.tryParseJson(j2);
      expect(e2, isNotNull);
      expect(e2!.micRms, isNull);
    });

    test('micRmsVsTrip scales against the 150k trip line', () {
      final e = FetchEvent.tryParseJson(_event(micRms: 75000.0));
      expect(e!.micRmsVsTrip, closeTo(0.5, 0.001));
      final over = FetchEvent.tryParseJson(_event(micRms: 900000.0));
      expect(over!.micRmsVsTrip, 4.0); // clamped
      final none = FetchEvent.tryParseJson(_event(micRms: null));
      expect(none!.micRmsVsTrip, isNull);
    });
  });

  group('FetchEvent.tryParseLine', () {
    test('real serial line parses', () {
      const line =
          '{"event":"FUSED","mag_g":1.025,"mic_rms":31772.0,'
          '"accel_trip":false,"mic_trip":false,"mmwave_trip":true,'
          '"ble_trip":false,"wifi_trip":false,"ble_nearby":15,'
          '"wifi_beacons":0,"fix":false,"sats":0,"lat":null,'
          '"lon":null,"lora":"NOT_YET"}';
      final e = FetchEvent.tryParseLine(line);
      expect(e, isNotNull);
      expect(e!.mmwaveTrip, isTrue);
      expect(e.bleNearby, 15);
    });

    test('malformed lines return null, never throw', () {
      expect(FetchEvent.tryParseLine(''), isNull);
      expect(FetchEvent.tryParseLine('not json at all'), isNull);
      expect(FetchEvent.tryParseLine('{"event":"FUSED",'), isNull);
      expect(FetchEvent.tryParseLine('[1,2,3]'), isNull);
      expect(FetchEvent.tryParseLine('{"event":"FUSED","mag_g":"x"}'),
          isNotNull); // bad mag_g is dropped, event still parses
      expect(
          FetchEvent.tryParseLine(
              '{"event":"FUSED","mag_g":"x"}')!.magG,
          isNull);
    });
  });

  group('FetchGpsStatus', () {
    test('heartbeat parses with and without fix', () {
      final noFix = FetchGpsStatus.tryParseJson(
          {'gps': 'status', 'fix': false, 'sats': 0});
      expect(noFix, isNotNull);
      expect(noFix!.gpsFix, isFalse);
      expect(noFix.sats, 0);
      expect(noFix.lat, isNull);

      final fixed = FetchGpsStatus.tryParseJson({
        'gps': 'status',
        'fix': true,
        'sats': 7,
        'lat': 35.1,
        'lon': -79.0,
      });
      expect(fixed, isNotNull);
      expect(fixed!.gpsFix, isTrue);
      expect(fixed.sats, 7);
      expect(fixed.lat, closeTo(35.1, 1e-9));
    });

    test('heartbeat line parses; non-heartbeat returns null', () {
      expect(
          FetchGpsStatus.tryParseLine(
              '{"gps":"status","fix":false,"sats":0}'),
          isNotNull);
      expect(
          FetchGpsStatus.tryParseLine(
              '{"event":"FUSED","mag_g":1.0}'),
          isNull);
      expect(FetchGpsStatus.tryParseLine('garbage'), isNull);
      expect(FetchGpsStatus.tryParseJson({'gps': 'other'}), isNull);
    });
  });
}
