/// Tests for Fetch voice alerts (pure logic): sensor phrases,
/// bearing/distance math, cardinal vs relative direction, position
/// fallbacks, the throw-point path, and the per-sensor throttle.
///
/// Coordinate fixtures: the operator stands at 35.0, -79.0. A ball
/// 0.00011° north is ~12 m away (0.00011 * 110540 ≈ 12.2 m) — just
/// outside the ~10 m bare-phrase cutoff, so direction fixtures use
/// it; a ball 0.000045° north is ~5 m away and speaks the bare
/// phrase. A ball 0.0005° east is ~46 m away
/// (0.0005 * 111320 * cos 35° ≈ 45.6 m).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/models/fetch_event.dart';
import 'package:outride/services/fetch_voice_alerts.dart';

const _opLat = 35.0;
const _opLon = -79.0;

FetchEvent _event({
  bool accel = false,
  bool mic = false,
  bool mmwave = false,
  bool ble = false,
  bool wifi = false,
  bool gpsFix = false,
  double? lat,
  double? lon,
  DateTime? at,
}) =>
    FetchEvent(
      receivedAt: at ?? DateTime(2026, 11, 12, 12, 0, 0),
      accelTrip: accel,
      micTrip: mic,
      mmwaveTrip: mmwave,
      bleTrip: ble,
      wifiTrip: wifi,
      gpsFix: gpsFix,
      lat: lat,
      lon: lon,
    );

OperatorPosition _op({DateTime? at}) => OperatorPosition(
      lat: _opLat,
      lon: _opLon,
      // Fresh by default: buildPhrase compares against the real
      // clock unless the test passes `now` explicitly.
      at: at ?? DateTime.now(),
    );

void main() {
  group('sensor phrases', () {
    test('each sensor has its short neutral phrase', () {
      expect(FetchVoiceAlerts.sensorPhrase(FetchTripSensor.accel),
          'Movement');
      expect(
          FetchVoiceAlerts.sensorPhrase(FetchTripSensor.mic), 'Sound');
      expect(FetchVoiceAlerts.sensorPhrase(FetchTripSensor.mmwave),
          'Possible person');
      expect(
          FetchVoiceAlerts.sensorPhrase(FetchTripSensor.ble), 'New radio');
      expect(FetchVoiceAlerts.sensorPhrase(FetchTripSensor.wifi),
          'New Wi-Fi');
    });

    test('mmWave speaks "Possible person" with direction and distance',
        () {
      final e = _event(
          mmwave: true, gpsFix: true, lat: _opLat + 0.00011, lon: _opLon);
      expect(
        FetchVoiceAlerts.buildPhrase(e, FetchTripSensor.mmwave,
            operatorPosition: _op()),
        'Possible person, north, twelve meters',
      );
    });

    test('wording rule: no phrase claims identity or hostile intent',
        () {
      const banned = ['enemy', 'friendly', 'civilian', 'armed'];
      for (final s in FetchTripSensor.values) {
        final e = _event(mmwave: s == FetchTripSensor.mmwave);
        // Phrase with no position at all — the bare sensor phrase.
        final bare = FetchVoiceAlerts.buildPhrase(e, s);
        for (final word in banned) {
          expect(bare.toLowerCase(), isNot(contains(word)),
              reason: '$s phrase must never say "$word"');
        }
        // Phrase with a full position — direction words included.
        final e2 = _event(
            mmwave: true, gpsFix: true, lat: _opLat + 0.00011, lon: _opLon);
        final full = FetchVoiceAlerts.buildPhrase(e2, s,
            operatorPosition: _op(), heading: 0);
        for (final word in banned) {
          expect(full.toLowerCase(), isNot(contains(word)),
              reason: '$s phrase with position must never say "$word"');
        }
      }
    });
  });

  group('bearing and distance math', () {
    test('due north: bearing 0, ~10 m', () {
      expect(
          FetchVoiceAlerts.bearingDegrees(
              _opLat, _opLon, _opLat + 0.00009, _opLon),
          closeTo(0.0, 0.5));
      expect(
          FetchVoiceAlerts.distanceMeters(
              _opLat, _opLon, _opLat + 0.00009, _opLon),
          closeTo(9.95, 0.5));
    });

    test('due east: bearing 90, ~46 m', () {
      expect(
          FetchVoiceAlerts.bearingDegrees(
              _opLat, _opLon, _opLat, _opLon + 0.0005),
          closeTo(90.0, 0.5));
      expect(
          FetchVoiceAlerts.distanceMeters(
              _opLat, _opLon, _opLat, _opLon + 0.0005),
          closeTo(45.6, 1.0));
    });

    test('due south and west bearings', () {
      expect(
          FetchVoiceAlerts.bearingDegrees(
              _opLat, _opLon, _opLat - 0.00009, _opLon),
          closeTo(180.0, 0.5));
      expect(
          FetchVoiceAlerts.bearingDegrees(
              _opLat, _opLon, _opLat, _opLon - 0.0005),
          closeTo(270.0, 0.5));
    });

    test('distance rounding: whole under 20, 5s to 99, 10s at 100+', () {
      expect(FetchVoiceAlerts.roundedDistanceMeters(9.4), 9);
      expect(FetchVoiceAlerts.roundedDistanceMeters(10.4), 10);
      expect(FetchVoiceAlerts.roundedDistanceMeters(22.4), 20);
      expect(FetchVoiceAlerts.roundedDistanceMeters(23.0), 25);
      expect(FetchVoiceAlerts.roundedDistanceMeters(97.0), 95);
      expect(FetchVoiceAlerts.roundedDistanceMeters(149.0), 150);
    });

    test('distance words: 1-20 as words, above 20 "about N meters"', () {
      expect(FetchVoiceAlerts.distanceWords(1.0), 'one meter');
      expect(FetchVoiceAlerts.distanceWords(10.0), 'ten meters');
      expect(FetchVoiceAlerts.distanceWords(20.0), 'twenty meters');
      expect(FetchVoiceAlerts.distanceWords(45.6), 'about 45 meters');
      expect(FetchVoiceAlerts.distanceWords(150.0), 'about 150 meters');
    });

    test('distance words: the words-vs-"about" call uses the TRUE distance',
        () {
      // True 22.4 m rounds to 20, but it is not "twenty meters"
      // exact — it is "about 20 meters".
      expect(FetchVoiceAlerts.distanceWords(22.4), 'about 20 meters');
      expect(FetchVoiceAlerts.distanceWords(20.4), 'about 20 meters');
      // True 19.9 m rounds to 20 and IS within the words range.
      expect(FetchVoiceAlerts.distanceWords(19.9), 'twenty meters');
      expect(FetchVoiceAlerts.distanceWords(20.0), 'twenty meters');
    });
  });

  group('direction terms', () {
    test('cardinal fallback when heading is null', () {
      expect(FetchVoiceAlerts.cardinalDirection(0), 'north');
      expect(FetchVoiceAlerts.cardinalDirection(45), 'north-east');
      expect(FetchVoiceAlerts.cardinalDirection(90), 'east');
      expect(FetchVoiceAlerts.cardinalDirection(135), 'south-east');
      expect(FetchVoiceAlerts.cardinalDirection(180), 'south');
      expect(FetchVoiceAlerts.cardinalDirection(225), 'south-west');
      expect(FetchVoiceAlerts.cardinalDirection(270), 'west');
      expect(FetchVoiceAlerts.cardinalDirection(315), 'north-west');
      expect(FetchVoiceAlerts.cardinalDirection(359), 'north');
    });

    test('relative terms for headings 0/90/180/270 vs a north bearing',
        () {
      // Ball due north (bearing 0) of the operator.
      expect(FetchVoiceAlerts.relativeDirection(0, 0), 'ahead');
      expect(FetchVoiceAlerts.relativeDirection(0, 90), 'left');
      expect(FetchVoiceAlerts.relativeDirection(0, 180), 'behind');
      expect(FetchVoiceAlerts.relativeDirection(0, 270), 'right');
      // Diagonal: bearing 45, facing north -> ahead right.
      expect(FetchVoiceAlerts.relativeDirection(45, 0), 'ahead right');
      expect(FetchVoiceAlerts.relativeDirection(45, 90), 'ahead left');
    });

    test('GPS path: relative when heading known, cardinal when not',
        () {
      final e = _event(
          accel: true, gpsFix: true, lat: _opLat + 0.00011, lon: _opLon);
      expect(
        FetchVoiceAlerts.buildPhrase(e, FetchTripSensor.accel,
            operatorPosition: _op(), heading: 0),
        'Movement, ahead, twelve meters',
      );
      expect(
        FetchVoiceAlerts.buildPhrase(e, FetchTripSensor.accel,
            operatorPosition: _op()),
        'Movement, north, twelve meters',
      );
      // Facing east (90) with the ball north: it is on the left.
      expect(
        FetchVoiceAlerts.buildPhrase(e, FetchTripSensor.accel,
            operatorPosition: _op(), heading: 90),
        'Movement, left, twelve meters',
      );
    });

    test('east ball at ~46 m speaks "about 45 meters"', () {
      final e = _event(
          mic: true, gpsFix: true, lat: _opLat, lon: _opLon + 0.0005);
      expect(
        FetchVoiceAlerts.buildPhrase(e, FetchTripSensor.mic,
            operatorPosition: _op()),
        'Sound, east, about 45 meters',
      );
    });
  });

  group('position fallbacks', () {
    test('no fix and no throw point: phrase has NO direction words',
        () {
      final e = _event(accel: true);
      final phrase =
          FetchVoiceAlerts.buildPhrase(e, FetchTripSensor.accel);
      expect(phrase, 'Movement');
      expect(phrase, isNot(contains('north')));
      expect(phrase, isNot(contains('ahead')));
      expect(phrase, isNot(contains('meters')));
      expect(phrase, isNot(contains('meter')));
    });

    test('no fix and no throw point: mmWave is just "Possible person"',
        () {
      final e = _event(mmwave: true);
      expect(FetchVoiceAlerts.buildPhrase(e, FetchTripSensor.mmwave),
          'Possible person');
    });

    test('stale operator position (> 60 s) counts as unavailable', () {
      final e = _event(
          accel: true, gpsFix: true, lat: _opLat + 0.00011, lon: _opLon);
      final stale = _op(at: DateTime(2026, 11, 12, 11, 58, 59));
      expect(
        FetchVoiceAlerts.buildPhrase(e, FetchTripSensor.accel,
            operatorPosition: stale,
            now: DateTime(2026, 11, 12, 12, 0, 0)),
        'Movement',
      );
      // 60 s exactly is still fresh.
      final edge = _op(at: DateTime(2026, 11, 12, 11, 59, 0));
      expect(
        FetchVoiceAlerts.buildPhrase(e, FetchTripSensor.accel,
            operatorPosition: edge,
            now: DateTime(2026, 11, 12, 12, 0, 0)),
        'Movement, north, twelve meters',
      );
    });

    test('coincident positions speak the bare phrase, no invented bearing',
        () {
      // Ball and operator at the same coordinates: the bearing of
      // identical points is atan2(0,0) = 0 ("north") and the
      // distance is zero — a direction invented where none exists.
      final e = _event(
          mmwave: true, gpsFix: true, lat: _opLat, lon: _opLon);
      final phrase = FetchVoiceAlerts.buildPhrase(
          e, FetchTripSensor.mmwave,
          operatorPosition: _op());
      expect(phrase, 'Possible person');
      expect(phrase, isNot(contains('north')));
      expect(phrase, isNot(contains('meters')));
    });

    test('ball ~5 m away speaks the bare phrase (GPS error dominates)',
        () {
      // ~5 m north (0.000045° ≈ 4.97 m): at CQB ranges the bearing
      // is dominated by GPS error, so no direction is spoken.
      final e = _event(
          accel: true, gpsFix: true, lat: _opLat + 0.000045, lon: _opLon);
      expect(
        FetchVoiceAlerts.buildPhrase(e, FetchTripSensor.accel,
            operatorPosition: _op()),
        'Movement',
      );
    });

    test('ball ~12 m away speaks with direction', () {
      final e = _event(
          accel: true, gpsFix: true, lat: _opLat + 0.00011, lon: _opLon);
      expect(
        FetchVoiceAlerts.buildPhrase(e, FetchTripSensor.accel,
            operatorPosition: _op()),
        'Movement, north, twelve meters',
      );
    });

    test('throw point ~5 m away speaks the bare phrase too', () {
      final tp = ThrowPoint(
        lat: _opLat + 0.000045,
        lon: _opLon,
        at: DateTime(2026, 11, 12, 11, 59, 0),
      );
      final e = _event(accel: true); // no GPS fix on the ball
      expect(
        FetchVoiceAlerts.buildPhrase(e, FetchTripSensor.accel,
            operatorPosition: _op(), throwPoint: tp),
        'Movement',
      );
    });

    test('throw-point path says "from throw point"', () {
      final tp = ThrowPoint(
        lat: _opLat + 0.00011,
        lon: _opLon,
        at: DateTime(2026, 11, 12, 11, 59, 0),
      );
      final e = _event(accel: true); // no GPS fix on the ball
      expect(
        FetchVoiceAlerts.buildPhrase(e, FetchTripSensor.accel,
            operatorPosition: _op(), heading: 0, throwPoint: tp),
        'Movement, from throw point, ahead, twelve meters',
      );
      expect(
        FetchVoiceAlerts.buildPhrase(e, FetchTripSensor.accel,
            operatorPosition: _op(), throwPoint: tp),
        'Movement, from throw point, north, twelve meters',
      );
    });

    test('live GPS fix beats the throw point', () {
      final tp = ThrowPoint(
        lat: _opLat - 0.00011, // south — would say "behind"
        lon: _opLon,
        at: DateTime(2026, 11, 12, 11, 59, 0),
      );
      final e = _event(
          accel: true, gpsFix: true, lat: _opLat + 0.00011, lon: _opLon);
      expect(
        FetchVoiceAlerts.buildPhrase(e, FetchTripSensor.accel,
            operatorPosition: _op(), heading: 0, throwPoint: tp),
        'Movement, ahead, twelve meters',
      );
    });

    test('throw point without operator position: no direction', () {
      final tp = ThrowPoint(
        lat: _opLat + 0.00011,
        lon: _opLon,
        at: DateTime(2026, 11, 12, 11, 59, 0),
      );
      final e = _event(accel: true);
      expect(
        FetchVoiceAlerts.buildPhrase(e, FetchTripSensor.accel,
            throwPoint: tp),
        'Movement',
      );
    });
  });

  group('throttle (nextPhrase)', () {
    test('same sensor twice within 10 s: second suppressed', () {
      final alerts = FetchVoiceAlerts();
      final t0 = DateTime(2026, 11, 12, 12, 0, 0);
      final e = _event(accel: true, at: t0);
      expect(alerts.nextPhrase(e, now: t0), 'Movement');
      expect(alerts.nextPhrase(_event(accel: true, at: t0.add(const Duration(seconds: 5))), now: t0.add(const Duration(seconds: 5))), isNull);
    });

    test('different sensor within 10 s speaks immediately', () {
      final alerts = FetchVoiceAlerts();
      final t0 = DateTime(2026, 11, 12, 12, 0, 0);
      expect(alerts.nextPhrase(_event(accel: true), now: t0), 'Movement');
      expect(
          alerts.nextPhrase(_event(mic: true),
              now: t0.add(const Duration(seconds: 5))),
          'Sound');
      // ...and the first sensor is still suppressed: the breakthrough
      // reset nothing for it.
      expect(
          alerts.nextPhrase(_event(accel: true),
              now: t0.add(const Duration(seconds: 6))),
          isNull);
    });

    test('same sensor after 10 s speaks again', () {
      final alerts = FetchVoiceAlerts();
      final t0 = DateTime(2026, 11, 12, 12, 0, 0);
      expect(alerts.nextPhrase(_event(accel: true), now: t0), 'Movement');
      expect(
          alerts.nextPhrase(_event(accel: true),
              now: t0.add(const Duration(seconds: 10))),
          'Movement');
    });

    test('multi-sensor event speaks the person-class channel first',
        () {
      final alerts = FetchVoiceAlerts();
      final t0 = DateTime(2026, 11, 12, 12, 0, 0);
      final e = _event(accel: true, mmwave: true, mic: true);
      expect(alerts.nextPhrase(e, now: t0), 'Possible person');
      // The other tripped sensors were not spoken: a follow-up event
      // with only accel still speaks (its own throttle is untouched).
      expect(alerts.nextPhrase(_event(accel: true), now: t0), 'Movement');
    });

    test('event with no trips never speaks', () {
      final alerts = FetchVoiceAlerts();
      expect(
          alerts.nextPhrase(_event(),
              now: DateTime(2026, 11, 12, 12, 0, 0)),
          isNull);
    });
  });
}
