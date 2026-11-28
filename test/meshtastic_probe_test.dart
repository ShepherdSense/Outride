import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:outride/services/meshtastic_probe.dart';
import 'package:outride/services/meshtastic_proto.dart';

/// Spy sender for the startPeriodic tests: records the channel
/// each tick passes to [sendOnce] instead of opening a socket. When
/// [stallGate] is set, a send never completes — simulating a
/// stalled peer (a `socket.flush()` with no timeout that never
/// returns) so the reentrancy guard can be observed.
class _ProbeSenderSpy extends MeshtasticProbeSender {
  _ProbeSenderSpy()
      : super(
          host: '127.0.0.1',
          port: 1,
          enabled: true,
          cadence: const Duration(minutes: 1),
        );

  int sendCalls = 0;
  int? lastChannel;
  Completer<void>? stallGate;

  @override
  Future<bool> sendOnce({
    required int senderNodeNum,
    required List<ProbeNeighborObservation> neighbors,
    double observedUtilizationPercent = 0,
    int? channel,
    DateTime? at,
  }) async {
    sendCalls++;
    lastChannel = channel;
    final gate = stallGate;
    if (gate != null) await gate.future;
    return true;
  }
}

/// Read one framed ToRadio packet off [bytes] and return the
/// MeshPacket.channel field (-1 when the frame sets no channel).
int _frameChannel(List<int> bytes) {
  expect(bytes[0], 0x94);
  expect(bytes[1], 0xC3);
  final len = (bytes[2] << 8) | bytes[3];
  expect(len, bytes.length - 4);
  final toRadio =
      MeshProtoReader(Uint8List.fromList(bytes.sublist(4)));
  toRadio.readTag();
  final packetBytes = toRadio.readBytes();
  final r = MeshProtoReader(packetBytes);
  var channelSeen = -1;
  while (!r.done) {
    final tag = r.readTag();
    if ((tag >> 3) == 3 && (tag & 7) == 0) {
      channelSeen = r.readVarint();
    } else {
      r.skip(tag & 7);
    }
  }
  return channelSeen;
}

void main() {
  group('probe payload encode/decode', () {
    test('round-trip with several neighbors, negative RSSI kept', () {
      final at = DateTime.fromMillisecondsSinceEpoch(1790000000 * 1000);
      final bytes = MeshtasticProbePayload.encode(
        senderNodeNum: 0x11111111,
        timestamp: at,
        neighbors: const [
          ProbeNeighborObservation(nodeNum: 0x22222222, snr: 5.5, rssi: -100),
          ProbeNeighborObservation(nodeNum: 0x33333333, snr: -2.25, rssi: -108),
          ProbeNeighborObservation(nodeNum: 0x44444444, snr: 0.0, rssi: -90),
        ],
      );
      final r = MeshtasticProbePayload.decode(bytes);
      expect(r.senderNodeNum, 0x11111111);
      expect(r.timestamp, at);
      expect(r.neighbors.length, 3);
      expect(r.neighbors[0].nodeNum, 0x22222222);
      expect(r.neighbors[0].snr, closeTo(5.5, 1e-6));
      expect(r.neighbors[0].rssi, -100.0);
      expect(r.neighbors[1].snr, closeTo(-2.25, 1e-6));
      expect(r.neighbors[1].rssi, -108.0);
    });

    test('empty neighbor list round-trips', () {
      final bytes = MeshtasticProbePayload.encode(
        senderNodeNum: 7,
        timestamp: DateTime.fromMillisecondsSinceEpoch(1000 * 1000),
        neighbors: const [],
      );
      final r = MeshtasticProbePayload.decode(bytes);
      expect(r.senderNodeNum, 7);
      expect(r.neighbors, isEmpty);
    });

    test('neighbor count is capped at 16', () {
      final bytes = MeshtasticProbePayload.encode(
        senderNodeNum: 7,
        timestamp: DateTime.now(),
        neighbors: [
          for (var i = 0; i < 20; i++)
            ProbeNeighborObservation(nodeNum: i + 1, snr: 1.0, rssi: -90),
        ],
      );
      expect(MeshtasticProbePayload.decode(bytes).neighbors.length, 16);
      // 14 header + 16*10 = 174 bytes, under the 233-byte budget.
      expect(bytes.length, 174);
    });

    test('RSSI is clamped to [-200, 0] on encode', () {
      final bytes = MeshtasticProbePayload.encode(
        senderNodeNum: 7,
        timestamp: DateTime.now(),
        neighbors: const [
          ProbeNeighborObservation(nodeNum: 1, snr: 1.0, rssi: 5.0),
          ProbeNeighborObservation(nodeNum: 2, snr: 1.0, rssi: -250.0),
        ],
      );
      final r = MeshtasticProbePayload.decode(bytes);
      expect(r.neighbors[0].rssi, 0.0);
      expect(r.neighbors[1].rssi, -200.0);
    });

    test('non-finite SNR throws FormatException (B1)', () {
      // A mesh node or spoofed packet with SNR bits 0x7FC00000
      // (NaN) must never decode: it would poison the series and
      // the neighbor table for up to 30 min.
      final bytes = MeshtasticProbePayload.encode(
        senderNodeNum: 7,
        timestamp: DateTime.now(),
        neighbors: const [
          ProbeNeighborObservation(nodeNum: 1, snr: 1.0, rssi: -90),
        ],
      );
      // Overwrite the triple's float32 SNR with a NaN bit pattern.
      final nan = ByteData(4)..setUint32(0, 0x7FC00000, Endian.little);
      bytes.setRange(14 + 4, 14 + 8, nan.buffer.asUint8List());
      expect(() => MeshtasticProbePayload.decode(bytes),
          throwsFormatException);
      // +Inf is likewise rejected.
      final inf = ByteData(4)..setUint32(0, 0x7F800000, Endian.little);
      bytes.setRange(14 + 4, 14 + 8, inf.buffer.asUint8List());
      expect(() => MeshtasticProbePayload.decode(bytes),
          throwsFormatException);
    });

    test('bad magic throws FormatException', () {
      final bytes = MeshtasticProbePayload.encode(
        senderNodeNum: 7,
        timestamp: DateTime.now(),
        neighbors: const [],
      );
      bytes[0] = 0x58; // 'X'
      expect(() => MeshtasticProbePayload.decode(bytes),
          throwsFormatException);
    });

    test('unknown version throws FormatException', () {
      final bytes = MeshtasticProbePayload.encode(
        senderNodeNum: 7,
        timestamp: DateTime.now(),
        neighbors: const [],
      );
      bytes[4] = 99;
      expect(() => MeshtasticProbePayload.decode(bytes),
          throwsFormatException);
    });

    test('truncated payload throws FormatException', () {
      final bytes = MeshtasticProbePayload.encode(
        senderNodeNum: 7,
        timestamp: DateTime.now(),
        neighbors: const [
          ProbeNeighborObservation(nodeNum: 1, snr: 1.0, rssi: -90),
        ],
      );
      expect(
          () => MeshtasticProbePayload.decode(
              bytes.sublist(0, bytes.length - 3)),
          throwsFormatException);
      expect(() => MeshtasticProbePayload.decode(bytes.sublist(0, 5)),
          throwsFormatException);
    });
  });

  group('ToRadio frame', () {
    test('frame decodes back to a broadcast packet on portnum 300', () {
      final frame = MeshtasticProbePayload.buildToRadioFrame(
        senderNodeNum: 0x11111111,
        timestamp: DateTime.fromMillisecondsSinceEpoch(1790000000 * 1000),
        neighbors: const [
          ProbeNeighborObservation(nodeNum: 0x22222222, snr: 5.5, rssi: -100),
        ],
      );
      // Framing: [0x94, 0xC3, lenMSB, lenLSB] + ToRadio protobuf.
      expect(frame[0], 0x94);
      expect(frame[1], 0xC3);
      final len = (frame[2] << 8) | frame[3];
      expect(len, frame.length - 4);
      // ToRadio{packet=1}: field 1 LEN.
      final toRadio =
          MeshProtoReader(Uint8List.fromList(frame.sublist(4)));
      final tag = toRadio.readTag();
      expect(tag >> 3, 1);
      expect(tag & 7, 2);
      final packetBytes = toRadio.readBytes();
      final info = MeshPacketInfo.decode(packetBytes);
      expect(info.to, 0xFFFFFFFF); // broadcast
      expect(info.portnum, outrideProbePortnum);
      final report =
          MeshtasticProbePayload.decode(info.payload!);
      expect(report.senderNodeNum, 0x11111111);
      expect(report.neighbors.length, 1);
      expect(report.neighbors.first.nodeNum, 0x22222222);
      expect(report.neighbors.first.rssi, -100.0);
    });

    test('channel parameter sets MeshPacket.channel; omitted = primary',
        () {
      final withChannel = MeshtasticProbePayload.buildToRadioFrame(
        senderNodeNum: 7,
        timestamp: DateTime.now(),
        neighbors: const [],
        channel: 2,
      );
      final toRadio =
          MeshProtoReader(Uint8List.fromList(withChannel.sublist(4)));
      toRadio.readTag();
      final packetBytes = toRadio.readBytes();
      // Scan the packet fields for channel (field 3, varint) == 2.
      final r = MeshProtoReader(packetBytes);
      var channelSeen = -1;
      while (!r.done) {
        final tag = r.readTag();
        if ((tag >> 3) == 3 && (tag & 7) == 0) {
          channelSeen = r.readVarint();
        } else {
          r.skip(tag & 7);
        }
      }
      expect(channelSeen, 2);
      // No channel param: no field 3 at all (primary by default).
      final primary = MeshtasticProbePayload.buildToRadioFrame(
        senderNodeNum: 7,
        timestamp: DateTime.now(),
        neighbors: const [],
      );
      final tr2 = MeshProtoReader(Uint8List.fromList(primary.sublist(4)));
      tr2.readTag();
      final pb2 = tr2.readBytes();
      final r2 = MeshProtoReader(pb2);
      var anyChannel = false;
      while (!r2.done) {
        final tag = r2.readTag();
        if ((tag >> 3) == 3) anyChannel = true;
        r2.skip(tag & 7);
      }
      expect(anyChannel, isFalse);
    });

    test('hopLimit is clamped to the 0-7 wire range', () {
      for (final hop in [9, 100]) {
        final frame = MeshtasticProbePayload.buildToRadioFrame(
          senderNodeNum: 7,
          timestamp: DateTime.now(),
          neighbors: const [],
          hopLimit: hop,
        );
        final tr = MeshProtoReader(Uint8List.fromList(frame.sublist(4)));
        tr.readTag();
        final pb = tr.readBytes();
        final r = MeshProtoReader(pb);
        var hopSeen = -1;
        while (!r.done) {
          final tag = r.readTag();
          if ((tag >> 3) == 9 && (tag & 7) == 0) {
            hopSeen = r.readVarint();
          } else {
            r.skip(tag & 7);
          }
        }
        expect(hopSeen, 7);
      }
    });

    test('channel outside 0-7 throws; 0 and 7 encode (re-review item 9)',
        () {
      // The wire range is 0-7; a bogus index used to encode
      // silently (only negatives threw — and the negative case had
      // no test at all).
      for (final bad in [-1, 8, 100]) {
        expect(
            () => MeshtasticProbePayload.buildToRadioFrame(
                  senderNodeNum: 7,
                  timestamp: DateTime.now(),
                  neighbors: const [],
                  channel: bad,
                ),
            throwsArgumentError);
      }
      // The edges of the range are fine.
      expect(
          _frameChannel(MeshtasticProbePayload.buildToRadioFrame(
            senderNodeNum: 7,
            timestamp: DateTime.now(),
            neighbors: const [],
            channel: 0,
          )),
          0);
      expect(
          _frameChannel(MeshtasticProbePayload.buildToRadioFrame(
            senderNodeNum: 7,
            timestamp: DateTime.now(),
            neighbors: const [],
            channel: 7,
          )),
          7);
    });
  });

  group('channel-utilization guard', () {
    test('10 nodes at 5 min on LongFast adds ~4.8% incl. relays', () {
      final added = ProbeChannelGuard.addedUtilization(
        nodeCount: 10,
        cadence: const Duration(minutes: 5),
      );
      // Origin-only 10 * 0.477 / 300 = 0.0159; x relay factor 3.
      expect(added, closeTo(0.0477, 1e-4));
      expect(
          ProbeChannelGuard.maySend(
            nodeCount: 10,
            cadence: const Duration(minutes: 5),
            observedUtilizationPercent: 5.0,
          ),
          isTrue);
    });

    test('10 nodes at 1 min on LongFast is refused once relays count',
        () {
      // Origin-only would compute 7.95% and allow the send; with
      // the relay factor the true load is ~24%, blowing the cap.
      final added = ProbeChannelGuard.addedUtilization(
        nodeCount: 10,
        cadence: const Duration(minutes: 1),
      );
      expect(added, closeTo(0.2385, 1e-4));
      expect(
          ProbeChannelGuard.maySend(
            nodeCount: 10,
            cadence: const Duration(minutes: 1),
          ),
          isFalse);
    });

    test('a realistic telemetry ChUtil percent still allows a send',
        () {
      // DeviceMetrics.channel_utilization is a PERCENT (live values
      // 2.655, 15.87). Passing 2.655% must allow a send; passing it
      // as a fraction (2.655 > 0.10) used to refuse every probe.
      final s = MeshtasticProbeSender(
        host: '127.0.0.1',
        port: 1,
        enabled: true,
        nodeCountEstimate: 10,
        cadence: const Duration(minutes: 5),
      );
      expect(s.guardAllows(observedUtilizationPercent: 2.655), isTrue);
      expect(
          ProbeChannelGuard.maySend(
            nodeCount: 10,
            cadence: const Duration(minutes: 5),
            observedUtilizationPercent: 2.655,
          ),
          isTrue);
    });

    test('guard refuses when projection would exceed 10%', () {
      expect(
          ProbeChannelGuard.maySend(
            nodeCount: 10,
            cadence: const Duration(minutes: 5),
            observedUtilizationPercent: 9.0,
          ),
          isFalse);
      // A busy mesh at 5% observed + 50 probing nodes refuses.
      expect(
          ProbeChannelGuard.maySend(
            nodeCount: 50,
            cadence: const Duration(minutes: 1),
            observedUtilizationPercent: 5.0,
          ),
          isFalse);
    });

    test('MediumFast airtime is ~3.4x cheaper', () {
      final longFast = ProbeChannelGuard.addedUtilization(
        nodeCount: 10,
        cadence: const Duration(minutes: 5),
        airtimeSecs: 0.477,
      );
      final mediumFast = ProbeChannelGuard.addedUtilization(
        nodeCount: 10,
        cadence: const Duration(minutes: 5),
        airtimeSecs: 0.140,
      );
      expect(longFast / mediumFast, closeTo(0.477 / 0.140, 0.01));
      // 10 * 0.140 / 300 * relay factor 3 = 0.014.
      expect(mediumFast, closeTo(0.014, 1e-4));
    });

    test('sub-second cadence is real utilization, not free (re-review item 7)',
        () {
      // cadence.inSeconds <= 0 used to return 0 for a sub-second
      // cadence, so a caller passing 500 ms got "free" utilization
      // and maySend allowed it. Computed in milliseconds, 10 nodes
      // at 500 ms is 10 * 0.477 / 0.5 * 3 = 28.62 — refused.
      final added = ProbeChannelGuard.addedUtilization(
        nodeCount: 10,
        cadence: const Duration(milliseconds: 500),
      );
      expect(added, closeTo(28.62, 1e-9));
      expect(
          ProbeChannelGuard.maySend(
            nodeCount: 10,
            cadence: const Duration(milliseconds: 500),
          ),
          isFalse);
      // Whole-second values are unchanged by the millisecond math.
      expect(
          ProbeChannelGuard.addedUtilization(
            nodeCount: 10,
            cadence: const Duration(minutes: 5),
          ),
          closeTo(0.0477, 1e-4));
      // Zero / negative cadence still yields 0 (no division).
      expect(
          ProbeChannelGuard.addedUtilization(
            nodeCount: 10,
            cadence: Duration.zero,
          ),
          0);
    });
  });

  group('MeshtasticProbeSender', () {
    test('probing is OFF by default and sendOnce refuses', () async {
      final s = MeshtasticProbeSender(host: '127.0.0.1', port: 1);
      expect(s.enabled, isFalse);
      expect(
          await s.sendOnce(
            senderNodeNum: 7,
            neighbors: const [],
          ),
          isFalse);
      expect(s.lastError, contains('disabled'));
      expect(s.tcpFramesWritten, 0);
    });

    test('cadence clamps to 1-5 min', () {
      expect(
          MeshtasticProbeSender(host: 'x', cadence: const Duration(seconds: 30))
              .cadence,
          const Duration(minutes: 1));
      expect(
          MeshtasticProbeSender(host: 'x', cadence: const Duration(minutes: 10))
              .cadence,
          const Duration(minutes: 5));
      expect(
          MeshtasticProbeSender(host: 'x', cadence: const Duration(minutes: 3))
              .cadence,
          const Duration(minutes: 3));
    });

    test('guard refusal is surfaced, not silent', () async {
      final s = MeshtasticProbeSender(
        host: '127.0.0.1',
        port: 1,
        enabled: true,
        nodeCountEstimate: 50,
        cadence: const Duration(minutes: 1),
      );
      expect(
          await s.sendOnce(
            senderNodeNum: 7,
            neighbors: const [],
            observedUtilizationPercent: 5.0,
          ),
          isFalse);
      expect(s.guardRefusals, 1);
      expect(s.lastError, contains('guard refused'));
    });

    test('TCP failure is surfaced in lastError', () async {
      final s = MeshtasticProbeSender(
        host: '127.0.0.1',
        port: 1, // closed port: connection refused, fast
        enabled: true,
      );
      expect(
          await s.sendOnce(senderNodeNum: 7, neighbors: const []),
          isFalse);
      expect(s.lastError, contains('failed'));
    });

    test('a throwing utilization callback does not kill the timer',
        () {
      // startPeriodic wraps the observed-utilization callback: a
      // throw is recorded in lastError, not an unhandled async
      // error escaping the timer tick. Disabling mid-run cancels
      // the timer on the next tick instead of overwriting
      // lastError every tick.
      fakeAsync((async) {
        final s = MeshtasticProbeSender(
          host: '127.0.0.1',
          port: 1,
          enabled: true,
          cadence: const Duration(minutes: 1),
        );
        s.startPeriodic(
          senderNodeNum: 7,
          neighbors: () => const [],
          observedUtilizationPercent: () => throw StateError('boom'),
        );
        async.elapse(const Duration(minutes: 1));
        expect(s.lastError, contains('utilization supplier failed'));
        expect(s.isRunning, isTrue);
        s.enabled = false;
        async.elapse(const Duration(minutes: 1));
        expect(s.isRunning, isFalse);
        s.dispose();
      });
    });

    test('startPeriodic threads its channel to sendOnce (re-review item 4)',
        () {
      // The periodic path is the one that actually runs; it used
      // to always probe the primary channel even when the
      // deployment channel was secondary.
      fakeAsync((async) {
        final s = _ProbeSenderSpy();
        s.startPeriodic(
          senderNodeNum: 7,
          neighbors: () => const [],
          channel: 2,
        );
        async.elapse(const Duration(minutes: 1));
        expect(s.sendCalls, 1);
        expect(s.lastChannel, 2);
        s.dispose();
      });
    });

    test('startPeriodic sends the frame on the given channel', () async {
      // Real socket end of item 4: sendOnce(channel: 2) puts
      // channel 2 in the MeshPacket on the wire.
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final received = Completer<List<int>>();
      unawaited(server.listen((Socket socket) async {
        final buf = <int>[];
        await for (final data in socket) {
          buf.addAll(data);
        }
        if (!received.isCompleted) received.complete(buf);
      }).asFuture());
      final s = MeshtasticProbeSender(
        host: '127.0.0.1',
        port: server.port,
        enabled: true,
      );
      try {
        expect(
            await s.sendOnce(
              senderNodeNum: 7,
              neighbors: const [],
              channel: 2,
            ),
            isTrue);
        final bytes = await received.future
            .timeout(const Duration(seconds: 5));
        expect(_frameChannel(bytes), 2);
        expect(s.tcpFramesWritten, 1);
      } finally {
        s.dispose();
        await server.close();
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a stalled tick does not open a second connection (re-review item 3)',
        () {
      // The Timer.periodic callback is async and sendOnce's
      // socket.flush() has no timeout: a stalled peer used to let
      // one tick overlap the next, opening a second concurrent
      // TCP 4403 connection and double-sending. The spy's stall
      // gate stands in for the stalled peer (the send never
      // completes); the second tick must be skipped, not run.
      fakeAsync((async) {
        final s = _ProbeSenderSpy();
        s.stallGate = Completer<void>();
        s.startPeriodic(
          senderNodeNum: 7,
          neighbors: () => const [],
        );
        async.elapse(const Duration(minutes: 1));
        expect(s.sendCalls, 1);
        expect(s.overlappingTicksSkipped, 0);
        // Second tick while the first send is still stalled.
        async.elapse(const Duration(minutes: 1));
        expect(s.sendCalls, 1);
        expect(s.overlappingTicksSkipped, 1);
        // Third tick: still stalled, still skipped.
        async.elapse(const Duration(minutes: 1));
        expect(s.sendCalls, 1);
        expect(s.overlappingTicksSkipped, 2);
        // The peer finally answers: the stalled send completes,
        // and the next tick sends again.
        s.stallGate!.complete();
        async.elapse(const Duration(minutes: 1));
        expect(s.sendCalls, 2);
        expect(s.overlappingTicksSkipped, 2);
        s.dispose();
      });
    });

    test('stop() resets the in-flight tick flag so a restart sends '
        'on its first tick (final delta N2)', () {
      // Restarting startPeriodic while a tick is stalled used to
      // make the new timer's first tick count as skipped: stop()
      // cancelled the timer but left _tickInFlight set. The spy's
      // stall gate stands in for the stalled peer.
      fakeAsync((async) {
        final s = _ProbeSenderSpy();
        final gate = Completer<void>();
        s.stallGate = gate;
        s.startPeriodic(
          senderNodeNum: 7,
          neighbors: () => const [],
        );
        async.elapse(const Duration(minutes: 1));
        expect(s.sendCalls, 1);
        // Second tick while the first send is still stalled.
        async.elapse(const Duration(minutes: 1));
        expect(s.sendCalls, 1);
        expect(s.overlappingTicksSkipped, 1);
        // Restart while the first tick is still stalled. The new
        // run's sends complete at once (no gate); without the fix
        // the new timer's first tick is skipped and nothing sends.
        s.stop();
        s.stallGate = null;
        s.startPeriodic(
          senderNodeNum: 7,
          neighbors: () => const [],
        );
        async.elapse(const Duration(minutes: 1));
        expect(s.sendCalls, 2);
        expect(s.overlappingTicksSkipped, 1);
        // The old stalled send finally completes: its finally
        // must not corrupt the new run — the next tick still sends.
        gate.complete();
        async.elapse(const Duration(minutes: 1));
        expect(s.sendCalls, 3);
        expect(s.overlappingTicksSkipped, 1);
        s.dispose();
      });
    });
  });
}
