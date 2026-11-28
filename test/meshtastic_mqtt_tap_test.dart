import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/services/meshtastic_mqtt_tap.dart';
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

/// int32 as a varint: negatives are the 10-byte sign-extended form.
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

List<int> _envelope(List<int> packet,
    {String channelId = 'test-channel', String gatewayId = '!a1b2c3d4'}) {
  return [
    ..._lenField(1, packet),
    ..._lenField(2, channelId.codeUnits),
    ..._lenField(3, gatewayId.codeUnits),
  ];
}

/// One MQTT packet (type byte + payload) parsed from a byte buffer.
({int type, List<int> payload})? _tryParseMqttPacket(List<int> buf) {
  if (buf.isEmpty) return null;
  var i = 1;
  var mult = 1;
  var remaining = 0;
  while (true) {
    if (i >= buf.length) return null;
    final b = buf[i++];
    remaining += (b & 0x7F) * mult;
    mult *= 128;
    if ((b & 0x80) == 0) break;
    if (mult > 128 * 128 * 128) return null;
  }
  if (buf.length < i + remaining) return null;
  return (
    type: buf[0] >> 4,
    payload: buf.sublist(i, i + remaining),
  );
}

List<int> _mqttRemaining(int n) {
  final out = <int>[];
  var x = n;
  do {
    var b = x & 0x7F;
    x >>= 7;
    if (x != 0) b |= 0x80;
    out.add(b);
  } while (x != 0);
  return out;
}

void main() {
  group('ServiceEnvelope decode', () {
    test('decodes packet, RSSI sign handling, hop count, gateway edge',
        () {
      final tap = MeshtasticMqttTap(host: '127.0.0.1', port: 1883);
      final bytes = Uint8List.fromList(_envelope(_meshPacket(
        snr: 7.5,
        rssi: -108,
        hopLimit: 1,
        hopStart: 3,
      )));
      final info = tap.ingestEnvelopeBytes(bytes);
      expect(info, isNotNull);
      expect(info!.from, 0x11111111);
      expect(info.rxSnr, closeTo(7.5, 1e-6));
      // -108 must decode as -108, not as a huge positive varint.
      expect(info.rxRssi, -108.0);
      expect(info.hopCount, 2);
      expect(info.channelId, 'test-channel');
      expect(info.gatewayId, '!a1b2c3d4');
      expect(tap.packetsSeen, 1);
      // Gateway-heard edge: sender -> gateway (!a1b2c3d4).
      final series = tap.linkSeries.seriesFor(0x11111111, 0xa1b2c3d4);
      expect(series.length, 1);
      expect(series.first.snr, closeTo(7.5, 1e-6));
      expect(series.first.rssi, -108.0);
      expect(series.first.hopCount, 2);
    });

    test('RSSI -1, 0, and absent are distinguished', () {
      expect(
          MeshPacketInfo.decode(
              Uint8List.fromList(_meshPacket(rssi: -1))).rxRssi,
          -1.0);
      expect(
          MeshPacketInfo.decode(
              Uint8List.fromList(_meshPacket(rssi: 0))).rxRssi,
          0.0);
      // hop_limit 7 present, no field 12: RSSI is null, NOT 7.
      // (This is the deep-dive field-9 regression test.)
      final noRssi = MeshPacketInfo.decode(
          Uint8List.fromList(_meshPacket(hopLimit: 7)));
      expect(noRssi.rxRssi, isNull);
      expect(noRssi.hopCount, isNull); // no hop_start either
    });

    test('envelope without a packet is malformed, counted', () {
      final tap = MeshtasticMqttTap(host: '127.0.0.1', port: 1883);
      final bytes = Uint8List.fromList(_lenField(2, 'only-channel'.codeUnits));
      expect(tap.ingestEnvelopeBytes(bytes), isNull);
      expect(tap.malformedCount, 1);
      expect(tap.packetsSeen, 0);
    });

    test('public broker is refused, including variants', () {
      expect(
        () => MeshtasticMqttTap(host: 'mqtt.meshtastic.org'),
        throwsArgumentError,
      );
      expect(
        () => MeshtasticMqttTap(host: 'MQTT.MESHTASTIC.ORG'),
        throwsArgumentError,
      );
      // Trailing dot is the same host — must still refuse.
      expect(
        () => MeshtasticMqttTap(host: 'mqtt.meshtastic.org.'),
        throwsArgumentError,
      );
      // Subdomains of the public broker are refused too.
      expect(
        () => MeshtasticMqttTap(host: 'eu.mqtt.meshtastic.org'),
        throwsArgumentError,
      );
      expect(
        () => MeshtasticMqttTap(host: 'EU.MQTT.MESHTASTIC.ORG.'),
        throwsArgumentError,
      );
      // A private host that merely contains the string is fine.
      expect(
        () => MeshtasticMqttTap(host: 'mqtt.meshtastic.org.local'),
        returnsNormally,
      );
    });

    test('non-hex gateway id is skipped, not merged into node 0', () {
      final tap = MeshtasticMqttTap(host: '127.0.0.1', port: 1883);
      final bytes = Uint8List.fromList(_envelope(
        _meshPacket(snr: 4.0),
        gatewayId: 'not-a-node-id',
      ));
      expect(tap.ingestEnvelopeBytes(bytes), isNull);
      expect(tap.malformedCount, 1);
      expect(tap.packetsSeen, 0);
      // No edge recorded against the local-node sentinel 0.
      expect(tap.linkSeries.seriesFor(0x11111111, 0), isEmpty);
      expect(tap.linkSeries.edgeCount, 0);
    });

    test('gateway id "-1" is malformed, not node -1 (re-review item 10)',
        () {
      // int.tryParse with radix 16 accepts a leading minus, so
      // "-1" used to record an edge to node -1. It must count as
      // malformed instead — same for "!-1" and "+1".
      for (final badId in ['-1', '!-1', '+1', '!+1']) {
        final tap = MeshtasticMqttTap(host: '127.0.0.1', port: 1883);
        final bytes = Uint8List.fromList(_envelope(
          _meshPacket(snr: 4.0),
          gatewayId: badId,
        ));
        expect(tap.ingestEnvelopeBytes(bytes), isNull);
        expect(tap.malformedCount, 1);
        expect(tap.packetsSeen, 0);
        expect(tap.linkSeries.edgeCount, 0);
      }
    });

    test('envelope without a gateway id is skipped', () {
      final tap = MeshtasticMqttTap(host: '127.0.0.1', port: 1883);
      final packet = _meshPacket(snr: 4.0);
      final bytes = Uint8List.fromList([
        ..._lenField(1, packet),
        ..._lenField(2, 'test-channel'.codeUnits),
        // No field 3 (gateway_id) at all.
      ]);
      expect(tap.ingestEnvelopeBytes(bytes), isNull);
      expect(tap.malformedCount, 1);
      expect(tap.packetsSeen, 0);
    });

    test('packet with from == 0 is dropped like the driver drops it',
        () {
      final tap = MeshtasticMqttTap(host: '127.0.0.1', port: 1883);
      final bytes = Uint8List.fromList(_envelope(
        _meshPacket(from: 0, snr: 4.0),
      ));
      expect(tap.ingestEnvelopeBytes(bytes), isNull);
      expect(tap.malformedCount, 1);
      expect(tap.packetsSeen, 0);
      expect(tap.linkSeries.edgeCount, 0);
    });
  });

  group('fake-broker subscribe', () {
    test('tap connects, subscribes, and ingests a published envelope',
        () async {
      // Fake MQTT 3.1.1 broker: CONNACK, SUBACK, then one PUBLISH.
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final port = server.port;
      final served = Completer<void>();
      unawaited(server.listen((Socket socket) async {
        final buf = <int>[];
        var published = false;
        await for (final data in socket) {
          buf.addAll(data);
          while (true) {
            final pkt = _tryParseMqttPacket(buf);
            if (pkt == null) break;
            // Consume the packet bytes from the buffer.
            var i = 1;
            var mult = 1;
            var remaining = 0;
            while (true) {
              final b = buf[i++];
              remaining += (b & 0x7F) * mult;
              mult *= 128;
              if ((b & 0x80) == 0) break;
            }
            buf.removeRange(0, i + remaining);
            if (pkt.type == 1) {
              // CONNECT -> CONNACK (accepted).
              socket.add([0x20, 0x02, 0x00, 0x00]);
            } else if (pkt.type == 8 && !published) {
              // SUBSCRIBE -> SUBACK with the client's packet id.
              final pid = pkt.payload.sublist(0, 2);
              socket.add([0x90, 0x03, pid[0], pid[1], 0x00]);
              // Then publish one ServiceEnvelope, QoS 0.
              final payload =
                  _envelope(_meshPacket(snr: 4.25, rssi: -95, hopLimit: 2, hopStart: 3));
              const topic = 'msh/US/2/e/test/!a1b2c3d4';
              final topicBytes = topic.codeUnits;
              final varHeader = [
                (topicBytes.length >> 8) & 0xFF,
                topicBytes.length & 0xFF,
                ...topicBytes,
              ];
              final remainingLen = varHeader.length + payload.length;
              socket.add([
                0x30,
                ..._mqttRemaining(remainingLen),
                ...varHeader,
                ...payload,
              ]);
              published = true;
              if (!served.isCompleted) served.complete();
            }
          }
        }
      }).asFuture());

      final tap = MeshtasticMqttTap(host: '127.0.0.1', port: port);
      try {
        expect(await tap.connect(), isTrue);
        expect(tap.isConnected, isTrue);
        expect(tap.isSubscribed, isTrue);
        // Wait for the published envelope to arrive via the tap.
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (tap.packetsSeen == 0 &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(tap.packetsSeen, greaterThanOrEqualTo(1));
        expect(tap.lastMessageAt, isNotNull);
        final series =
            tap.linkSeries.seriesFor(0x11111111, 0xa1b2c3d4);
        expect(series, isNotEmpty);
        expect(series.first.snr, closeTo(4.25, 1e-6));
        expect(series.first.rssi, -95.0);
        expect(series.first.hopCount, 1);
        expect(tap.coveragePacketsSeen, tap.packetsSeen);
      } finally {
        await tap.disconnect();
        await server.close();
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('connect to a closed port fails with lastError set', () async {
      final tap = MeshtasticMqttTap(host: '127.0.0.1', port: 1);
      expect(await tap.connect(), isFalse);
      expect(tap.lastError, isNotNull);
      expect(tap.isConnected, isFalse);
    });
  });

  group('subscribe confirmation (review item 6)', () {
    test('CONNACK without SUBACK makes connect() fail, not succeed',
        () async {
      // Fake broker: CONNACKs, then never answers the SUBSCRIBE.
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final port = server.port;
      unawaited(server.listen((Socket socket) async {
        final buf = <int>[];
        await for (final data in socket) {
          buf.addAll(data);
          while (true) {
            final pkt = _tryParseMqttPacket(buf);
            if (pkt == null) break;
            var i = 1;
            var mult = 1;
            var remaining = 0;
            while (true) {
              final b = buf[i++];
              remaining += (b & 0x7F) * mult;
              mult *= 128;
              if ((b & 0x80) == 0) break;
            }
            buf.removeRange(0, i + remaining);
            if (pkt.type == 1) {
              socket.add([0x20, 0x02, 0x00, 0x00]);
            }
            // SUBSCRIBE (type 8): deliberately never answered.
          }
        }
      }).asFuture());

      final tap = MeshtasticMqttTap(
        host: '127.0.0.1',
        port: port,
        subscribeTimeout: const Duration(seconds: 1),
      );
      try {
        expect(await tap.connect(), isFalse);
        expect(tap.isSubscribed, isFalse);
        expect(tap.lastError, contains('SUBACK'));
      } finally {
        await tap.disconnect();
        await server.close();
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('SUBACK failure code makes connect() fail', () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final port = server.port;
      unawaited(server.listen((Socket socket) async {
        final buf = <int>[];
        await for (final data in socket) {
          buf.addAll(data);
          while (true) {
            final pkt = _tryParseMqttPacket(buf);
            if (pkt == null) break;
            var i = 1;
            var mult = 1;
            var remaining = 0;
            while (true) {
              final b = buf[i++];
              remaining += (b & 0x7F) * mult;
              mult *= 128;
              if ((b & 0x80) == 0) break;
            }
            buf.removeRange(0, i + remaining);
            if (pkt.type == 1) {
              socket.add([0x20, 0x02, 0x00, 0x00]);
            } else if (pkt.type == 8) {
              // SUBACK with grant 0x80 = failure.
              final pid = pkt.payload.sublist(0, 2);
              socket.add([0x90, 0x03, pid[0], pid[1], 0x80]);
            }
          }
        }
      }).asFuture());

      final tap = MeshtasticMqttTap(
        host: '127.0.0.1',
        port: port,
        subscribeTimeout: const Duration(seconds: 5),
      );
      try {
        expect(await tap.connect(), isFalse);
        expect(tap.isSubscribed, isFalse);
        expect(tap.lastError, contains('subscribe refused'));
      } finally {
        await tap.disconnect();
        await server.close();
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('auto-reconnect (review item 10)', () {
    test('tap recovers from a broker drop and resubscribes', () async {
      // Fake broker: on every connection, CONNACK + SUBACK + one
      // publish; on the FIRST connection it then drops the socket.
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final port = server.port;
      var connections = 0;
      unawaited(server.listen((Socket socket) async {
        connections++;
        final thisConn = connections;
        final buf = <int>[];
        await for (final data in socket) {
          buf.addAll(data);
          while (true) {
            final pkt = _tryParseMqttPacket(buf);
            if (pkt == null) break;
            var i = 1;
            var mult = 1;
            var remaining = 0;
            while (true) {
              final b = buf[i++];
              remaining += (b & 0x7F) * mult;
              mult *= 128;
              if ((b & 0x80) == 0) break;
            }
            buf.removeRange(0, i + remaining);
            if (pkt.type == 1) {
              socket.add([0x20, 0x02, 0x00, 0x00]);
            } else if (pkt.type == 8) {
              final pid = pkt.payload.sublist(0, 2);
              socket.add([0x90, 0x03, pid[0], pid[1], 0x00]);
              final payload = _envelope(_meshPacket(
                  snr: 4.25, rssi: -95, hopLimit: 2, hopStart: 3));
              const topic = 'msh/US/2/e/test/!a1b2c3d4';
              final topicBytes = topic.codeUnits;
              final varHeader = [
                (topicBytes.length >> 8) & 0xFF,
                topicBytes.length & 0xFF,
                ...topicBytes,
              ];
              final remainingLen = varHeader.length + payload.length;
              socket.add([
                0x30,
                ..._mqttRemaining(remainingLen),
                ...varHeader,
                ...payload,
              ]);
              if (thisConn == 1) {
                // Drop the broker side after the first publish.
                await Future<void>.delayed(
                    const Duration(milliseconds: 200));
                try {
                  await socket.close();
                } catch (_) {}
              }
            }
          }
        }
      }).asFuture());

      final tap = MeshtasticMqttTap(host: '127.0.0.1', port: port);
      try {
        expect(await tap.connect(), isTrue);
        expect(tap.isSubscribed, isTrue);
        // First publish arrives.
        var deadline = DateTime.now().add(const Duration(seconds: 5));
        while (tap.packetsSeen < 1 && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(tap.packetsSeen, greaterThanOrEqualTo(1));
        expect(tap.lastMessageAt, isNotNull);
        // Broker drops; the tap must reconnect and ingest again.
        deadline = DateTime.now().add(const Duration(seconds: 15));
        while (tap.packetsSeen < 2 && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(tap.disconnectCount, greaterThanOrEqualTo(1));
        expect(tap.reconnectCount, greaterThanOrEqualTo(1));
        expect(tap.isConnected, isTrue);
        expect(tap.isSubscribed, isTrue);
        expect(tap.packetsSeen, greaterThanOrEqualTo(2));
      } finally {
        await tap.disconnect();
        await server.close();
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('intentional disconnect does not count as a broker failure',
        () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final port = server.port;
      unawaited(server.listen((Socket socket) async {
        final buf = <int>[];
        await for (final data in socket) {
          buf.addAll(data);
          while (true) {
            final pkt = _tryParseMqttPacket(buf);
            if (pkt == null) break;
            var i = 1;
            var mult = 1;
            var remaining = 0;
            while (true) {
              final b = buf[i++];
              remaining += (b & 0x7F) * mult;
              mult *= 128;
              if ((b & 0x80) == 0) break;
            }
            buf.removeRange(0, i + remaining);
            if (pkt.type == 1) {
              socket.add([0x20, 0x02, 0x00, 0x00]);
            } else if (pkt.type == 8) {
              final pid = pkt.payload.sublist(0, 2);
              socket.add([0x90, 0x03, pid[0], pid[1], 0x00]);
            }
          }
        }
      }).asFuture());

      final tap = MeshtasticMqttTap(host: '127.0.0.1', port: port);
      try {
        expect(await tap.connect(), isTrue);
        final dropsBefore = tap.disconnectCount;
        await tap.disconnect();
        // Give any stray callback a beat to fire.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(tap.disconnectCount, dropsBefore);
        expect(tap.isConnected, isFalse);
      } finally {
        await server.close();
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('tap-owned reconnect with backoff + circuit breaker (re-review item 1)', () {
    test('reconnectDelayFor backs off 5s -> 30s -> 60s cap', () {
      expect(MeshtasticMqttTap.reconnectDelayFor(0),
          const Duration(seconds: 5));
      expect(MeshtasticMqttTap.reconnectDelayFor(1),
          const Duration(seconds: 30));
      expect(MeshtasticMqttTap.reconnectDelayFor(2),
          const Duration(seconds: 60));
      expect(MeshtasticMqttTap.reconnectDelayFor(9),
          const Duration(seconds: 60));
      // A custom schedule caps at its own last entry.
      expect(
          MeshtasticMqttTap.reconnectDelayFor(
              0, const [Duration(milliseconds: 100)]),
          const Duration(milliseconds: 100));
      expect(
          MeshtasticMqttTap.reconnectDelayFor(
              5, const [Duration(milliseconds: 100)]),
          const Duration(milliseconds: 100));
    });

    test('repeated reconnect failures stop after maxReconnectAttempts',
        () async {
      // Fake broker: the first connection is fully served
      // (CONNACK + SUBACK + publish, then the socket is dropped).
      // Every later connection is refused at the MQTT layer
      // (CONNACK 0x05), so reconnect attempts fail fast and
      // deterministically instead of hanging on the timeout.
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final port = server.port;
      var connections = 0;
      final attemptTimes = <DateTime>[];
      unawaited(server.listen((Socket socket) async {
        connections++;
        attemptTimes.add(DateTime.now());
        final thisConn = connections;
        final buf = <int>[];
        await for (final data in socket) {
          buf.addAll(data);
          while (true) {
            final pkt = _tryParseMqttPacket(buf);
            if (pkt == null) break;
            var i = 1;
            var mult = 1;
            var remaining = 0;
            while (true) {
              final b = buf[i++];
              remaining += (b & 0x7F) * mult;
              mult *= 128;
              if ((b & 0x80) == 0) break;
            }
            buf.removeRange(0, i + remaining);
            if (pkt.type == 1) {
              if (thisConn == 1) {
                socket.add([0x20, 0x02, 0x00, 0x00]); // accepted
              } else {
                // Refused: not authorized (0x05). Fails fast.
                socket.add([0x20, 0x02, 0x00, 0x05]);
              }
            } else if (pkt.type == 8 && thisConn == 1) {
              final pid = pkt.payload.sublist(0, 2);
              socket.add([0x90, 0x03, pid[0], pid[1], 0x00]);
              final payload = _envelope(_meshPacket(
                  snr: 4.25, rssi: -95, hopLimit: 2, hopStart: 3));
              const topic = 'msh/US/2/e/test/!a1b2c3d4';
              final topicBytes = topic.codeUnits;
              final varHeader = [
                (topicBytes.length >> 8) & 0xFF,
                topicBytes.length & 0xFF,
                ...topicBytes,
              ];
              final remainingLen = varHeader.length + payload.length;
              socket.add([
                0x30,
                ..._mqttRemaining(remainingLen),
                ...varHeader,
                ...payload,
              ]);
              // Drop the broker side after the first publish.
              await Future<void>.delayed(
                  const Duration(milliseconds: 200));
              try {
                await socket.close();
              } catch (_) {}
            }
          }
        }
      }).asFuture());

      final tap = MeshtasticMqttTap(
        host: '127.0.0.1',
        port: port,
        connectTimeout: const Duration(seconds: 2),
        reconnectDelays: const [Duration(milliseconds: 100)],
        maxReconnectAttempts: 3,
      );
      try {
        expect(await tap.connect(), isTrue);
        // Wait for the first publish + the broker-side drop.
        var deadline = DateTime.now().add(const Duration(seconds: 5));
        while (tap.packetsSeen < 1 && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(tap.packetsSeen, greaterThanOrEqualTo(1));
        // Wait until the circuit breaker trips (3 failed retries).
        deadline = DateTime.now().add(const Duration(seconds: 15));
        while ((tap.reconnectAttempts < 3 ||
                tap.lastError == null ||
                !tap.lastError!.contains('gave up')) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(tap.reconnectAttempts, 3);
        expect(connections, 4); // 1 initial + 3 retries, then it stops
        expect(tap.lastError, contains('gave up'));
        expect(tap.isConnected, isFalse);
        // Retries really stopped: no further attempts after a wait
        // longer than the backoff delay.
        final attemptsAtTrip = tap.reconnectAttempts;
        final connsAtTrip = connections;
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(tap.reconnectAttempts, attemptsAtTrip);
        expect(connections, connsAtTrip);
        // And the retries were backed off, not spun: the attempts
        // are >= 50 ms apart (the configured delay was 100 ms).
        expect(attemptTimes.length, 4);
        for (var i = 1; i < attemptTimes.length; i++) {
          expect(
              attemptTimes[i]
                  .difference(attemptTimes[i - 1])
                  .inMilliseconds,
              greaterThanOrEqualTo(50));
        }
      } finally {
        await tap.disconnect();
        await server.close();
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('connect failure teardown — no orphaned client (re-review item 2)', () {
    test('CONNACK delayed past the timeout leaves no live client',
        () async {
      // Fake broker: on the FIRST connection, delay the CONNACK
      // past the tap's connect timeout, then answer it. On later
      // connections, answer promptly. If connect() orphaned the
      // first client, it would complete connecting in the
      // background and hold a live socket with the same client ID.
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final port = server.port;
      var connections = 0;
      var conn1Closed = false;
      unawaited(server.listen((Socket socket) async {
        connections++;
        final thisConn = connections;
        unawaited(socket.done.then(
          (_) {
            if (thisConn == 1) conn1Closed = true;
          },
          // The client tears the socket down with destroy(): done
          // completes with the reset error, not normally — either
          // way the socket is closed, which is what this asserts.
          onError: (_) {
            if (thisConn == 1) conn1Closed = true;
          },
        ));
        final buf = <int>[];
        // The broker writes the delayed CONNACK to a socket the
        // tap already tore down: that write fails with a broken
        // pipe, which is the expected outcome, not a test failure.
        try {
          await for (final data in socket) {
            buf.addAll(data);
            while (true) {
              final pkt = _tryParseMqttPacket(buf);
              if (pkt == null) break;
              var i = 1;
              var mult = 1;
              var remaining = 0;
              while (true) {
                final b = buf[i++];
                remaining += (b & 0x7F) * mult;
                mult *= 128;
                if ((b & 0x80) == 0) break;
              }
              buf.removeRange(0, i + remaining);
              if (pkt.type == 1) {
                if (thisConn == 1) {
                  // Delayed CONNACK: past the 1 s connect timeout.
                  await Future<void>.delayed(
                      const Duration(milliseconds: 2000));
                }
                try {
                  socket.add([0x20, 0x02, 0x00, 0x00]);
                } catch (_) {}
              } else if (pkt.type == 8) {
                final pid = pkt.payload.sublist(0, 2);
                try {
                  socket.add([0x90, 0x03, pid[0], pid[1], 0x00]);
                } catch (_) {}
              }
            }
          }
        } catch (_) {
          // Socket went away mid-conversation (teardown) — expected.
        }
      }).asFuture());

      final tap = MeshtasticMqttTap(
        host: '127.0.0.1',
        port: port,
        connectTimeout: const Duration(seconds: 1),
        subscribeTimeout: const Duration(seconds: 5),
      );
      try {
        // Times out waiting for the delayed CONNACK.
        expect(await tap.connect(), isFalse);
        expect(tap.lastError, isNotNull);
        expect(tap.isConnected, isFalse);
        // The orphaned-first-client failure mode would leave the
        // first socket open; the teardown must have closed it even
        // though the broker answered late.
        var deadline = DateTime.now().add(const Duration(seconds: 5));
        while (!conn1Closed && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(conn1Closed, isTrue);
        // A subsequent connect works cleanly: no duplicate client
        // with the same client ID left behind to get kicked.
        final secondOk = await tap.connect();
        expect(secondOk, isTrue);
        expect(tap.isConnected, isTrue);
        expect(tap.isSubscribed, isTrue);
        expect(connections, 2);
      } finally {
        await tap.disconnect();
        await server.close();
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('refused CONNACK leaves no live client either', () async {
      // Broker refuses the first CONNECT (0x05), accepts the
      // second: the non-connected-status failure path must tear
      // the client down the same way the timeout path does.
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final port = server.port;
      var connections = 0;
      unawaited(server.listen((Socket socket) async {
        connections++;
        final thisConn = connections;
        final buf = <int>[];
        await for (final data in socket) {
          buf.addAll(data);
          while (true) {
            final pkt = _tryParseMqttPacket(buf);
            if (pkt == null) break;
            var i = 1;
            var mult = 1;
            var remaining = 0;
            while (true) {
              final b = buf[i++];
              remaining += (b & 0x7F) * mult;
              mult *= 128;
              if ((b & 0x80) == 0) break;
            }
            buf.removeRange(0, i + remaining);
            if (pkt.type == 1) {
              if (thisConn == 1) {
                socket.add([0x20, 0x02, 0x00, 0x05]); // refused
              } else {
                socket.add([0x20, 0x02, 0x00, 0x00]); // accepted
              }
            } else if (pkt.type == 8) {
              final pid = pkt.payload.sublist(0, 2);
              socket.add([0x90, 0x03, pid[0], pid[1], 0x00]);
            }
          }
        }
      }).asFuture());

      final tap = MeshtasticMqttTap(
        host: '127.0.0.1',
        port: port,
        connectTimeout: const Duration(seconds: 2),
      );
      try {
        expect(await tap.connect(), isFalse);
        expect(tap.lastError, isNotNull);
        expect(tap.isConnected, isFalse);
        expect(await tap.connect(), isTrue);
        expect(tap.isConnected, isTrue);
        expect(tap.isSubscribed, isTrue);
        expect(connections, 2);
      } finally {
        await tap.disconnect();
        await server.close();
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('final delta check (round 3)', () {
    test('S1: broker drop mid-handshake leaves no retry behind after '
        'a failed manual connect()', () async {
      // Fake broker: CONNACKs every connection, then drops the
      // socket ~100 ms later — mid-handshake, before any SUBACK.
      // _onDisconnected fires during connect() and arms a retry
      // timer; the SUBACK timeout then fails connect(). Before
      // the fix the timer survived the teardown and the tap
      // auto-retried anyway, contradicting "a manual connect()
      // supersedes any pending tap-owned retry".
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final port = server.port;
      unawaited(server.listen((Socket socket) async {
        final buf = <int>[];
        try {
          await for (final data in socket) {
            buf.addAll(data);
            while (true) {
              final pkt = _tryParseMqttPacket(buf);
              if (pkt == null) break;
              var i = 1;
              var mult = 1;
              var remaining = 0;
              while (true) {
                final b = buf[i++];
                remaining += (b & 0x7F) * mult;
                mult *= 128;
                if ((b & 0x80) == 0) break;
              }
              buf.removeRange(0, i + remaining);
              if (pkt.type == 1) {
                socket.add([0x20, 0x02, 0x00, 0x00]);
                // Drop mid-handshake, before the SUBACK.
                await Future<void>.delayed(
                    const Duration(milliseconds: 100));
                try {
                  await socket.close();
                } catch (_) {}
              }
              // SUBSCRIBE (type 8): never answered.
            }
          }
        } catch (_) {
          // Socket went away mid-handshake — expected.
        }
      }).asFuture());

      final tap = MeshtasticMqttTap(
        host: '127.0.0.1',
        port: port,
        subscribeTimeout: const Duration(seconds: 1),
        // Short backoff so the test can prove the timer is gone
        // without waiting out the default 5 s first delay.
        reconnectDelays: const [Duration(seconds: 2)],
      );
      try {
        expect(await tap.connect(), isFalse);
        expect(tap.isConnected, isFalse);
        // The drop really happened mid-handshake: the tap saw it
        // (and before the fix had armed a retry timer for it).
        expect(tap.disconnectCount, greaterThanOrEqualTo(1));
        // Wait past the 2 s backoff: a live timer would have
        // fired a reconnect attempt by now.
        await Future<void>.delayed(const Duration(milliseconds: 2500));
        expect(tap.reconnectAttempts, 0);
        expect(tap.isConnected, isFalse);
      } finally {
        await tap.disconnect();
        await server.close();
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('N1: a retry timer firing during a manual connect() does '
        'not burn a circuit-breaker count', () async {
      // Fake broker: CONNACKs every connection, then drops the
      // socket ~100 ms later — mid-handshake, before any SUBACK.
      // The drop arms a retry timer DURING the manual connect()
      // (which is still awaiting the 2 s SUBACK timeout); with the
      // 100 ms backoff the timer fires repeatedly against the
      // _connecting guard while the manual connect is in flight.
      // Before the fix the first two guard hits burned both
      // breaker counts (maxReconnectAttempts: 2) and retries froze
      // at 2 attempts; with the fix the guard hits keep coming
      // and the count grows well past 2.
      //
      // (An earlier form of this test armed the timer from a
      // drop of a PREVIOUS connection — that cannot work: a
      // manual connect() tears the old client down on entry,
      // detaching onDisconnected, so the later drop is never
      // observed and no timer is ever armed.)
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final port = server.port;
      unawaited(server.listen((Socket socket) async {
        final buf = <int>[];
        try {
          await for (final data in socket) {
            buf.addAll(data);
            while (true) {
              final pkt = _tryParseMqttPacket(buf);
              if (pkt == null) break;
              var i = 1;
              var mult = 1;
              var remaining = 0;
              while (true) {
                final b = buf[i++];
                remaining += (b & 0x7F) * mult;
                mult *= 128;
                if ((b & 0x80) == 0) break;
              }
              buf.removeRange(0, i + remaining);
              if (pkt.type == 1) {
                socket.add([0x20, 0x02, 0x00, 0x00]);
                // Drop mid-handshake, before the SUBACK.
                await Future<void>.delayed(
                    const Duration(milliseconds: 100));
                try {
                  await socket.close();
                } catch (_) {}
              }
              // SUBSCRIBE (type 8): never answered.
            }
          }
        } catch (_) {
          // Socket went away mid-handshake — expected.
        }
      }).asFuture());

      final tap = MeshtasticMqttTap(
        host: '127.0.0.1',
        port: port,
        subscribeTimeout: const Duration(seconds: 2),
        reconnectDelays: const [Duration(milliseconds: 100)],
        maxReconnectAttempts: 2,
      );
      try {
        expect(await tap.connect(), isFalse);
        // The drop really happened mid-handshake.
        expect(tap.disconnectCount, greaterThanOrEqualTo(1));
        // The manual connect was in flight for ~2 s while the
        // 100 ms retry timer kept firing against the guard:
        // ~18 guard hits with the fix, exactly 2 without it
        // (breaker tripped, retries frozen).
        expect(tap.reconnectAttempts, greaterThan(2));
        expect(tap.isConnected, isFalse);
      } finally {
        await tap.disconnect();
        await server.close();
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
