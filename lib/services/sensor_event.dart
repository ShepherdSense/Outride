/// Typed sensor-event surface for the Outride sensor bus.
///
/// [SensorProtocol] parses the wire (UART text / UDP 49160 JSON) into
/// the plain models ([SensorObservation], [CsiObservation],
/// [WindObservation]). This file is the TYPED event layer on top of
/// it: one `@freezed` sealed union — [SensorEvent] — whose eight
/// variants are the eight `obs` verbs the bus understands, plus
/// [SensorEventParseResult], the three-way outcome of parsing one
/// datagram (ok / malformed / ignored).
///
/// The wire format is UNCHANGED: [SensorEvent.toUdpJson] delegates to
/// [SensorProtocol.toUdpJson] for the six [SensorObservation]
/// variants (byte-identical output), and the CSI/WIND encoders emit
/// exactly the keys their parsers accept (proven by round-trip).
/// Two round-trip edges: a CSI datagram omitting `wind_gated` gains
/// the fail-safe default `true` on first encode (idempotent
/// thereafter), and lat/lon `(0,0)` is dropped by the parsers
/// (pre-existing). [SensorEvent.parseEvent] is the single typed entry
/// point for one UDP datagram; the legacy parse methods and their
/// [SensorParseResult]/[CsiParseResult]/[WindParseResult] return types
/// are untouched (fleet_service still uses `parseUdpJson` directly).
///
/// Deliberately NOT converted here:
/// - [SensorObservation] itself: consumed by the corroboration
///   engine, the ZMeta adapter, fleet_service and app_state. The
///   union wraps it per-variant instead of rewriting it.
/// - [CsiObservation]/[WindObservation]: plain models, wrapped as
///   union variants.
/// - [CrossingEvent]/[EpisodeSummary]/[LinkSample] (tripwire event
///   models): consumed by screens and app_state; out of scope for
///   this stream.
/// - The string dispatch inside [SensorProtocol._parseUdpInner]:
///   the lenient §1c parser contract (unknown verbs skipped, never
///   thrown) stays string-based internally; the typed surface is
///   [parseEvent] + [SensorEvent].
library;

import 'package:freezed_annotation/freezed_annotation.dart';

import '../models/sensor_observation.dart';
import 'sensor_protocol.dart';

part 'sensor_event.freezed.dart';

/// One typed sensor-bus event: exactly one `obs` verb's worth of data.
@freezed
sealed class SensorEvent with _$SensorEvent {
  const factory SensorEvent.range(SensorObservation observation) =
      SensorRangeEvent;
  const factory SensorEvent.bearing(SensorObservation observation) =
      SensorBearingEvent;
  const factory SensorEvent.spectrum(SensorObservation observation) =
      SensorSpectrumEvent;
  const factory SensorEvent.binary(SensorObservation observation) =
      SensorBinaryEvent;
  const factory SensorEvent.energy(SensorObservation observation) =
      SensorEnergyEvent;
  const factory SensorEvent.motion(SensorObservation observation) =
      SensorMotionEvent;
  const factory SensorEvent.csi(CsiObservation observation) = SensorCsiEvent;
  const factory SensorEvent.wind(WindObservation observation) = SensorWindEvent;

  const SensorEvent._();

  /// Wrap a parsed [SensorObservation] in the variant its type names.
  factory SensorEvent.fromObservation(SensorObservation o) {
    switch (o.type) {
      case SensorObsType.range:
        return SensorEvent.range(o);
      case SensorObsType.bearing:
        return SensorEvent.bearing(o);
      case SensorObsType.spectrum:
        return SensorEvent.spectrum(o);
      case SensorObsType.binary:
        return SensorEvent.binary(o);
      case SensorObsType.energy:
        return SensorEvent.energy(o);
      case SensorObsType.motion:
        return SensorEvent.motion(o);
    }
  }

  /// Parse one UDP JSON datagram body into the typed outcome. Never
  /// throws. The `obs` string is resolved ONCE here; callers dispatch
  /// on the result with exhaustive `when()` instead of string checks.
  ///
  /// - [SensorEventParseResult.ok]: a known verb parsed cleanly.
  /// - [SensorEventParseResult.malformed]: a KNOWN verb whose payload
  ///   failed validation (counts as malformed, as before).
  /// - [SensorEventParseResult.ignored]: not a `sensor_obs` datagram,
  ///   or an unknown verb — skipped per the §1c parser contract,
  ///   never counted malformed.
  static SensorEventParseResult parseEvent(Map<String, dynamic> j,
      {DateTime? receivedAt}) {
    if ('${j['type']}' != 'sensor_obs') {
      return const SensorEventParseResult.ignored();
    }
    final obs = '${j['obs'] ?? ''}'.toUpperCase();
    if (obs == 'CSI') {
      final r = SensorProtocol.parseCsiUdpJson(j, receivedAt: receivedAt);
      final o = r.observation;
      if (o == null) {
        return SensorEventParseResult.malformed(
            r.warning ?? 'unparseable CSI sensor_obs JSON');
      }
      return SensorEventParseResult.ok(SensorEvent.csi(o));
    }
    if (obs == 'WIND') {
      final r = SensorProtocol.parseWindUdpJson(j, receivedAt: receivedAt);
      final o = r.observation;
      if (o == null) {
        return SensorEventParseResult.malformed(
            r.warning ?? 'unparseable WIND sensor_obs JSON');
      }
      return SensorEventParseResult.ok(SensorEvent.wind(o));
    }
    if (!SensorProtocol.isKnownVerb(obs)) {
      return const SensorEventParseResult.ignored();
    }
    final r = SensorProtocol.parseUdpJson(j, receivedAt: receivedAt);
    final o = r.observation;
    if (o == null) {
      return SensorEventParseResult.malformed(
          r.warning ?? 'unparseable sensor_obs JSON');
    }
    return SensorEventParseResult.ok(SensorEvent.fromObservation(o));
  }

  /// Serialize back to the UDP 49160 JSON form. Byte-identical to
  /// [SensorProtocol.toUdpJson] for the six observation variants;
  /// CSI/WIND emit exactly the keys their parsers accept (same key
  /// set, same omission of absent optionals, same `t` seconds).
  Map<String, dynamic> toUdpJson() => when(
        range: SensorProtocol.toUdpJson,
        bearing: SensorProtocol.toUdpJson,
        spectrum: SensorProtocol.toUdpJson,
        binary: SensorProtocol.toUdpJson,
        energy: SensorProtocol.toUdpJson,
        motion: SensorProtocol.toUdpJson,
        csi: _csiToJson,
        wind: _windToJson,
      );

  static Map<String, dynamic> _csiToJson(CsiObservation o) {
    final j = <String, dynamic>{
      'type': 'sensor_obs',
      'obs': 'CSI',
      'sensor': o.sensorId,
      'dev_hz': o.devHz,
      'wind_gated': o.windGated,
      't': o.timestamp.toUtc().millisecondsSinceEpoch / 1000.0,
    };
    if (o.pairsActive != null) j['pairs_active'] = o.pairsActive;
    if (o.pathLossDb != null) j['path_loss_db'] = o.pathLossDb;
    if (o.link != null) j['link'] = o.link;
    if (o.windMs != null) j['wind_ms'] = o.windMs;
    if (o.sensorLat != null && o.sensorLon != null) {
      j['lat'] = o.sensorLat;
      j['lon'] = o.sensorLon;
    }
    return j;
  }

  static Map<String, dynamic> _windToJson(WindObservation o) {
    final j = <String, dynamic>{
      'type': 'sensor_obs',
      'obs': 'WIND',
      'sensor': o.sensorId,
      'wind_ms': o.windMs,
      't': o.timestamp.toUtc().millisecondsSinceEpoch / 1000.0,
    };
    if (o.gustMs != null) j['gust_ms'] = o.gustMs;
    if (o.sensorLat != null && o.sensorLon != null) {
      j['lat'] = o.sensorLat;
      j['lon'] = o.sensorLon;
    }
    return j;
  }
}

/// Outcome of parsing one sensor-bus datagram: the old
/// `(observation?, warning?)` nullable pair, made explicit.
@freezed
sealed class SensorEventParseResult with _$SensorEventParseResult {
  /// A known verb parsed cleanly into its typed event.
  const factory SensorEventParseResult.ok(SensorEvent event) = SensorEventOk;

  /// A known verb whose payload failed validation. Carries the
  /// warning string the legacy result classes carried.
  const factory SensorEventParseResult.malformed(String warning) =
      SensorEventMalformed;

  /// Not a `sensor_obs` datagram, or an unknown verb: skipped per
  /// the §1c parser contract, never counted malformed.
  const factory SensorEventParseResult.ignored() = SensorEventIgnored;
}
