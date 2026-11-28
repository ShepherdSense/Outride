import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/services/meshtastic_driver.dart';
import 'package:outride/services/meshtastic_link_series.dart';
import 'package:outride/services/meshtastic_mesh_config.dart';
import 'package:outride/services/meshtastic_probe.dart';

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

List<int> _frame(List<int> payload) => [
      0x94,
      0xC3,
      (payload.length >> 8) & 0xFF,
      payload.length & 0xFF,
      ...payload,
    ];

List<int> _meshPacketFrame({
  int from = 0x11111111,
  double? snr,
  int? rssi,
  int? hopLimit,
  int? hopStart,
  int portnum = 1,
  List<int>? payloadBytes,
}) {
  final data = [
    ..._u32(1, portnum),
    ..._lenField(2, payloadBytes ?? 'hi'.codeUnits),
  ];
  final packet = [
    ..._fixed32(1, from),
    ..._fixed32(2, 0xFFFFFFFF),
    ..._lenField(4, data),
    if (snr != null) ..._float32(8, snr),
    if (hopLimit != null) ..._u32(9, hopLimit),
    if (rssi != null) ..._sint32Field(12, rssi),
    if (hopStart != null) ..._u32(15, hopStart),
  ];
  return _frame(_lenField(2, packet));
}

void main() {
  group('driver per-packet link stream', () {
    test('every packet is series-recorded with SNR + RSSI + hop count',
        () {
      final d = MeshtasticDriver(host: '127.0.0.1', port: 4403);
      d.ingestBytesForTest(_meshPacketFrame(
        snr: 7.5,
        rssi: -108,
        hopLimit: 1,
        hopStart: 3,
      ));
      final series = d.linkSeries.seriesFor(
          0x11111111, MeshLinkSeries.localNode);
      expect(series.length, 1);
      expect(series.first.snr, closeTo(7.5, 1e-6));
      expect(series.first.rssi, -108.0);
      expect(series.first.hopCount, 2);
      expect(series.first.portnum, 1);
      // The direct LinkSample carries RSSI too.
      final samples = d.buildSamplesForTest();
      final direct = samples.where((s) =>
          s.fromNode == 'meshtastic:local' &&
          s.toNode == 'meshtastic:!11111111');
      expect(direct.length, 1);
      expect(direct.first.snr, closeTo(7.5, 1e-6));
      expect(direct.first.rssi, -108.0);
      expect(direct.first.authenticated, isFalse); // default: untrusted
      d.dispose();
    });

    test('field 9 is hop_limit, NOT RSSI (deep-dive regression)', () {
      final d = MeshtasticDriver(host: '127.0.0.1', port: 4403);
      // hop_limit 7, no field 12 at all: RSSI must be null, not 7.
      d.ingestBytesForTest(_meshPacketFrame(snr: 3.0, hopLimit: 7));
      final series = d.linkSeries.seriesFor(
          0x11111111, MeshLinkSeries.localNode);
      expect(series.length, 1);
      expect(series.first.rssi, isNull);
      expect(series.first.snr, closeTo(3.0, 1e-6));
      d.dispose();
    });

    test('hop count is null without hop_start', () {
      final d = MeshtasticDriver(host: '127.0.0.1', port: 4403);
      d.ingestBytesForTest(_meshPacketFrame(snr: 1.0, hopLimit: 2));
      expect(
          d.linkSeries
              .seriesFor(0x11111111, MeshLinkSeries.localNode)
              .first
              .hopCount,
          isNull);
      d.dispose();
    });

    test('my_info names the real local node in series edges', () {
      final d = MeshtasticDriver(host: '127.0.0.1', port: 4403);
      final myInfo = _u32(1, 0x99999999);
      d.ingestBytesForTest(_frame(_lenField(3, myInfo)));
      expect(d.localNodeNum, 0x99999999);
      d.ingestBytesForTest(_meshPacketFrame(snr: 2.0, rssi: -100));
      expect(
          d.linkSeries.seriesFor(0x11111111, 0x99999999).length, 1);
      d.dispose();
    });

    test('telemetry ChUtil/AirUtil are consumed into the series', () {
      final d = MeshtasticDriver(host: '127.0.0.1', port: 4403);
      // Telemetry{device_metrics=2} / DeviceMetrics{chUtil=3, airUtil=4}
      final metrics = [
        ..._float32(3, 12.5),
        ..._float32(4, 3.25),
      ];
      final telemetry = _lenField(2, metrics);
      d.ingestBytesForTest(_meshPacketFrame(
        snr: 6.0,
        rssi: -99,
        hopLimit: 0,
        hopStart: 3,
        portnum: 67,
        payloadBytes: telemetry,
      ));
      final series = d.linkSeries.seriesFor(
          0x11111111, MeshLinkSeries.localNode);
      // Exactly one series record for the packet (no double-count).
      expect(series.length, 1);
      expect(series.first.chUtil, closeTo(12.5, 1e-6));
      expect(series.first.airUtil, closeTo(3.25, 1e-6));
      expect(series.first.portnum, 67);
      expect(d.channelUtilization.latest(0x11111111)!.chUtil,
          closeTo(12.5, 1e-6));
      d.dispose();
    });

    test('probe reports decode into reporter -> heard edges', () {
      final d = MeshtasticDriver(host: '127.0.0.1', port: 4403);
      final report = MeshtasticProbePayload.encode(
        senderNodeNum: 0x11111111,
        timestamp: DateTime.now(),
        neighbors: const [
          ProbeNeighborObservation(nodeNum: 0x22222222, snr: 5.5, rssi: -100),
        ],
      );
      d.ingestBytesForTest(_meshPacketFrame(
        snr: 8.0,
        rssi: -95,
        portnum: 300,
        payloadBytes: report,
      ));
      // The probe packet itself: sender -> local.
      expect(
          d.linkSeries
              .seriesFor(0x11111111, MeshLinkSeries.localNode)
              .length,
          1);
      // The reported observation: reporter -> heard (sender ->
      // neighbor) — the NeighborInfo / LinkSample convention, so
      // the series edge and the neighbor table agree on direction.
      final edge = d.linkSeries.seriesFor(0x11111111, 0x22222222);
      expect(edge.length, 1);
      expect(edge.first.snr, closeTo(5.5, 1e-6));
      expect(edge.first.rssi, -100.0);
      expect(edge.first.portnum, 300);
      // And the neighbor edge shows up as a LinkSample too.
      final samples = d.buildSamplesForTest();
      expect(
          samples.any((s) =>
              s.fromNode == 'meshtastic:!11111111' &&
              s.toNode == 'meshtastic:!22222222' &&
              s.snr == 5.5),
          isTrue);
      d.dispose();
    });

    test('NaN-SNR probe report creates no probe edge (B1)', () {
      // A portnum-300 report with SNR bits 0x7FC00000 (NaN) must
      // not poison the series or the neighbor table: only the
      // packet itself is series-recorded.
      final d = MeshtasticDriver(host: '127.0.0.1', port: 4403);
      final report = MeshtasticProbePayload.encode(
        senderNodeNum: 0x11111111,
        timestamp: DateTime.now(),
        neighbors: const [
          ProbeNeighborObservation(nodeNum: 0x22222222, snr: 5.5, rssi: -100),
        ],
      );
      final nan = ByteData(4)..setUint32(0, 0x7FC00000, Endian.little);
      report.setRange(14 + 4, 14 + 8, nan.buffer.asUint8List());
      d.ingestBytesForTest(_meshPacketFrame(
        snr: 8.0,
        rssi: -95,
        portnum: 300,
        payloadBytes: report,
      ));
      expect(
          d.linkSeries
              .seriesFor(0x11111111, MeshLinkSeries.localNode)
              .length,
          1);
      expect(d.linkSeries.edgeCount, 1);
      expect(d.linkSeries.seriesFor(0x11111111, 0x22222222), isEmpty);
      expect(d.buildSamplesForTest().any((s) =>
          s.toNode == 'meshtastic:!22222222'), isFalse);
      expect(d.malformedCount, 1);
      d.dispose();
    });

    test('probe report whose sender mismatches the packet is dropped',
        () {
      final d = MeshtasticDriver(host: '127.0.0.1', port: 4403);
      // Report claims sender 0x33333333 but the packet came from
      // 0x11111111 — spoofed or misaddressed; drop the report.
      final report = MeshtasticProbePayload.encode(
        senderNodeNum: 0x33333333,
        timestamp: DateTime.now(),
        neighbors: const [
          ProbeNeighborObservation(nodeNum: 0x22222222, snr: 5.5, rssi: -100),
        ],
      );
      d.ingestBytesForTest(_meshPacketFrame(
        snr: 8.0,
        rssi: -95,
        portnum: 300,
        payloadBytes: report,
      ));
      expect(
          d.linkSeries
              .seriesFor(0x11111111, MeshLinkSeries.localNode)
              .length,
          1);
      expect(d.linkSeries.edgeCount, 1);
      expect(d.malformedCount, 1);
      d.dispose();
    });

    test('Data with a portnum but no payload keeps the portnum', () {
      final d = MeshtasticDriver(host: '127.0.0.1', port: 4403);
      // Data{portnum=67} with no payload field at all.
      final data = _u32(1, 67);
      final packet = [
        ..._fixed32(1, 0x11111111),
        ..._fixed32(2, 0xFFFFFFFF),
        ..._lenField(4, data),
        ..._float32(8, 4.0),
      ];
      d.ingestBytesForTest(_frame(_lenField(2, packet)));
      final series = d.linkSeries.seriesFor(
          0x11111111, MeshLinkSeries.localNode);
      expect(series.length, 1);
      expect(series.first.portnum, 67);
      d.dispose();
    });

    test('hostile framer input never crashes or corrupts the series',
        () {
      final d = MeshtasticDriver(host: '127.0.0.1', port: 4403);
      // Truncated varint (0x80-run with no terminator).
      d.ingestBytesForTest([0x94, 0xC3, 0x00, 0x10, 0x80, 0x80, 0x80]);
      // Length field far larger than the buffer.
      d.ingestBytesForTest(
          [0x94, 0xC3, 0xFF, 0xFF, 0x01, 0x02, 0x03]);
      // Random bytes, no frame header at all.
      d.ingestBytesForTest(
          List<int>.generate(64, (i) => (i * 37 + 11) % 256));
      // A valid packet afterwards still parses: the framer
      // resynced instead of wedging.
      d.ingestBytesForTest(_meshPacketFrame(snr: 7.5, rssi: -108));
      final series = d.linkSeries.seriesFor(
          0x11111111, MeshLinkSeries.localNode);
      expect(series.length, 1);
      expect(series.first.snr, closeTo(7.5, 1e-6));
      d.dispose();
    });

    test('malformed probe payload does not break packet parsing', () {
      final d = MeshtasticDriver(host: '127.0.0.1', port: 4403);
      d.ingestBytesForTest(_meshPacketFrame(
        snr: 8.0,
        portnum: 300,
        payloadBytes: [0x58, 0x58, 0x58, 0x58], // bad magic
      ));
      // Packet still series-recorded; no probe edge created.
      expect(
          d.linkSeries
              .seriesFor(0x11111111, MeshLinkSeries.localNode)
              .length,
          1);
      expect(d.linkSeries.edgeCount, 1);
      d.dispose();
    });

    test('authenticated config marks samples authenticated', () {
      final config = MeshtasticMeshConfig.locked(
        pskBytes: List<int>.generate(32, (i) => i + 1),
      );
      final d = MeshtasticDriver(
        host: '127.0.0.1',
        port: 4403,
        meshConfig: config,
      );
      expect(d.authenticated, isTrue);
      d.ingestBytesForTest(_meshPacketFrame(snr: 4.0, rssi: -101));
      final direct = d.buildSamplesForTest().where((s) =>
          s.fromNode == 'meshtastic:local' &&
          s.toNode == 'meshtastic:!11111111');
      expect(direct.length, 1);
      expect(direct.first.authenticated, isTrue);
      expect(direct.first.rssi, -101.0);
      d.dispose();
    });

    test('a stale field is never presented as current (re-review item 12)',
        () {
      // The direct sample used lastHeardAt = max(snrAt, rssiAt),
      // so a fresh RSSI carried a >15-min-old SNR presented as
      // current. Each field is now checked on its own timestamp:
      // the stale field reads null, and the sample is dropped
      // only when nothing is fresh.
      final d = MeshtasticDriver(host: '127.0.0.1', port: 4403);
      d.ingestBytesForTest(_meshPacketFrame(snr: 7.5, rssi: -108));
      final now = DateTime.now();
      const stale = Duration(minutes: 16); // past the 15-min maxAge
      // Fresh RSSI + stale SNR: sample carries RSSI only.
      d.setNodeMeasurementTimesForTest(0x11111111,
          snrAt: now.subtract(stale));
      var direct = d.buildSamplesForTest().where((s) =>
          s.fromNode == 'meshtastic:local' &&
          s.toNode == 'meshtastic:!11111111');
      expect(direct.length, 1);
      expect(direct.first.snr, isNull);
      expect(direct.first.rssi, -108.0);
      // Fresh SNR + stale RSSI: sample carries SNR only.
      d.setNodeMeasurementTimesForTest(0x11111111,
          snrAt: now, rssiAt: now.subtract(stale));
      direct = d.buildSamplesForTest().where((s) =>
          s.fromNode == 'meshtastic:local' &&
          s.toNode == 'meshtastic:!11111111');
      expect(direct.length, 1);
      expect(direct.first.snr, closeTo(7.5, 1e-6));
      expect(direct.first.rssi, isNull);
      // Both stale: no direct sample at all.
      d.setNodeMeasurementTimesForTest(0x11111111,
          snrAt: now.subtract(stale),
          rssiAt: now.subtract(stale));
      direct = d.buildSamplesForTest().where((s) =>
          s.fromNode == 'meshtastic:local' &&
          s.toNode == 'meshtastic:!11111111');
      expect(direct, isEmpty);
      d.dispose();
    });
  });
}
