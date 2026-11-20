/// Fetch voice alerts — PURE logic, no TTS, fully unit-testable.
///
/// Spoken alerts carry a Fetch trip into the operator's hearing
/// protection (Comtacs) via the EUD's audio output, so an operator
/// clearing a structure hears a trip instead of looking at a screen.
///
/// HONESTY RULES (hard — standing Outride honest-scope rules, do not
/// weaken them):
///
/// 1. The ball's own sensors (mic, mmWave, BLE, Wi-Fi) CANNOT give a
///    bearing. Direction comes ONLY from positions: the ball's GPS fix
///    against the operator's GPS fix, or the recorded throw point
///    against the operator's current position. Never imply a sensor
///    "heard" a direction.
/// 2. The Fetch senses movement / presence — it can NEVER identify
///    someone as an enemy, a friendly, or a civilian, and it never
///    states armed status. Phrases stay neutral: "possible person",
///    "movement", "sound", "new radio", "new Wi-Fi" + position. Never
///    "enemy at ...", never any wording claiming identity or hostile
///    intent. The operator decides what a detection is. The mmWave
///    channel (LD2420 presence — something moving near the ball) is
///    the person-class channel, so it speaks "Possible person"; that
///    is a presence class, not an identity.
/// 3. NEVER invent a direction: with no ball position and no throw
///    point, the phrase has no direction words at all — just the
///    sensor phrase. The same holds under ~10 m from the operator:
///    at CQB ranges the bearing is dominated by GPS error (each fix
///    ±several m), and at 0 m the bearing of identical points is
///    atan2(0,0) = 0 ("north") — a direction invented where none
///    exists. Below ~10 m the alert speaks the sensor phrase only.
/// 4. No RSSI ranging: the event stream carries no RSSI fields
///    (ble_nearby / wifi_beacons are counts only), so there is no
///    honest range signal without positions. Nothing here promises
///    it.
///
/// Number rule (documented, consistent): distances are rounded
/// before speaking — nearest whole meter under 20 m, nearest 5 m
/// from 20–99 m, nearest 10 m at 100+ m. Whether the rounded
/// distance is spoken as words or as "about N meters" is decided
/// on the TRUE distance: true ≤ 20 m speaks as words ("ten
/// meters", "twenty meters"); above 20 m the rounded distance is
/// spoken as a numeral prefixed with "about" ("about 45 meters"),
/// because the rounding makes it an approximation, not a
/// measurement. Under ~10 m no direction or distance is spoken at
/// all (see rule 3).
library;

import 'dart:math' as math;

import '../models/fetch_event.dart';

/// Operator position with its capture time. Older than 60 s it is
/// stale and counts as unavailable — a direction built on a stale
/// operator position would point at where the operator WAS, not
/// where they are.
class OperatorPosition {
  const OperatorPosition({
    required this.lat,
    required this.lon,
    required this.at,
    this.accuracyM,
  });

  final double lat;
  final double lon;
  final DateTime at;

  /// Horizontal accuracy in meters, when known. Live-stream fixes
  /// carry it (the accuracy ring on the map); one-shot captures
  /// leave it null — the marker draws without a ring.
  final double? accuracyM;

  /// True when this fix is fresh enough to build a direction from.
  bool freshAt(DateTime now) =>
      now.difference(at).abs() <= const Duration(seconds: 60);
}

/// Throw point: operator position (+ heading, when known) captured
/// at the moment the ball was thrown. Session-only, never persisted.
/// Direction/distance from a throw point are relative to where the
/// ball was thrown, NOT a live fix — the phrase says so.
class ThrowPoint {
  const ThrowPoint({
    required this.lat,
    required this.lon,
    required this.at,
    this.heading,
  });

  final double lat;
  final double lon;
  final DateTime at;

  /// Compass heading (degrees, clockwise from north) at throw time,
  /// or null when no heading was available.
  final double? heading;
}

/// Pure phrase + throttle logic for Fetch voice alerts. Holds only
/// throttle state (last spoken time per sensor); no audio, no clock
/// of its own — callers pass `now`, so tests drive it exactly.
class FetchVoiceAlerts {
  /// Repeat suppression window for the SAME sensor.
  static const Duration repeatWindow = Duration(seconds: 10);

  /// Below this true distance the phrase carries no direction or
  /// distance at all — just the sensor phrase. At CQB ranges the
  /// bearing is dominated by GPS error (each fix ±several m), so a
  /// confident "north, three meters" would be noise presented as
  /// fact; at 0 m the bearing of identical points is atan2(0,0) =
  /// 0, an invented direction. See the file doc, rule 3.
  static const double minSpokenDirectionDistanceM = 10.0;

  /// Priority when one event trips several sensors at once: the
  /// person-class channel speaks first, then the physical channels,
  /// then the radio-presence channels.
  static const List<FetchTripSensor> sensorPriority = [
    FetchTripSensor.mmwave,
    FetchTripSensor.accel,
    FetchTripSensor.mic,
    FetchTripSensor.ble,
    FetchTripSensor.wifi,
  ];

  final Map<FetchTripSensor, DateTime> _lastSpoken = {};

  /// Short spoken phrase per sensor channel. A few words each; the
  /// mmWave channel is the person-class channel ("Possible person").
  static String sensorPhrase(FetchTripSensor sensor) => switch (sensor) {
        FetchTripSensor.accel => 'Movement',
        FetchTripSensor.mic => 'Sound',
        FetchTripSensor.mmwave => 'Possible person',
        FetchTripSensor.ble => 'New radio',
        FetchTripSensor.wifi => 'New Wi-Fi',
      };

  /// True bearing in degrees (0–360, clockwise from north) from
  /// ([fromLat], [fromLon]) to ([toLat], [toLon]).
  static double bearingDegrees(
      double fromLat, double fromLon, double toLat, double toLon) {
    final p1 = fromLat * math.pi / 180.0;
    final p2 = toLat * math.pi / 180.0;
    final dLon = (toLon - fromLon) * math.pi / 180.0;
    final y = math.sin(dLon) * math.cos(p2);
    final x = math.cos(p1) * math.sin(p2) -
        math.sin(p1) * math.cos(p2) * math.cos(dLon);
    return (math.atan2(y, x) * 180.0 / math.pi + 360.0) % 360.0;
  }

  /// Great-circle distance in meters (haversine). Field distances
  /// are tens of meters; haversine and the equirectangular
  /// projection agree to centimeters there.
  static double distanceMeters(
      double fromLat, double fromLon, double toLat, double toLon) {
    const r = 6371000.0;
    final p1 = fromLat * math.pi / 180.0;
    final p2 = toLat * math.pi / 180.0;
    final dp = p2 - p1;
    final dl = (toLon - fromLon) * math.pi / 180.0;
    final a = math.sin(dp / 2) * math.sin(dp / 2) +
        math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
    return 2 * r * math.asin(math.sqrt(a.clamp(0.0, 1.0)));
  }

  /// Distance rounded for speech: nearest whole meter under 20 m,
  /// nearest 5 m from 20–99 m, nearest 10 m at 100+ m.
  static int roundedDistanceMeters(double meters) {
    final m = meters.clamp(0.0, double.infinity);
    if (m < 20) return m.round();
    if (m < 100) return (m / 5).round() * 5;
    return (m / 10).round() * 10;
  }

  /// Rounded distance as spoken words. True distance ≤ 20 m as
  /// words ("ten meters"); above 20 m as a numeral prefixed with
  /// "about" ("about 45 meters"). The words-vs-"about" decision is
  /// made on the TRUE distance, not the rounded one: a true 22.4 m
  /// rounds to 20 but is not "twenty meters" exact — it is
  /// "about 20 meters". See the file doc for the rule.
  static String distanceWords(double meters) {
    final r = roundedDistanceMeters(meters);
    if (meters <= 20) {
      const words = [
        'zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven',
        'eight', 'nine', 'ten', 'eleven', 'twelve', 'thirteen',
        'fourteen', 'fifteen', 'sixteen', 'seventeen', 'eighteen',
        'nineteen', 'twenty',
      ];
      return '${words[r]} ${r == 1 ? 'meter' : 'meters'}';
    }
    return 'about $r meters';
  }

  static const List<String> _relativeTerms = [
    'ahead',
    'ahead right',
    'right',
    'behind right',
    'behind',
    'behind left',
    'left',
    'ahead left',
  ];

  static const List<String> _cardinalTerms = [
    'north',
    'north-east',
    'east',
    'south-east',
    'south',
    'south-west',
    'west',
    'north-west',
  ];

  /// Relative direction term for a bearing seen from [heading]
  /// (both degrees, clockwise from north). 8 terms, 45° sectors
  /// centred on ahead / right / behind / left.
  static String relativeDirection(double bearing, double heading) {
    final rel = (bearing - heading + 360.0) % 360.0;
    return _relativeTerms[((rel + 22.5) / 45.0).floor() % 8];
  }

  /// Cardinal direction term for a true bearing, used when no
  /// operator heading is available. 8 terms, 45° sectors centred
  /// on the cardinal / intercardinal points.
  static String cardinalDirection(double bearing) =>
      _cardinalTerms[((bearing + 22.5) / 45.0).floor() % 8];

  /// Full spoken phrase for [sensor] on [event].
  ///
  /// Position sources, in priority order:
  /// (a) ball GPS fix in the event + a fresh operator position —
  ///     direction/distance are live, ball-to-operator;
  /// (b) recorded [throwPoint] + a fresh operator position —
  ///     direction/distance are relative to the throw point and the
  ///     phrase says "from throw point" so the operator knows it is
  ///     not a live fix;
  /// (c) neither — just the sensor phrase, no direction words at
  ///     all (never invent a direction).
  ///
  /// When [heading] is given, the direction is relative to the
  /// operator's facing ("ahead left"); when null, it is cardinal
  /// ("north-east"). [now] defaults to [DateTime.now] and is used
  /// only for the operator-position freshness check.
  static String buildPhrase(
    FetchEvent event,
    FetchTripSensor sensor, {
    OperatorPosition? operatorPosition,
    double? heading,
    ThrowPoint? throwPoint,
    DateTime? now,
  }) {
    final phrase = sensorPhrase(sensor);
    final at = now ?? DateTime.now();
    final op = operatorPosition != null && operatorPosition.freshAt(at)
        ? operatorPosition
        : null;
    if (op == null) return phrase;

    double? targetLat, targetLon;
    var fromThrowPoint = false;
    if (event.gpsFix && event.lat != null && event.lon != null) {
      targetLat = event.lat;
      targetLon = event.lon;
    } else if (throwPoint != null) {
      targetLat = throwPoint.lat;
      targetLon = throwPoint.lon;
      fromThrowPoint = true;
    }
    if (targetLat == null || targetLon == null) return phrase;

    final bearing = bearingDegrees(op.lat, op.lon, targetLat, targetLon);
    final distance = distanceMeters(op.lat, op.lon, targetLat, targetLon);
    // Under ~10 m the bearing is dominated by GPS error and at 0 m
    // it is atan2(0,0) — an invented direction. Speak the bare
    // sensor phrase instead (rule 3).
    if (distance < minSpokenDirectionDistanceM) return phrase;
    final direction = heading == null
        ? cardinalDirection(bearing)
        : relativeDirection(bearing, heading);
    final dist = distanceWords(distance);
    if (fromThrowPoint) {
      return '$phrase, from throw point, $direction, $dist';
    }
    return '$phrase, $direction, $dist';
  }

  /// The phrase to speak for [event] right now, or null when nothing
  /// should be spoken.
  ///
  /// Throttle: the first trip for a sensor speaks immediately;
  /// repeats of the SAME sensor within [repeatWindow] are suppressed;
  /// a DIFFERENT sensor type breaking through speaks immediately
  /// (and resets nothing for the other sensor); after the window a
  /// repeat speaks again. Among several tripped sensors the highest
  /// [sensorPriority] unsuppressed one speaks; an event with no trips
  /// never speaks. Calling this with a phrase to speak records the
  /// sensor's spoken time — a null return records nothing.
  String? nextPhrase(
    FetchEvent event, {
    required DateTime now,
    OperatorPosition? operatorPosition,
    double? heading,
    ThrowPoint? throwPoint,
  }) {
    for (final sensor in sensorPriority) {
      if (!event.tripped(sensor)) continue;
      final last = _lastSpoken[sensor];
      if (last != null && now.difference(last) < repeatWindow) continue;
      _lastSpoken[sensor] = now;
      return buildPhrase(
        event,
        sensor,
        operatorPosition: operatorPosition,
        heading: heading,
        throwPoint: throwPoint,
        now: now,
      );
    }
    return null;
  }

  /// Test/support hook: when [sensor] last spoke, or null.
  DateTime? lastSpokenAt(FetchTripSensor sensor) => _lastSpoken[sensor];
}
