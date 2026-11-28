/// Shared minimal protobuf wire helpers for the Meshtastic files.
///
/// The driver (`meshtastic_driver.dart`) now uses this reader too
/// (unified 2026-11-28, review fix: the driver's private copy was
/// deleted — the len-0 bug had existed in both copies because of
/// the duplication). These helpers are the shared ones for all the
/// Meshtastic files, so the field numbers live in exactly one
/// place and the sign-extension rule for `rx_rssi` is implemented
/// once, correctly.
///
/// Verified against meshtastic/protobufs (master, read 2026-11-28):
/// `MeshPacket{from=1 fixed32, to=2 fixed32, channel=3, decoded=4,
/// encrypted=5, id=6 fixed32, rx_time=7, rx_snr=8 float,
/// hop_limit=9 varint, want_ack=10, priority=11, rx_rssi=12 int32
/// varint, delayed=13, via_mqtt=14, hop_start=15 varint,
/// public_key=16, pki_encrypted=17, next_hop=18, relay_node=19,
/// tx_after=20, transport_mechanism=21, xeddsa_signed=22}`,
/// `Data{portnum=1, payload=2}`, `ToRadio{packet=1, want_config_id=3}`,
/// `FromRadio{packet=2, my_info=3, node_info=4}`,
/// `ServiceEnvelope{packet=1, channel_id=2, gateway_id=3}`,
/// `Telemetry{device_metrics=2}`,
/// `DeviceMetrics{channel_utilization=3 float, air_util_tx=4 float}`,
/// `TELEMETRY_APP=67`, `NEIGHBORINFO_APP=71`.
///
/// CORRECTION (2026-11-28): the deep-dive report claimed `rx_rssi`
/// was MeshPacket field 9. It is field **12**. Field 9 is
/// `hop_limit`. Reading field 9 as RSSI would silently record
/// hop-limit values (0-7) as RSSI — a data-corruption bug.
///
/// `rx_rssi` is int32 encoded as a varint: negative values arrive as
/// 10-byte sign-extended varints. [readSignedVarint32] takes only the
/// low 32 bits and sign-extends from bit 31, so -108 dBm decodes as
/// -108, not as a huge positive number.
library;

import 'dart:typed_data';

/// Minimal protobuf wire-format reader: varint, 32-bit, and
/// length-delimited fields. Skips anything it doesn't understand.
class MeshProtoReader {
  MeshProtoReader(this.buf) : _b = ByteData.sublistView(buf);

  final Uint8List buf;
  final ByteData _b;
  int _i = 0;

  bool get done => _i >= buf.length;

  int readTag() => readVarint();

  /// Unsigned varint, up to 64 bits. Truncated input returns the
  /// best-effort partial value; callers that need strictness must
  /// check [done] / length themselves.
  int readVarint() {
    var result = 0;
    var shift = 0;
    while (_i < buf.length && shift < 64) {
      final byte = buf[_i++];
      result |= (byte & 0x7F) << shift;
      if ((byte & 0x80) == 0) return result;
      shift += 7;
    }
    return result;
  }

  /// int32 encoded as a varint (proto3 `int32`): negative values are
  /// sign-extended to 64 bits on the wire (10 bytes). Only the low
  /// 32 bits carry the value; sign-extend from bit 31.
  int readSignedVarint32() {
    var low32 = 0;
    var shift = 0;
    while (_i < buf.length && shift < 70) {
      final byte = buf[_i++];
      if (shift < 32) {
        low32 |= (byte & 0x7F) << shift;
      }
      if ((byte & 0x80) == 0) break;
      shift += 7;
    }
    low32 &= 0xFFFFFFFF;
    if ((low32 & 0x80000000) != 0) return low32 - 0x100000000;
    return low32;
  }

  int readFixed32() {
    if (_i + 4 > buf.length) {
      _i = buf.length;
      return 0;
    }
    final v = _b.getUint32(_i, Endian.little);
    _i += 4;
    return v;
  }

  int readSfixed32() {
    if (_i + 4 > buf.length) {
      _i = buf.length;
      return 0;
    }
    final v = _b.getInt32(_i, Endian.little);
    _i += 4;
    return v;
  }

  double readFloat() {
    if (_i + 4 > buf.length) {
      _i = buf.length;
      return double.nan;
    }
    final v = _b.getFloat32(_i, Endian.little);
    _i += 4;
    return v;
  }

  Uint8List readBytes() {
    final len = readVarint();
    // FIX (review 2026-11-28, item 4): len == 0 is VALID protobuf
    // (an empty length-delimited field) — it must NOT abort the
    // rest of the message. Only overrun aborts. A MeshPacket with
    // an empty `decoded` followed by `rx_snr` used to lose rx_snr.
    if (len < 0 || _i + len > buf.length) {
      _i = buf.length;
      return Uint8List(0);
    }
    final out = buf.sublist(_i, _i + len);
    _i += len;
    return out;
  }

  void skip(int wire) {
    switch (wire) {
      case 0:
        readVarint();
      case 1:
        _i += 8;
      case 2:
        final len = readVarint();
        _i += len < 0 ? 0 : len;
      case 5:
        _i += 4;
      default:
        _i = buf.length; // groups (3/4): deprecated, abort field
    }
    if (_i > buf.length) _i = buf.length;
  }
}

/// Minimal protobuf wire-format writer helpers (encode only what we
/// send: varint / fixed32 / float32 / length-delimited fields).
class MeshProtoWriter {
  static List<int> varint(int v) {
    // FIX (review 2026-11-28, item 5): a negative input used to
    // loop forever (arithmetic `>>` keeps -1 at -1) and hang the
    // isolate. Negative values must go through [signedVarint32].
    if (v < 0) {
      throw ArgumentError(
          'MeshProtoWriter.varint: negative value $v; use '
          'signedVarint32 for signed fields');
    }
    final out = <int>[];
    // Unsigned encoding of the low 64 bits; callers pass non-negative
    // values except [signedVarint32], which handles negatives.
    var x = v;
    do {
      var b = x & 0x7F;
      x >>= 7;
      if (x != 0) b |= 0x80;
      out.add(b);
    } while (x != 0);
    return out;
  }

  /// int32 as a varint: negative values are sign-extended to 64 bits
  /// (10 bytes on the wire), matching proto3 `int32` encoding.
  static List<int> signedVarint32(int v) {
    final out = <int>[];
    // Dart ints are already 64-bit two's-complement, so `v` itself
    // is the bit pattern to encode; see the loop below.
    if (v >= 0) return varint(v);
    // 10 bytes: first 9 carry 7 bits each (63 bits), last carries 1.
    var remaining = v;
    for (var i = 0; i < 9; i++) {
      out.add((remaining & 0x7F) | 0x80);
      remaining = remaining >>> 7;
    }
    out.add(remaining & 0x7F);
    return out;
  }

  static List<int> tag(int field, int wire) => varint((field << 3) | wire);

  static List<int> varintField(int field, int v) => [
        ...tag(field, 0),
        ...varint(v),
      ];

  static List<int> fixed32Field(int field, int v) {
    final b = ByteData(4)..setUint32(0, v, Endian.little);
    return [...tag(field, 5), ...b.buffer.asUint8List()];
  }

  static List<int> floatField(int field, double v) {
    final b = ByteData(4)..setFloat32(0, v, Endian.little);
    return [...tag(field, 5), ...b.buffer.asUint8List()];
  }

  static List<int> lenField(int field, List<int> bytes) => [
        ...tag(field, 2),
        ...varint(bytes.length),
        ...bytes,
      ];
}

/// The decoded per-packet fields Outride cares about, shared by the
/// driver, the probe parser and the MQTT tap.
///
/// `hopCount` is `hop_start - hop_limit` when both are known; null
/// when `hop_start` is absent or 0 (firmware before 2.3.0 never
/// populated it, so 0 means "unknown", not "direct" — mesh.proto).
class MeshPacketInfo {
  const MeshPacketInfo({
    required this.from,
    required this.to,
    this.rxSnr,
    this.rxRssi,
    this.hopCount,
    this.portnum,
    this.payload,
    this.channelId,
    this.gatewayId,
  });

  /// Sender node number (0 = unknown/absent).
  final int from;

  /// Destination node number (0xFFFFFFFF = broadcast).
  final int to;

  /// Received SNR in dB, as reported by the receiving radio.
  final double? rxSnr;

  /// Received RSSI in dBm. Null when the packet carried no RSSI.
  /// (Field 12, int32 varint — NOT field 9.)
  final double? rxRssi;

  /// Hops already travelled, or null when unknown.
  final int? hopCount;

  /// Decoded payload portnum, when the packet carried a `decoded`
  /// payload (encrypted packets have none at this layer).
  final int? portnum;

  /// Decoded payload bytes, when present.
  final Uint8List? payload;

  /// MQTT channel id, when the packet arrived via a ServiceEnvelope.
  final String? channelId;

  /// MQTT gateway id, when the packet arrived via a ServiceEnvelope.
  final String? gatewayId;

  /// Decode a MeshPacket protobuf. Never throws: malformed input
  /// yields a best-effort record with the fields that did parse.
  static MeshPacketInfo decode(Uint8List pb,
      {String? channelId, String? gatewayId}) {
    var from = 0;
    var to = 0;
    double? rxSnr;
    double? rxRssi;
    int? hopLimit;
    int? hopStart;
    var hasHopStart = false;
    Uint8List? decoded;
    try {
      final r = MeshProtoReader(pb);
      while (!r.done) {
        final tag = r.readTag();
        final field = tag >> 3;
        final wire = tag & 7;
        if (field == 1 && wire == 5) {
          from = r.readFixed32();
        } else if (field == 2 && wire == 5) {
          to = r.readFixed32();
        } else if (field == 4 && wire == 2) {
          decoded = r.readBytes();
        } else if (field == 8 && wire == 5) {
          final v = r.readFloat();
          if (v.isFinite) rxSnr = v;
        } else if (field == 9 && wire == 0) {
          hopLimit = r.readVarint();
        } else if (field == 12 && wire == 0) {
          rxRssi = r.readSignedVarint32().toDouble();
        } else if (field == 15 && wire == 0) {
          hopStart = r.readVarint();
          hasHopStart = true;
        } else {
          r.skip(wire);
        }
      }
    } catch (_) {
      // Best effort: keep whatever parsed before the bad field.
    }
    int? portnum;
    Uint8List? payload;
    if (decoded != null) {
      try {
        final r = MeshProtoReader(decoded);
        while (!r.done) {
          final tag = r.readTag();
          final field = tag >> 3;
          final wire = tag & 7;
          if (field == 1 && wire == 0) {
            portnum = r.readVarint();
          } else if (field == 2 && wire == 2) {
            payload = r.readBytes();
          } else {
            r.skip(wire);
          }
        }
      } catch (_) {
        // Keep the packet-level fields; payload stays as parsed.
      }
    }
    int? hopCount;
    if (hasHopStart && hopStart != null && hopStart > 0 && hopLimit != null) {
      hopCount = hopStart - hopLimit;
      if (hopCount < 0) hopCount = 0;
    }
    return MeshPacketInfo(
      from: from,
      to: to,
      rxSnr: rxSnr,
      rxRssi: rxRssi,
      hopCount: hopCount,
      portnum: portnum,
      payload: payload,
      channelId: channelId,
      gatewayId: gatewayId,
    );
  }

  /// Decode a `ServiceEnvelope{packet=1, channel_id=2, gateway_id=3}`
  /// (mqtt.proto). Never throws; returns null only when the envelope
  /// carries no packet at all.
  static MeshPacketInfo? decodeEnvelope(Uint8List pb) {
    Uint8List? packet;
    String? channelId;
    String? gatewayId;
    try {
      final r = MeshProtoReader(pb);
      while (!r.done) {
        final tag = r.readTag();
        final field = tag >> 3;
        final wire = tag & 7;
        if (field == 1 && wire == 2) {
          packet = r.readBytes();
        } else if (field == 2 && wire == 2) {
          channelId = String.fromCharCodes(r.readBytes());
        } else if (field == 3 && wire == 2) {
          gatewayId = String.fromCharCodes(r.readBytes());
        } else {
          r.skip(wire);
        }
      }
    } catch (_) {
      // Best effort.
    }
    if (packet == null) return null;
    return decode(packet, channelId: channelId, gatewayId: gatewayId);
  }
}
