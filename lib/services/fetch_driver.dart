/// Fetch driver: "The Fetch" throwable sensor ball.
///
/// Listens on the shared UDP 49160 hub ([NodeUdpHub]) — the same
/// universal ingestion path as every other Outride sensor — for the
/// ball's fused-event JSON:
///
///   {"event":"FUSED","mag_g":1.02,"mic_rms":31772.0,
///    "accel_trip":false,"mic_trip":false,"mmwave_trip":true,
///    "ble_trip":false,"wifi_trip":false,
///    "ble_nearby":15,"wifi_beacons":0,
///    "fix":false,"sats":0,"lat":null,"lon":null,"lora":"NOT_YET"}
///
/// and its 10 s GPS heartbeat {"gps":"status","fix":...,"sats":...}.
/// Today the bench bridge forwards the ball's serial lines to UDP
/// 49160; later the LoRa link carries the same JSON. The wire format
/// is the firmware's — this driver parses it, never redefines it.
///
/// CORROBORATION ONLY, by construction: [poll] returns no
/// [LinkSample]s, so the ball can never drive the RF tripwire, the
/// tracker, or the confidence merger in v1. Its events are displayed
/// on the Fetch view and are available to a future merger arm (the
/// model already carries the GPS position a geometry gate would
/// need). Whether Fetch trips should feed the tripwire is a
/// follow-up decision for the operator — it is not wired in here.
///
/// HONEST SCOPE: presence/movement data from a ball that hears,
/// feels, and sees motion and reports its own position. Never
/// identity, never a camera feed, never fire-control. BLE/Wi-Fi
/// tripwires watch device addresses, never who owns them; the ball
/// is listen-only and this driver transmits nothing.
///
/// SPEC NOTE (fusion_architecture_spec.md §10 item 2, new-sensor
/// onboarding checklist) — recorded as a deliberate deviation, not
/// silent drift: (a) the wire format is the ball's bespoke FUSED
/// JSON, not the typed Sensor Protocol RANGE/BINARY/MOTION
/// observations — but it rides the same transport (UDP 49160 via
/// NodeUdpHub, including its flood guard, 16 KB cap, and optional
/// source allowlist); (b) merger weight is explicitly zero —
/// display-only, a staged decision (whether Fetch trips feed the
/// tripwire is a follow-up for the operator; §3.1 fusion-on-connect
/// as written is not yet met); (c) timestamps are receive time,
/// satisfying §5 (the ball sends no clock); (d) the per-node
/// baseline lives on the ball (first two radio scans after boot,
/// ~10 s); (e) admission control is the hub allowlist, off by
/// default — same as the other sensor drivers.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/fetch_event.dart';
import '../models/link_sample.dart';
import 'node_udp_hub.dart';
import 'radio_driver.dart';

class FetchDriver extends RadioDriver {
  FetchDriver();

  /// Bounded event store: newest first. Oldest evicted first.
  final List<FetchEvent> _events = [];

  /// Latest GPS heartbeat (null until the first one arrives).
  FetchGpsStatus? _latestGps;

  int _malformed = 0;
  int _ingested = 0;

  /// Max fused events kept; the view shows the last ~100.
  static const int maxStored = 100;

  /// Events older than this are pruned (they're history; the
  /// recorder owns history for RF links, and the ball's serial log
  /// owns it here).
  static const Duration maxAge = Duration(minutes: 10);

  @override
  String get driverId => 'fetch';

  @override
  String get label => 'FETCH';

  @override
  bool get isImplemented => true;

  @override
  String get emptyHint =>
      'Listening on UDP 49160 — no Fetch events yet. The bench bridge '
      'forwards the ball\'s serial JSON (tools/fetch_serial_bridge), '
      'or the LoRa link carries the same JSON when it lands.';

  /// A display-only driver: an empty poll is normal (the ball only
  /// sends on a trip), never a fault. Without this override the
  /// poller would set a permanent "error" on the FETCH status every
  /// poll, and deployment health would read degraded/blind even
  /// while Fetch events are flowing.
  @override
  bool get emptyPollIsError => false;

  /// Deliberately NOT overridden: sampleMaxAge only governs
  /// LinkSample staleness, and this driver emits none.

  int get ingestedCount => _ingested;
  int get malformedCount => _malformed;

  /// Fused events, newest first (read-only view).
  List<FetchEvent> get events => List.unmodifiable(_events);

  /// Latest GPS heartbeat, or null when none has arrived.
  FetchGpsStatus? get latestGps => _latestGps;

  /// Newest event, or null when the store is empty.
  FetchEvent? get latest => _events.isEmpty ? null : _events.first;

  /// When [sensor] last tripped, or null when it never has in the
  /// stored window. Used by the view's per-sensor "last trip" state.
  DateTime? lastTripAt(FetchTripSensor sensor) {
    for (final e in _events) {
      if (e.tripped(sensor)) return e.receivedAt;
    }
    return null;
  }

  /// True when the newest event tripped [sensor].
  bool latestTripped(FetchTripSensor sensor) {
    final l = latest;
    return l != null && l.tripped(sensor);
  }

  /// Test hook: feed one event directly.
  @visibleForTesting
  void ingestForTest(FetchEvent e) => _ingest(e);

  /// Test hook: feed one GPS heartbeat directly.
  @visibleForTesting
  void gpsForTest(FetchGpsStatus s) => _ingestGps(s);

  /// Test hook: feed one raw UDP datagram body.
  @visibleForTesting
  void datagramForTest(String text) => _onDatagram(text);

  @override
  Future<List<LinkSample>> poll() async {
    await NodeUdpHub.ensureListening(_onDatagram);
    _prune();
    // Deliberately no LinkSamples: the ball is corroboration/display
    // only in v1 (see the class doc). An empty poll is NOT an error
    // for this driver — see [emptyPollIsError]; the poller must not
    // treat "the ball is quiet" as "the radio is broken".
    return const [];
  }

  void _onDatagram(String text) {
    Map<String, dynamic>? j;
    try {
      j = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      return; // not JSON / not ours; other drivers' traffic passes by
    }
    // Only messages that look like ours are counted malformed when
    // they fail to parse — anything else belongs to another driver.
    final event = j['event'];
    final gps = j['gps'];
    if (event != null) {
      if ('$event'.toUpperCase() != 'FUSED') return;
      final e = FetchEvent.tryParseJson(j);
      if (e == null) {
        _malformed++;
        return;
      }
      _ingest(e);
      return;
    }
    if (gps != null) {
      if ('$gps'.toLowerCase() != 'status') return;
      final s = FetchGpsStatus.tryParseJson(j);
      if (s == null) {
        _malformed++;
        return;
      }
      _ingestGps(s);
      return;
    }
    // No event/gps key: not a Fetch message; ignore silently.
  }

  void _ingest(FetchEvent e) {
    _ingested++;
    _events.insert(0, e);
    if (_events.length > maxStored) {
      _events.removeRange(maxStored, _events.length);
    }
    // Every fused event refreshes the GPS picture — the heartbeat
    // is 10 s, events are faster. ONE RULE in both paths (heartbeat
    // and event): a fix carries the position; a no-fix report
    // CLEARS it. "No fix" means the position is unknown, not "last
    // known" — a stale position must never outlive the fix that
    // produced it.
    _latestGps = FetchGpsStatus(
      receivedAt: e.receivedAt,
      gpsFix: e.gpsFix,
      sats: e.sats,
      lat: e.lat,
      lon: e.lon,
    );
    _pruneAt(DateTime.now());
  }

  void _ingestGps(FetchGpsStatus s) {
    _ingested++;
    _latestGps = s;
  }

  void _prune() => _pruneAt(DateTime.now());

  void _pruneAt(DateTime now) {
    final cutoff = now.subtract(maxAge);
    _events.removeWhere((e) => e.receivedAt.isBefore(cutoff));
  }

  @override
  Future<bool> probe() async {
    await NodeUdpHub.ensureListening(_onDatagram);
    return NodeUdpHub.isBound;
  }

  @override
  void dispose() => NodeUdpHub.release(_onDatagram);
}

// Wired into radio_driver.dart as driver id 'fetch'
// (driverTypes: 'FETCH (throwable sensor ball)').
// No config address needed — the driver listens, the ball talks.
