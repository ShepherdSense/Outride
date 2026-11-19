/// "The Fetch" — the throwable sensor ball — fused-event model.
///
/// The ball (ESP32-S3, bench sketch `sensor-ball-poc-bench.ino`) emits ONE
/// fused JSON event per trigger, today over serial, later over LoRa:
///
///   {"event":"FUSED","mag_g":1.02,"mic_rms":31772.0,
///    "accel_trip":false,"mic_trip":false,"mmwave_trip":true,
///    "ble_trip":false,"wifi_trip":false,
///    "ble_nearby":15,"wifi_beacons":0,
///    "fix":false,"sats":0,"lat":null,"lon":null,"lora":"NOT_YET"}
///
/// Plus a 10 s heartbeat: {"gps":"status","fix":false,"sats":0}
/// (adds lat/lon when fixed).
///
/// Sensor facts (bench-verified 2026-11-12): BMI160 accel (I2C addr 0x69,
/// SAO high), INMP441 mic (RMS on 24-bit samples, trip threshold 150000),
/// HLK-LD2420 mmWave OT1, GY-NEO6MV2 GPS on UART1 GPIO 41/42 @9600.
/// BLE nearby = presence count only, never identity; Wi-Fi beacons =
/// passive scan count, never joins a network. BLE/Wi-Fi TRIPWIRES learn
/// the transmitters around the ball in the first two radio scans after
/// boot (~10 s; scans run ~5 s apart) — baseline of addresses + RSSI —
/// and trip when a NEW transmitter appears or a known one's RSSI jumps
/// by more than 15 dB. Listen-only throughout — never joins, connects,
/// or impersonates; the ball watches devices (addresses), never who
/// owns them.
///
/// HONEST SCOPE: this is presence/movement data from a ball that hears,
/// feels, and sees motion and reports its own position. Never identity,
/// never a camera feed, never fire-control. Parsing is LENIENT BY
/// DESIGN (same contract as SensorProtocol): malformed input is skipped,
/// never thrown — a chatty broken sender must not take down ingest.
/// Unknown fields are ignored; a future sketch revision must not break
/// today's app.
library;

import 'dart:convert';

/// The five tripwire channels on the ball.
enum FetchTripSensor {
  /// BMI160 |mag − 1g| above 0.35 g.
  accel,

  /// INMP441 RMS above 150000 (24-bit samples).
  mic,

  /// HLK-LD2420 OT1 presence output high.
  mmwave,

  /// New BLE advertiser, or a known one's RSSI jumped > 15 dB.
  ble,

  /// New Wi-Fi BSSID, or a known one's RSSI jumped > 15 dB.
  wifi,
}

/// One fused event from the ball.
class FetchEvent {
  const FetchEvent({
    required this.receivedAt,
    this.magG,
    this.micRms,
    this.accelTrip = false,
    this.micTrip = false,
    this.mmwaveTrip = false,
    this.bleTrip = false,
    this.wifiTrip = false,
    this.bleNearby,
    this.wifiBeacons,
    this.gpsFix = false,
    this.sats,
    this.lat,
    this.lon,
    this.lora,
  });

  /// When Outride received it (the ball sends no timestamp; the
  /// sketch's events are real-time, so receive time is the event time).
  final DateTime receivedAt;

  /// |acceleration| magnitude in g. ~1.0 at rest.
  final double? magG;

  /// INMP441 RMS on 24-bit samples. Trip threshold 150000.
  final double? micRms;

  final bool accelTrip;
  final bool micTrip;
  final bool mmwaveTrip;

  /// BLE tripwire: new advertiser, or RSSI jump > 15 dB.
  final bool bleTrip;

  /// Wi-Fi tripwire: new BSSID, or RSSI jump > 15 dB.
  final bool wifiTrip;

  /// BLE advertisers seen in this snapshot (presence count only).
  final int? bleNearby;

  /// Wi-Fi beacons seen in this snapshot (passive scan count).
  final int? wifiBeacons;

  /// GPS fix at event time (false = no fix; lat/lon are null then).
  final bool gpsFix;

  /// Satellites in view at event time.
  final int? sats;

  /// Ball position (WGS-84) when fixed. Null = no fix; never 0,0.
  final double? lat;
  final double? lon;

  /// Link the event arrived on ("NOT_YET" while the bench runs over
  /// serial; a LoRa link name later). Informational only.
  final String? lora;

  /// Which tripwires fired on this event, in display order.
  List<FetchTripSensor> get trippedSensors {
    final out = <FetchTripSensor>[];
    if (accelTrip) out.add(FetchTripSensor.accel);
    if (micTrip) out.add(FetchTripSensor.mic);
    if (mmwaveTrip) out.add(FetchTripSensor.mmwave);
    if (bleTrip) out.add(FetchTripSensor.ble);
    if (wifiTrip) out.add(FetchTripSensor.wifi);
    return out;
  }

  bool get anyTrip => trippedSensors.isNotEmpty;

  bool tripped(FetchTripSensor sensor) => switch (sensor) {
        FetchTripSensor.accel => accelTrip,
        FetchTripSensor.mic => micTrip,
        FetchTripSensor.mmwave => mmwaveTrip,
        FetchTripSensor.ble => bleTrip,
        FetchTripSensor.wifi => wifiTrip,
      };

  /// Mic RMS as a fraction of the 150000 trip line (for the gauge).
  /// Null when the event carries no mic reading.
  double? get micRmsVsTrip =>
      micRms == null ? null : (micRms! / micTripThreshold).clamp(0.0, 4.0);

  /// Trip threshold for the INMP441 RMS (24-bit samples).
  static const double micTripThreshold = 150000.0;

  /// Parse one decoded-JSON map. Returns null when it is not a Fetch
  /// fused event, or when a fix claim has no valid coordinates.
  /// Out-of-range gauge values (mag_g / mic_rms) drop the FIELD,
  /// never the event: the live sketch emits mag_g -1.000 when the
  /// BMI160 read fails, and that event may carry the trip report the
  /// operator most needs. Never throws. Unknown fields are ignored.
  static FetchEvent? tryParseJson(Map<String, dynamic> j,
      {DateTime? receivedAt}) {
    try {
      return _parse(j, receivedAt ?? DateTime.now());
    } catch (_) {
      return null;
    }
  }

  /// Parse one JSON text line (serial / UDP datagram body). Returns
  /// null when it is not a Fetch fused event. Never throws.
  static FetchEvent? tryParseLine(String line, {DateTime? receivedAt}) {
    final t = line.trim();
    if (!t.startsWith('{')) return null;
    try {
      final j = jsonDecode(t);
      if (j is! Map<String, dynamic>) return null;
      return tryParseJson(j, receivedAt: receivedAt);
    } catch (_) {
      return null;
    }
  }

  static FetchEvent? _parse(Map<String, dynamic> j, DateTime now) {
    if ('${j['event']}'.toUpperCase() != 'FUSED') return null;

    // A corrupt or out-of-range gauge value drops the FIELD, never
    // the event (see the doc on tryParseJson): a failed accel read
    // must not delete a real trip report from another sensor.
    final magG = _ranged(_fin(j['mag_g']), 0, 50);
    final micRms = _ranged(_fin(j['mic_rms']), 0, 100000000);

    var gpsFix = _bool(j['fix']);
    double? lat, lon;
    final la = j['lat'];
    final lo = j['lon'];
    // A position without a fix is not a position: lat/lon are only
    // accepted when the fix flag says fixed. Stale coordinates from
    // before the fix was lost must never be plotted.
    //
    // Conversely, a fix claim WITHOUT valid coordinates is
    // contradictory data — reject the event rather than showing a
    // "FIX" with nowhere to point at.
    if (gpsFix) {
      if (la is! num ||
          lo is! num ||
          !la.isFinite ||
          !lo.isFinite ||
          la.abs() > 90 ||
          lo.abs() > 180) {
        return null;
      }
      if (la != 0 || lo != 0) {
        lat = la.toDouble();
        lon = lo.toDouble();
      } else {
        // (0, 0) is a null-island lie, not a position: drop it — and
        // drop the fix claim with it, so no consumer can read "FIX"
        // with nowhere to point at.
        gpsFix = false;
      }
    }

    final sats = j['sats'];
    final ble = j['ble_nearby'];
    final wifi = j['wifi_beacons'];
    return FetchEvent(
      receivedAt: now,
      magG: magG,
      micRms: micRms,
      accelTrip: _bool(j['accel_trip']),
      micTrip: _bool(j['mic_trip']),
      mmwaveTrip: _bool(j['mmwave_trip']),
      bleTrip: _bool(j['ble_trip']),
      wifiTrip: _bool(j['wifi_trip']),
      bleNearby: ble is num && ble.isFinite ? ble.toInt().clamp(0, 10000) : null,
      wifiBeacons:
          wifi is num && wifi.isFinite ? wifi.toInt().clamp(0, 10000) : null,
      gpsFix: gpsFix,
      sats: sats is num && sats.isFinite ? sats.toInt().clamp(0, 64) : null,
      lat: lat,
      lon: lon,
      lora: j['lora'] is String && (j['lora'] as String).isNotEmpty
          ? '${j['lora']}'
          : null,
    );
  }

  static double? _fin(dynamic v) =>
      v is num && v.isFinite ? v.toDouble() : null;

  /// Keep [v] when it lies in [lo]..[hi]; otherwise null. The caller
  /// keeps the event and its trip flags — only the gauge field is lost.
  static double? _ranged(double? v, double lo, double hi) =>
      v == null || v < lo || v > hi ? null : v;

  /// Booleans, lenient: true/false, 1/0, "true"/"false". Missing or
  /// anything else = false (no trip reported). Older sketch revisions
  /// have no ble_trip/wifi_trip fields at all — those events predate
  /// the radio tripwires, so "not reported" is the honest read.
  static bool _bool(dynamic v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) return v.toLowerCase() == 'true' || v == '1';
    return false;
  }
}

/// The ball's 10 s GPS heartbeat: {"gps":"status","fix":...,"sats":...}.
/// Carries position when fixed; nulls when not. Same lenient contract
/// as [FetchEvent]: malformed input is skipped, never thrown.
class FetchGpsStatus {
  const FetchGpsStatus({
    required this.receivedAt,
    this.gpsFix = false,
    this.sats,
    this.lat,
    this.lon,
  });

  final DateTime receivedAt;
  final bool gpsFix;
  final int? sats;
  final double? lat;
  final double? lon;

  /// Age of this status reading.
  Duration ageAt(DateTime now) => now.difference(receivedAt);

  static FetchGpsStatus? tryParseJson(Map<String, dynamic> j,
      {DateTime? receivedAt}) {
    try {
      return _parse(j, receivedAt ?? DateTime.now());
    } catch (_) {
      return null;
    }
  }

  static FetchGpsStatus? tryParseLine(String line,
      {DateTime? receivedAt}) {
    final t = line.trim();
    if (!t.startsWith('{')) return null;
    try {
      final j = jsonDecode(t);
      if (j is! Map<String, dynamic>) return null;
      return tryParseJson(j, receivedAt: receivedAt);
    } catch (_) {
      return null;
    }
  }

  static FetchGpsStatus? _parse(Map<String, dynamic> j, DateTime now) {
    if ('${j['gps']}'.toLowerCase() != 'status') return null;
    var gpsFix = FetchEvent._bool(j['fix']);
    double? lat, lon;
    final la = j['lat'];
    final lo = j['lon'];
    // Same rule as FetchEvent: no fix, no position — and a fix claim
    // without valid coordinates is contradictory, so reject it.
    if (gpsFix) {
      if (la is! num ||
          lo is! num ||
          !la.isFinite ||
          !lo.isFinite ||
          la.abs() > 90 ||
          lo.abs() > 180) {
        return null;
      }
      if (la != 0 || lo != 0) {
        lat = la.toDouble();
        lon = lo.toDouble();
      } else {
        // (0, 0) is not a position: drop the fix claim with it.
        gpsFix = false;
      }
    }
    final sats = j['sats'];
    return FetchGpsStatus(
      receivedAt: now,
      gpsFix: gpsFix,
      sats: sats is num && sats.isFinite ? sats.toInt().clamp(0, 64) : null,
      lat: lat,
      lon: lon,
    );
  }
}
