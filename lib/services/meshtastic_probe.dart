/// Custom Outride sensing payload on a private portnum, host-injected
/// (improvement #2, path (a) — no firmware fork).
///
/// DESIGN DECISION (recorded explicitly — see also the driver header,
/// `docs/meshtastic_driver_spec.md`, and
/// `docs/meshtastic_hygiene_config.md`): this changes the driver's
/// historical RX-only stance. When probing is enabled, Outride
/// TRANSMITS normal Meshtastic broadcast packets on OUR OWN channel,
/// via the local node's client API (TCP 4403, `ToRadio{packet}`).
/// That is legitimate operation of our own mesh, not an attack: the
/// packets are ordinary mesh traffic, addressed to broadcast, on a
/// private portnum, carrying only link measurements our nodes already
/// made. Nothing here jams, deauths, spoofs, or touches any other
/// network. Probing is OFF by default (opt-in flag) and refuses to
/// send when the channel-utilization guard trips — fail-safe default.
///
/// ## Payload format (version 1, "ORT1")
///
/// Binary, little-endian, max 14 + 16*10 = 174 bytes (well under the
/// 233-byte `Data` payload budget):
///
/// ```
/// offset  size  field
/// 0       4     magic "ORT1" (0x4F 0x52 0x54 0x31)
/// 4       1     version = 1
/// 5       4     sender node number (uint32 LE)
/// 9       4     timestamp, epoch seconds (uint32 LE)
/// 13      1     neighbor count N (0..16)
/// 14      N*10  per-neighbor triples:
///               node number uint32 LE (4)
///               rx_snr float32 LE, dB (4)
///               rx_rssi int16 LE, dBm, clamped to [-200, 0] (2)
/// ```
///
/// Each triple says: "the sender heard this neighbor at this SNR /
/// RSSI". The decoder records the edge reporter -> heard (sender ->
/// neighbor) — the NeighborInfo / LinkSample convention, so a probe
/// observation and a NeighborInfo edge for the same pair land on
/// the same directed edge (FIX, review 2026-11-28, item 8: the
/// series edge and the neighbor table previously used opposite
/// directions for the same observation).
///
/// ## Channel (FIX, review item 7)
///
/// Probes are transmitted on the PRIMARY channel (index 0) unless
/// the caller passes [MeshtasticProbePayload.buildToRadioFrame]'s
/// `channel` parameter: the frame sets `MeshPacket.channel` only
/// when one is given, and the earlier doc claim "on OUR OWN
/// channel" is true only when the deployment channel IS the
/// primary. On a secondary channel, pass its index explicitly —
/// otherwise the probe goes out on the wrong channel, possibly the
/// public default, with the wrong PSK. [MeshtasticProbeSender.
/// startPeriodic] takes the same `channel` and threads it to
/// [MeshtasticProbeSender.sendOnce], so the periodic path — the one
/// that actually runs — probes the deployment channel too (FIX,
/// re-review item 4: it used to always probe the primary).
///
/// ## Second TCP connection (FIX, review item 14)
///
/// [MeshtasticProbeSender.sendOnce] dials a FRESH TCP 4403
/// connection per probe while the driver holds its own persistent
/// one. Whether a node's client API tolerates a second concurrent
/// client is UNVERIFIED — confirm against a real Heltec node
/// before wiring (bench checklist, hygiene doc §10). If it
/// disrupts the driver stream, the fallback is to send probes
/// through the driver's existing socket instead of a second
/// connection. `tcpFramesWritten` counts frames flushed to TCP —
/// the radio may still never have transmitted them.
///
/// ## Channel-utilization guard
///
/// Arithmetic (deep-dive §2.1/§4 #2, CLAIMED as arithmetic): a
/// 32-byte LongFast packet costs ~477 ms airtime. One probe per node
/// per 5 min in a 10-node mesh adds 10 x 12 x 0.477 s ≈ 57 s of
/// airtime per hour, ~1.6% channel utilization on LongFast
/// (MediumFast ~3.4x cheaper) — origin transmissions only. Every
/// probe broadcast is ALSO relayed (typically 1-3 extra
/// transmissions per probe in a small mesh), so the guard
/// multiplies the origin-only figure by a conservative relay
/// factor of 3 (FIX, review item 2: without it, 10 nodes at 1-min
/// cadence on LongFast computed 7.95% and passed, while true load
/// with relays is ~16-24%, blowing the 10% cap). The guard caps
/// the OWN-TX PROJECTION (origin + relay estimate) — it is not a
/// guarantee about total channel load: pass the freshest observed
/// ChUtil (telemetry, percent) when available; without an
/// observation the projection covers probe load only, not the
/// mesh's background traffic. Feed observed ChUtil as a PERCENT
/// (e.g. 2.655), the unit `DeviceMetrics.channel_utilization`
/// reports; the guard divides by 100 internally (FIX, review
/// item 9: passing the raw percent as a fraction used to refuse
/// every probe forever).
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'meshtastic_proto.dart';

/// Private portnum for the Outride link-report payload (256-511).
const int outrideProbePortnum = 300;

/// Max neighbors carried in one probe report.
const int maxProbeNeighbors = 16;

/// One neighbor observation inside a probe report: the sender heard
/// this neighbor at [snr] dB / [rssi] dBm.
class ProbeNeighborObservation {
  const ProbeNeighborObservation({
    required this.nodeNum,
    required this.snr,
    required this.rssi,
  });

  final int nodeNum;
  final double snr;

  /// dBm, clamped to [-200, 0] on encode.
  final double rssi;
}

/// A decoded Outride probe report.
class MeshtasticProbeReport {
  const MeshtasticProbeReport({
    required this.senderNodeNum,
    required this.timestamp,
    required this.neighbors,
  });

  final int senderNodeNum;
  final DateTime timestamp;
  final List<ProbeNeighborObservation> neighbors;
}

/// Encode / decode for the versioned binary link-report payload.
/// [decode] throws [FormatException] on bad magic, unknown version,
/// or truncation — never returns a half-parsed report.
class MeshtasticProbePayload {
  static const List<int> magic = [0x4F, 0x52, 0x54, 0x31]; // "ORT1"
  static const int version = 1;

  static const int _headerBytes = 14;
  static const int _tripleBytes = 10;

  static Uint8List encode({
    required int senderNodeNum,
    required DateTime timestamp,
    required List<ProbeNeighborObservation> neighbors,
  }) {
    final kept = neighbors.take(maxProbeNeighbors).toList();
    final out = BytesBuilder();
    out.add(magic);
    out.addByte(version);
    final head = ByteData(8)
      ..setUint32(0, senderNodeNum, Endian.little)
      ..setUint32(
          4, timestamp.millisecondsSinceEpoch ~/ 1000, Endian.little);
    out.add(head.buffer.asUint8List());
    out.addByte(kept.length);
    for (final n in kept) {
      final b = ByteData(_tripleBytes)
        ..setUint32(0, n.nodeNum, Endian.little)
        ..setFloat32(4, n.snr, Endian.little)
        ..setInt16(
            8, n.rssi.clamp(-200.0, 0.0).round(), Endian.little);
      out.add(b.buffer.asUint8List());
    }
    return out.toBytes();
  }

  static MeshtasticProbeReport decode(Uint8List bytes) {
    if (bytes.length < _headerBytes) {
      throw const FormatException('probe payload too short');
    }
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) {
        throw const FormatException('probe payload bad magic');
      }
    }
    if (bytes[4] != version) {
      throw FormatException(
          'probe payload unsupported version ${bytes[4]}');
    }
    final head = ByteData.sublistView(bytes, 5, 13);
    final sender = head.getUint32(0, Endian.little);
    final epochSecs = head.getUint32(4, Endian.little);
    final count = bytes[13];
    if (count > maxProbeNeighbors) {
      throw FormatException('probe payload neighbor count $count > '
          '$maxProbeNeighbors');
    }
    if (bytes.length < _headerBytes + count * _tripleBytes) {
      throw const FormatException('probe payload truncated triples');
    }
    final neighbors = <ProbeNeighborObservation>[];
    for (var i = 0; i < count; i++) {
      final off = _headerBytes + i * _tripleBytes;
      final t = ByteData.sublistView(bytes, off, off + _tripleBytes);
      // FIX (review 2026-11-28, B1 — BLOCKING): a triple's SNR must
      // be finite. A NaN SNR (bits 0x7FC00000) used to decode fine,
      // poisoning the series (MeshLinkSample(snr: NaN)) and the
      // neighbor table for up to 30 min, and making detectStep
      // return NaN instead of null. Throws, like every other bad
      // input here — never returns a half-parsed report.
      final snr = t.getFloat32(4, Endian.little);
      if (!snr.isFinite) {
        throw const FormatException('probe payload non-finite SNR');
      }
      neighbors.add(ProbeNeighborObservation(
        nodeNum: t.getUint32(0, Endian.little),
        snr: snr,
        rssi: t.getInt16(8, Endian.little).toDouble(),
      ));
    }
    return MeshtasticProbeReport(
      senderNodeNum: sender,
      timestamp: DateTime.fromMillisecondsSinceEpoch(epochSecs * 1000),
      neighbors: neighbors,
    );
  }

  /// Build the framed TCP-4403 bytes for one probe:
  /// `[0x94, 0xC3, lenMSB, lenLSB]` + `ToRadio{packet}` where the
  /// MeshPacket is a broadcast (`to = 0xFFFFFFFF`) carrying
  /// `Data{portnum: 300, payload}` with hop_limit 3. `from`/`id`
  /// are left for the firmware to fill — that assumption is
  /// UNVERIFIED on hardware; confirm on the Heltec bench (hygiene
  /// doc §10) before relying on it. When [channel] is given, the
  /// frame sets `MeshPacket.channel` to that index; when omitted
  /// the probe goes out on the PRIMARY channel (index 0) — see
  /// the channel note in this file's header.
  static Uint8List buildToRadioFrame({
    required int senderNodeNum,
    required DateTime timestamp,
    required List<ProbeNeighborObservation> neighbors,
    int hopLimit = 3,
    int? channel,
  }) {
    // FIX (review item 5): hop_limit is a 3-bit wire field (0-7).
    // Clamp instead of encoding an out-of-range value.
    final clampedHopLimit = hopLimit.clamp(0, 7);
    if (channel != null && (channel < 0 || channel > 7)) {
      // FIX (re-review item 9): the wire range is 0-7; a bogus
      // index used to encode silently (only negatives threw).
      throw ArgumentError(
          'probe channel must be 0-7, got $channel');
    }
    final payload = encode(
      senderNodeNum: senderNodeNum,
      timestamp: timestamp,
      neighbors: neighbors,
    );
    final data = [
      ...MeshProtoWriter.varintField(1, outrideProbePortnum),
      ...MeshProtoWriter.lenField(2, payload),
    ];
    final packet = [
      ...MeshProtoWriter.fixed32Field(2, 0xFFFFFFFF), // to: broadcast
      if (channel != null) ...MeshProtoWriter.varintField(3, channel),
      ...MeshProtoWriter.lenField(4, data), // decoded
      ...MeshProtoWriter.varintField(9, clampedHopLimit),
    ];
    final toRadio = MeshProtoWriter.lenField(1, packet);
    return Uint8List.fromList([
      0x94,
      0xC3,
      (toRadio.length >> 8) & 0xFF,
      toRadio.length & 0xFF,
      ...toRadio,
    ]);
  }
}

/// Channel-utilization guard (pure arithmetic, unit-tested).
class ProbeChannelGuard {
  /// Max total channel utilization (fraction) probes may push us to.
  static const double maxUtilization = 0.10;

  /// Airtime of one probe packet, seconds. Default 0.477 s = a
  /// 32-byte LongFast packet (deep-dive §2.1). Callers on MediumFast
  /// pass ~0.140 s.
  static const double defaultAirtimeSecs = 0.477;

  /// Conservative multiplier for flood-relay cost: every probe
  /// broadcast is relayed as well as originated (typically 1-3
  /// extra transmissions per probe in a small mesh, so 2-4x the
  /// origin-only airtime). 3.0 is the documented conservative
  /// middle of that range; a dense mesh with more relays can
  /// exceed it, so the guard caps a PROJECTION, not a guarantee.
  static const double defaultRelayFactor = 3.0;

  /// Fraction of channel time our probes would ADD, given [nodeCount]
  /// probing nodes each sending one probe per [cadence]. Includes
  /// the relay multiplier ([relayFactor] x the origin-only figure).
  ///
  /// FIX (re-review item 7): computed in milliseconds, not whole
  /// seconds — `cadence.inSeconds <= 0` used to return 0 for a
  /// sub-second cadence (e.g. 500 ms), reporting the probes as
  /// "free" and letting [maySend] allow them. A cadence under 1 s
  /// is now real utilization (500 ms at 10 nodes ≈ 28.6x the
  /// channel), so it refuses.
  static double addedUtilization({
    required int nodeCount,
    required Duration cadence,
    double airtimeSecs = defaultAirtimeSecs,
    double relayFactor = defaultRelayFactor,
  }) {
    if (nodeCount <= 0 || cadence.inMilliseconds <= 0) return 0;
    final cadenceSecs = cadence.inMilliseconds / 1000;
    return nodeCount * airtimeSecs / cadenceSecs * relayFactor;
  }

  /// Projected total utilization = observed + added. True when the
  /// projection stays within [maxUtilization].
  ///
  /// [observedUtilizationPercent] is the freshest observed channel
  /// utilization as a PERCENT (the unit telemetry ChUtil reports,
  /// e.g. 2.655 for 2.655%) — divided by 100 internally. Passing
  /// the raw percent as a fraction used to refuse every probe
  /// forever (2.655 > 0.10). When no observation is available,
  /// pass 0: the projection then covers probe load only, and the
  /// caller should prefer a fresh ChUtil reading whenever the
  /// driver has one.
  static bool maySend({
    required int nodeCount,
    required Duration cadence,
    double observedUtilizationPercent = 0,
    double airtimeSecs = defaultAirtimeSecs,
    double relayFactor = defaultRelayFactor,
  }) {
    final projected = observedUtilizationPercent / 100 +
        addedUtilization(
            nodeCount: nodeCount,
            cadence: cadence,
            airtimeSecs: airtimeSecs,
            relayFactor: relayFactor);
    return projected <= maxUtilization;
  }
}

/// Host-injected probe sender: talks TCP 4403 to a local node and
/// asks it to transmit one probe broadcast.
///
/// OFF BY DEFAULT: [enabled] defaults to false and [sendOnce]
/// refuses (returns false, sets [lastError]) until the operator
/// opts in. Cadence is clamped to 1-5 min at construction.
class MeshtasticProbeSender {
  MeshtasticProbeSender({
    required this.host,
    this.port = 4403,
    this.enabled = false,
    Duration cadence = const Duration(minutes: 5),
    this.nodeCountEstimate = 10,
    this.airtimeSecs = ProbeChannelGuard.defaultAirtimeSecs,
  }) : cadence = cadence.inSeconds < 60
            ? const Duration(minutes: 1)
            : cadence.inSeconds > 300
                ? const Duration(minutes: 5)
                : cadence;

  final String host;
  final int port;

  /// Opt-in flag. False (default) = never transmit, fail-safe.
  bool enabled;

  /// Probe cadence, clamped to 1-5 min.
  final Duration cadence;

  /// How many nodes we expect to be probing (for the guard).
  final int nodeCountEstimate;

  /// Airtime per probe packet, seconds (preset-dependent).
  final double airtimeSecs;

  Timer? _timer;

  /// Reentrancy guard for the periodic tick (FIX, re-review
  /// item 3): the [Timer.periodic] callback is async and
  /// [sendOnce]'s `socket.flush()` has no timeout, so a stalled
  /// peer could make one tick overlap the next, opening a second
  /// concurrent TCP 4403 connection and double-sending. While a
  /// tick is in flight, later ticks are skipped (counted in
  /// [overlappingTicksSkipped]), never run concurrently.
  bool _tickInFlight = false;

  /// How many periodic ticks were skipped because the previous
  /// tick was still in flight (stalled peer). A rising count
  /// means the peer is not answering, not that probes are lost
  /// to the guard — each skipped tick is one probe not sent.
  int overlappingTicksSkipped = 0;

  /// Last failure reason, or null when the last send succeeded /
  /// nothing has been attempted. Failures are surfaced here and in
  /// the return value — never swallowed silently.
  String? lastError;

  /// How many probe frames have been written to the radio's TCP
  /// socket (flushed). Named for what it measures: a flushed frame
  /// is NOT proof the radio transmitted it (FIX, review item 14 —
  /// the old name `sentCount` claimed a successful send).
  int tcpFramesWritten = 0;

  /// How many sends were refused by the utilization guard.
  int guardRefusals = 0;

  /// True when the guard would allow a send right now, given the
  /// observed channel utilization as a PERCENT (telemetry ChUtil,
  /// e.g. 2.655 — divided by 100 inside the guard).
  bool guardAllows({double observedUtilizationPercent = 0}) =>
      ProbeChannelGuard.maySend(
        nodeCount: nodeCountEstimate,
        cadence: cadence,
        observedUtilizationPercent: observedUtilizationPercent,
        airtimeSecs: airtimeSecs,
      );

  /// Send one probe now. Returns true when the frame was flushed
  /// to the radio's TCP socket. Returns false (with [lastError]
  /// set) when probing is disabled, the guard refuses, or the TCP
  /// send fails.
  ///
  /// Opens a FRESH TCP 4403 connection per probe while the driver
  /// holds its own persistent one — whether the radio tolerates a
  /// second concurrent client is unverified (see the header note
  /// and the hygiene-doc bench checklist).
  Future<bool> sendOnce({
    required int senderNodeNum,
    required List<ProbeNeighborObservation> neighbors,
    double observedUtilizationPercent = 0,
    int? channel,
    DateTime? at,
  }) async {
    lastError = null;
    if (!enabled) {
      lastError = 'probing is disabled (opt-in flag off)';
      return false;
    }
    if (!guardAllows(
        observedUtilizationPercent: observedUtilizationPercent)) {
      guardRefusals++;
      lastError = 'channel-utilization guard refused: projected '
          'utilization would exceed '
          '${(ProbeChannelGuard.maxUtilization * 100).toStringAsFixed(0)}%';
      return false;
    }
    final frame = MeshtasticProbePayload.buildToRadioFrame(
      senderNodeNum: senderNodeNum,
      timestamp: at ?? DateTime.now(),
      neighbors: neighbors,
      channel: channel,
    );
    Socket? socket;
    try {
      socket = await Socket.connect(host, port,
          timeout: const Duration(seconds: 5));
      socket.add(frame);
      await socket.flush();
      tcpFramesWritten++;
      return true;
    } catch (e) {
      lastError = 'probe TCP send failed: $e';
      return false;
    } finally {
      try {
        await socket?.close();
      } catch (_) {}
    }
  }

  /// Start periodic probing (timer-driven [sendOnce] calls). The
  /// [neighbors] callback supplies the current neighbor observations
  /// each tick; a throwing callback is caught, recorded in
  /// [lastError], and the timer keeps running (one bad tick must not
  /// kill the schedule silently — but it is logged, not swallowed).
  /// The [observedUtilizationPercent] callback (percent, telemetry
  /// ChUtil) is wrapped the same way (FIX, review small item: it
  /// used to escape the timer tick as an unhandled async error).
  /// Disabling the sender mid-run ([enabled] = false) cancels the
  /// timer on the next tick instead of letting it overwrite
  /// [lastError] every tick.
  ///
  /// [channel] is the deployment channel index the probes go out
  /// on (FIX, re-review item 4: the periodic path — the one that
  /// actually runs — used to always probe the primary channel even
  /// when [sendOnce] was given a channel). Omitted = primary.
  /// Overlapping ticks are skipped, never run concurrently (see
  /// [_tickInFlight]).
  void startPeriodic({
    required int senderNodeNum,
    required List<ProbeNeighborObservation> Function() neighbors,
    double Function()? observedUtilizationPercent,
    int? channel,
  }) {
    stop();
    if (!enabled) {
      lastError = 'probing is disabled (opt-in flag off)';
      return;
    }
    _timer = Timer.periodic(cadence, (_) async {
      if (!enabled) {
        stop();
        return;
      }
      if (_tickInFlight) {
        overlappingTicksSkipped++;
        return;
      }
      _tickInFlight = true;
      try {
        List<ProbeNeighborObservation> obs;
        try {
          obs = neighbors();
        } catch (e) {
          lastError = 'probe neighbor supplier failed: $e';
          return;
        }
        double observedPercent;
        try {
          observedPercent = observedUtilizationPercent?.call() ?? 0;
        } catch (e) {
          lastError = 'probe utilization supplier failed: $e';
          return;
        }
        await sendOnce(
          senderNodeNum: senderNodeNum,
          neighbors: obs,
          observedUtilizationPercent: observedPercent,
          channel: channel,
        );
      } finally {
        _tickInFlight = false;
      }
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    // N2 (final delta check): a stalled tick leaves _tickInFlight
    // set; without this reset, restarting startPeriodic makes the
    // new timer's first tick count as skipped.
    _tickInFlight = false;
  }

  bool get isRunning => _timer != null;

  void dispose() => stop();
}
