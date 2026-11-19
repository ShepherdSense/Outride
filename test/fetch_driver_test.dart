/// Tests for the Fetch driver: UDP datagram filtering, bounded store,
/// GPS heartbeat handling, malformed counting, and per-sensor last-trip.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/models/fetch_event.dart';
import 'package:outride/services/fetch_driver.dart';

const String _fusedMmwave =
    '{"event":"FUSED","mag_g":1.025,"mic_rms":31772.0,'
    '"accel_trip":false,"mic_trip":false,"mmwave_trip":true,'
    '"ble_trip":false,"wifi_trip":false,"ble_nearby":15,'
    '"wifi_beacons":0,"fix":false,"sats":0,"lat":null,'
    '"lon":null,"lora":"NOT_YET"}';

const String _fusedBleOnly =
    '{"event":"FUSED","mag_g":1.02,"mic_rms":20000.0,'
    '"accel_trip":false,"mic_trip":false,"mmwave_trip":false,'
    '"ble_trip":true,"wifi_trip":false,"ble_nearby":18,'
    '"wifi_beacons":2,"fix":false,"sats":0,"lat":null,'
    '"lon":null,"lora":"NOT_YET"}';

const String _fusedWifiOnly =
    '{"event":"FUSED","mag_g":1.02,"mic_rms":25000.0,'
    '"accel_trip":false,"mic_trip":false,"mmwave_trip":false,'
    '"ble_trip":false,"wifi_trip":true,"ble_nearby":14,'
    '"wifi_beacons":5,"fix":false,"sats":0,"lat":null,'
    '"lon":null,"lora":"NOT_YET"}';

const String _fusedGpsFix =
    '{"event":"FUSED","mag_g":1.02,"mic_rms":10000.0,'
    '"accel_trip":false,"mic_trip":false,"mmwave_trip":true,'
    '"ble_trip":false,"wifi_trip":false,"ble_nearby":15,'
    '"wifi_beacons":3,"fix":true,"sats":7,'
    '"lat":35.123456,"lon":-79.012345,"lora":"NOT_YET"}';

void main() {
  group('FetchDriver datagrams', () {
    test('fused event datagram is ingested', () {
      final d = FetchDriver();
      d.datagramForTest(_fusedMmwave);
      expect(d.ingestedCount, 1);
      expect(d.events.length, 1);
      final e = d.events.first;
      expect(e.mmwaveTrip, isTrue);
      expect(e.bleNearby, 15);
      expect(e.gpsFix, isFalse);
      expect(d.latestTripped(FetchTripSensor.mmwave), isTrue);
      expect(d.latestTripped(FetchTripSensor.ble), isFalse);
    });

    test('BLE-only and Wi-Fi-only trip events land on the right sensor',
        () {
      final d = FetchDriver();
      d.datagramForTest(_fusedBleOnly);
      d.datagramForTest(_fusedWifiOnly);
      expect(d.ingestedCount, 2);
      expect(d.events.length, 2);
      // Newest first: wifi event is newest.
      expect(d.events.first.trippedSensors, [FetchTripSensor.wifi]);
      expect(d.events.last.trippedSensors, [FetchTripSensor.ble]);
      expect(d.lastTripAt(FetchTripSensor.ble), isNotNull);
      expect(d.lastTripAt(FetchTripSensor.wifi), isNotNull);
      expect(d.lastTripAt(FetchTripSensor.accel), isNull);
      expect(d.latestTripped(FetchTripSensor.wifi), isTrue);
      expect(d.latestTripped(FetchTripSensor.ble), isFalse);
    });

    test('GPS heartbeat updates latestGps; fixed event does too', () {
      final d = FetchDriver();
      expect(d.latestGps, isNull);
      d.datagramForTest('{"gps":"status","fix":false,"sats":0}');
      expect(d.latestGps, isNotNull);
      expect(d.latestGps!.gpsFix, isFalse);
      d.datagramForTest(_fusedGpsFix);
      expect(d.latestGps!.gpsFix, isTrue);
      expect(d.latestGps!.sats, 7);
      expect(d.latestGps!.lat, closeTo(35.123456, 1e-6));
      expect(d.latestGps!.lon, closeTo(-79.012345, 1e-6));
    });

    test('other drivers\' traffic passes by silently', () {
      final d = FetchDriver();
      d.datagramForTest(
          '{"type":"sensor_obs","obs":"RANGE","sensor":"lidar1","dist_m":12.4}');
      d.datagramForTest('{"type":"beacon","node":"esp32:1"}');
      d.datagramForTest('RANGE lidar1 12.4 45');
      d.datagramForTest('not json at all');
      d.datagramForTest('');
      expect(d.ingestedCount, 0);
      expect(d.malformedCount, 0);
      expect(d.events, isEmpty);
    });

    test('Fetch-shaped but unparseable datagrams count malformed', () {
      final d = FetchDriver();
      // A fix claim with a missing coordinate is contradictory.
      d.datagramForTest('{"event":"FUSED","fix":true,"lat":35.0}');
      d.datagramForTest(
          '{"event":"FUSED","fix":true,"lat":91.0,"lon":0.0}'); // fix without valid coords
      d.datagramForTest(
          '{"gps":"status","fix":true,"lat":200.0,"lon":0.0}'); // same, heartbeat
      expect(d.malformedCount, 3);
      expect(d.ingestedCount, 0);
      expect(d.events, isEmpty);
    });

    test('failed accel read still ingests its trip (B1, driver level)', () {
      final d = FetchDriver();
      d.datagramForTest(
          '{"event":"FUSED","mag_g":-1.0,"mic_rms":31772.0,'
          '"accel_trip":false,"mic_trip":false,"mmwave_trip":true,'
          '"ble_trip":false,"wifi_trip":false,"ble_nearby":15,'
          '"wifi_beacons":0,"fix":false,"sats":0,"lat":null,'
          '"lon":null,"lora":"NOT_YET"}');
      expect(d.malformedCount, 0);
      expect(d.ingestedCount, 1);
      expect(d.events.first.mmwaveTrip, isTrue);
      expect(d.events.first.magG, isNull);
      expect(d.latestTripped(FetchTripSensor.mmwave), isTrue);
    });

    test('a no-fix event clears the last known position (S2)', () {
      final d = FetchDriver();
      d.datagramForTest(_fusedGpsFix);
      expect(d.latestGps!.gpsFix, isTrue);
      expect(d.latestGps!.lat, closeTo(35.123456, 1e-6));
      // Same rule as a no-fix heartbeat: "no fix" means the position
      // is unknown, not "last known" — the stale position must not
      // outlive the fix that produced it.
      d.datagramForTest(_fusedMmwave);
      expect(d.latestGps, isNotNull);
      expect(d.latestGps!.gpsFix, isFalse);
      expect(d.latestGps!.lat, isNull);
      expect(d.latestGps!.lon, isNull);
      expect(d.latestGps!.sats, 0);
    });

    test('a no-fix heartbeat clears the last known position (S2)', () {
      final d = FetchDriver();
      d.datagramForTest(_fusedGpsFix);
      expect(d.latestGps!.gpsFix, isTrue);
      d.datagramForTest('{"gps":"status","fix":false,"sats":2}');
      expect(d.latestGps!.gpsFix, isFalse);
      expect(d.latestGps!.lat, isNull);
      expect(d.latestGps!.lon, isNull);
      expect(d.latestGps!.sats, 2);
    });

    test('unknown event verbs are ignored, not malformed', () {
      final d = FetchDriver();
      d.datagramForTest('{"event":"SOMETHING_ELSE","x":1}');
      d.datagramForTest('{"gps":"other"}');
      expect(d.malformedCount, 0);
      expect(d.ingestedCount, 0);
    });

    test('store caps at 100 events, newest first', () {
      final d = FetchDriver();
      for (var i = 0; i < 120; i++) {
        d.datagramForTest(_fusedMmwave);
      }
      expect(d.events.length, FetchDriver.maxStored);
      expect(d.ingestedCount, 120);
    });

    test('poll returns no link samples (display-only, no tripwire)', () async {
      final d = FetchDriver();
      d.datagramForTest(_fusedMmwave);
      final links = await d.poll();
      expect(links, isEmpty);
      d.dispose();
    });

    test('driver identity', () {
      final d = FetchDriver();
      expect(d.driverId, 'fetch');
      expect(d.label, 'FETCH');
      expect(d.isImplemented, isTrue);
      expect(d.emptyHint, contains('UDP 49160'));
    });
  });
}
