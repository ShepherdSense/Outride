import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/services/meshtastic_proto.dart';

// --- Minimal protobuf encoder for building synthetic frames ---

List<int> _varint(int v) {
  final out = <int>[];
  var x = v;
  do {
    var b = x & 0x7F;
    x >>= 7;
    if (x != 0) b |= 0x80;
    out.add(b);
  } while (x != 0);
  return out;
}

List<int> _sint32(int v) {
  if (v >= 0) return _varint(v);
  final out = <int>[];
  var r = v;
  for (var i = 0; i < 9; i++) {
    out.add((r & 0x7F) | 0x80);
    r = r >>> 7;
  }
  out.add(r & 0x7F);
  return out;
}

List<int> _tag(int field, int wire) => _varint((field << 3) | wire);
List<int> _lenField(int field, List<int> bytes) => [
      ..._tag(field, 2),
      ..._varint(bytes.length),
      ...bytes,
    ];
List<int> _u32(int field, int v) => [..._tag(field, 0), ..._varint(v)];
List<int> _sint32Field(int field, int v) => [..._tag(field, 0), ..._sint32(v)];

List<int> _fixed32(int field, int v) {
  final b = ByteData(4)..setUint32(0, v, Endian.little);
  return [..._tag(field, 5), ...b.buffer.asUint8List()];
}

List<int> _float32(int field, double v) {
  final b = ByteData(4)..setFloat32(0, v, Endian.little);
  return [..._tag(field, 5), ...b.buffer.asUint8List()];
}

List<int> _meshPacket({
  int from = 0x11111111,
  double? snr,
  int? rssi,
  int? hopLimit,
  int? hopStart,
  int portnum = 1,
}) {
  final data = [
    ..._u32(1, portnum),
    ..._lenField(2, 'hi'.codeUnits),
  ];
  return [
    ..._fixed32(1, from),
    ..._fixed32(2, 0xFFFFFFFF),
    ..._lenField(4, data),
    if (snr != null) ..._float32(8, snr),
    if (hopLimit != null) ..._u32(9, hopLimit),
    if (rssi != null) ..._sint32Field(12, rssi),
    if (hopStart != null) ..._u32(15, hopStart),
  ];
}

void main() {
  group('MeshProtoReader.readBytes len-0 (review item 4)', () {
    test('empty decoded field does not abort the rest of the packet',
        () {
      // MeshPacket with an EMPTY decoded field followed by rx_snr:
      // rx_snr must still decode (it used to come back null).
      final packet = [
        ..._fixed32(1, 0x11111111),
        ..._lenField(4, <int>[]), // empty decoded
        ..._float32(8, 7.5),
      ];
      final info = MeshPacketInfo.decode(Uint8List.fromList(packet));
      expect(info.from, 0x11111111);
      expect(info.rxSnr, closeTo(7.5, 1e-6));
      expect(info.portnum, isNull);
    });

    test('empty channel_id in an envelope does not lose gateway_id',
        () {
      final envelope = [
        ..._lenField(1, _meshPacket(snr: 3.0)),
        ..._lenField(2, <int>[]), // empty channel_id
        ..._lenField(3, '!a1b2c3d4'.codeUnits),
      ];
      final info = MeshPacketInfo.decodeEnvelope(
          Uint8List.fromList(envelope));
      expect(info, isNotNull);
      expect(info!.rxSnr, closeTo(3.0, 1e-6));
      expect(info.channelId, '');
      expect(info.gatewayId, '!a1b2c3d4');
    });

    test('readBytes returns empty for len 0 without consuming more',
        () {
      final r = MeshProtoReader(Uint8List.fromList([
        ..._tag(1, 2),
        0x00, // len 0
        ..._tag(2, 0),
        0x07,
      ]));
      expect(r.readTag(), (1 << 3) | 2);
      expect(r.readBytes(), isEmpty);
      expect(r.done, isFalse);
      expect(r.readTag(), (2 << 3) | 0);
      expect(r.readVarint(), 7);
    });
  });

  group('hostile protobuf input (review item 15)', () {
    test('MeshPacketInfo.decode never throws on garbage', () {
      final inputs = <List<int>>[
        <int>[], // empty
        [0x80], // truncated varint, single continuation byte
        [0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80],
        // 0x80-run with no terminator
        [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
        // length field larger than the buffer
        [..._tag(4, 2), ..._varint(5000), 0x01, 0x02],
        // random bytes
        List<int>.generate(128, (i) => (i * 37 + 11) % 256),
        // truncated float / fixed32 fields
        [..._tag(8, 5), 0x00, 0x00],
        [..._tag(1, 5), 0x11, 0x22],
        // valid prefix then garbage
        [..._meshPacket(snr: 1.0), 0xFF, 0xFF, 0x80, 0x80],
        // huge field number / unknown wire type
        [..._tag(1000, 2), ..._varint(3), 0x01, 0x02, 0x03],
        [..._tag(1, 3), 0x01, 0x02], // group wire type
      ];
      for (final input in inputs) {
        final info = MeshPacketInfo.decode(Uint8List.fromList(input));
        // No throw, no poisoned values.
        expect(info.rxSnr == null || info.rxSnr!.isFinite, isTrue);
        expect(info.rxRssi == null || info.rxRssi!.isFinite, isTrue);
      }
      // The valid-prefix case keeps its parsed fields.
      final kept = MeshPacketInfo.decode(Uint8List.fromList(
          [..._meshPacket(snr: 1.0), 0xFF, 0xFF, 0x80, 0x80]));
      expect(kept.rxSnr, closeTo(1.0, 1e-6));
    });

    test('decodeEnvelope never throws on garbage', () {
      final inputs = <List<int>>[
        <int>[],
        [0x80, 0x80, 0x80],
        [..._tag(1, 2), ..._varint(5000), 0x01],
        List<int>.generate(64, (i) => (i * 91 + 7) % 256),
        [..._lenField(1, _meshPacket(snr: 2.0)), 0xFF, 0x80],
      ];
      for (final input in inputs) {
        // Null (no packet) or a best-effort decoded info — never a
        // throw, and never a non-finite measurement.
        final info =
            MeshPacketInfo.decodeEnvelope(Uint8List.fromList(input));
        if (info != null) {
          expect(info.rxSnr == null || info.rxSnr!.isFinite, isTrue);
          expect(info.rxRssi == null || info.rxRssi!.isFinite, isTrue);
        }
      }
      final kept = MeshPacketInfo.decodeEnvelope(Uint8List.fromList(
          [..._lenField(1, _meshPacket(snr: 2.0)), 0xFF, 0x80]));
      expect(kept, isNotNull);
      expect(kept!.rxSnr, closeTo(2.0, 1e-6));
    });

    test('reader handles a truncated varint mid-message', () {
      final r = MeshProtoReader(
          Uint8List.fromList([0x08, 0x80, 0x80])); // field 1, no end
      expect(r.readTag(), 8);
      // Best-effort partial value; the reader is done, not wedged.
      r.readVarint();
      expect(r.done, isTrue);
    });
  });

  group('MeshProtoWriter', () {
    test('varint(-1) throws instead of hanging (review item 5)', () {
      expect(() => MeshProtoWriter.varint(-1), throwsArgumentError);
      expect(() => MeshProtoWriter.varint(-100), throwsArgumentError);
      expect(MeshProtoWriter.varint(0), [0]);
      expect(MeshProtoWriter.varint(300), [0xAC, 0x02]);
    });

    test('signedVarint32 round-trips through the real encoder', () {
      // The writer had zero callers in lib/ or tests (each test
      // file carried its own copy). Cover the real one.
      for (final v in [0, 1, -1, -108, 127, -128, 2147483647, -2147483648]) {
        final bytes = MeshProtoWriter.signedVarint32(v);
        final r = MeshProtoReader(Uint8List.fromList(bytes));
        expect(r.readSignedVarint32(), v);
      }
      // Negative int32 is the 10-byte sign-extended form.
      expect(MeshProtoWriter.signedVarint32(-108).length, 10);
      expect(MeshProtoWriter.signedVarint32(108).length, 1);
    });
  });
}
