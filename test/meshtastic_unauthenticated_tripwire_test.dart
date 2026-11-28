/// Regression test for the review finding (v0.31.0, reviewer #1):
/// `LinkSample.authenticated` was produced by the Meshtastic driver
/// but never consumed — every driver's raw samples went straight
/// into `_tripwire.process`, so a spoofed/unsigned Meshtastic packet
/// could trip a Meshtastic link and raise a DETECTED event.
///
/// The fix gates the tripwire in `AppState._tickPoller`: unauthenticated
/// samples from a `MeshtasticDriver` are still recorded to history
/// (UNTRUSTED fusion input — corroborate/upgrade, never veto) but
/// never reach the tripwire. The same gate keeps unauthenticated
/// Meshtastic samples out of guided calibration
/// (`_accumulateCalibration`), so a spoofed dip cannot bias a link's
/// median or the path-loss fit.
///
/// Honest scope: Meshtastic tripping is fully OFF in v0.31.0. No
/// production code ever constructs a `MeshtasticMeshConfig`
/// (`MeshtasticDriver.fromAddress (via driverFor)` builds the driver with no
/// meshConfig, and nothing in `AppState` ever sets one), so
/// `authenticated` is always false in the live app and no Meshtastic
/// sample can trip today. Plumbing `MeshtasticMeshConfig` into the
/// driver factory is a follow-up, not this release. "Authenticated
/// samples still trip" is therefore true only at unit level — a
/// positive-path AppState test is impossible through the app's
/// current wiring.
///
/// This test drives the real poll path: a fake Meshtastic TCP server
/// (127.0.0.1, the same 0x94 0xC3 framing the driver speaks) feeds
/// a calm baseline and then a deep dip that would trip an ungated
/// tripwire. The control test proves the stimulus trips a bare
/// [Tripwire], so the AppState test failing means the gate is missing,
/// not that the stimulus is weak.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/models/link_sample.dart';
import 'package:outride/models/tracking.dart';
import 'package:outride/services/adaptive_baseline.dart';
import 'package:outride/services/radio_driver.dart';
import 'package:outride/services/tripwire.dart';
import 'package:outride/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

// --- Minimal protobuf encoder for synthetic MeshPacket frames ---
// (same framing as test/meshtastic_driver_series_test.dart)

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

List<int> _tag(int field, int wire) => _varint((field << 3) | wire);
List<int> _lenField(int field, List<int> bytes) => [
      ..._tag(field, 2),
      ..._varint(bytes.length),
      ...bytes,
    ];
List<int> _u32(int field, int v) => [..._tag(field, 0), ..._varint(v)];
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

/// One MeshPacket frame from node 0x11111111 with the given rx SNR.
/// No mesh config is supplied to the driver, so the emitted
/// [LinkSample]s carry `authenticated: false` (default = untrusted).
List<int> _meshPacketFrame({required double snr}) {
  final data = [
    ..._u32(1, 1), // Data.portnum = text
    ..._lenField(2, 'hi'.codeUnits),
  ];
  final packet = [
    ..._fixed32(1, 0x11111111), // from
    ..._fixed32(2, 0xFFFFFFFF), // to (broadcast)
    ..._lenField(4, data),
    ..._float32(8, snr), // rx_snr
  ];
  return _frame(_lenField(2, packet));
}

const _linkKey = 'meshtastic:local → meshtastic:!11111111';

void main() {
  group('unauthenticated Meshtastic samples never trip the tripwire', () {
    test('spoofed dip on an unauthenticated mesh link raises no event',
        timeout: const Timeout(Duration(minutes: 2)), () async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      addTearDown(state.dispose);

      // Fake Meshtastic TCP endpoint: the driver connects here and
      // reads 0x94 0xC3 frames; no handshake is required.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      Socket? client;
      final serverSub = server.listen((s) {
        client = s;
      });
      addTearDown(serverSub.cancel);

      // Current SNR the fake radio reports; the sender loop keeps
      // the node's measurement fresh so every poll sees it.
      var currentSnr = 8.0;
      final sender = Timer.periodic(const Duration(milliseconds: 80), (_) {
        client?.add(_meshPacketFrame(snr: currentSnr));
      });
      addTearDown(sender.cancel);

      state.settings.simulatedMode = false;
      state.radioConfigs.add(RadioConfig(
        driverId: 'meshtastic',
        address: '127.0.0.1:${server.port}',
        label: 'MESHTASTIC',
        pollInterval: 0.25,
      ));
      state.start();
      // start() may defer while the saved-radio load lands; wait
      // for polling to actually begin.
      for (var i = 0; i < 100 && !state.polling; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(state.polling, isTrue);

      // Calm phase: let the tripwire learn its baseline (10 polls
      // before it is trusted) from the unauthenticated link.
      final baselineDeadline = DateTime.now().add(const Duration(seconds: 30));
      while ((state.history[_linkKey]?.length ?? 0) < 12) {
        if (DateTime.now().isAfter(baselineDeadline)) {
          fail('baseline never built: '
              'history=${state.history[_linkKey]?.length}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(state.events, isEmpty);

      // Spoof phase: a deep dip (8.0 → -10.0, 18 radio units — far
      // past the ~4-unit adaptive floor) that trips an ungated
      // tripwire after 2 consecutive polls. Keep it up for 6+ polls.
      currentSnr = -10.0;
      final dipDeadline = DateTime.now().add(const Duration(seconds: 30));
      while ((state.history[_linkKey]?.length ?? 0) < 19) {
        if (DateTime.now().isAfter(dipDeadline)) {
          fail('dip polls never landed: '
              'history=${state.history[_linkKey]?.length}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }

      // The gate: no DETECTED event, even though the dip is far past
      // threshold — an unsigned packet must never trip the mesh.
      expect(state.events, isEmpty,
          reason: 'unauthenticated Meshtastic dip must not trip');
      // ...but the samples were still recorded (UNTRUSTED fusion
      // input: corroborate/upgrade, never veto).
      final hist = state.history[_linkKey]!;
      expect(hist.length, greaterThanOrEqualTo(19));
      expect(hist.any((s) => s.snr == -10.0), isTrue);
      expect(hist.every((s) => s.authenticated == false), isTrue);
      state.stop();
    });

    test('control: the same dip trips a bare Tripwire', () {
      // Proves the stimulus above is strong enough to trip — so the
      // AppState test passing means the gate works, not that the
      // dip was too weak to detect.
      final tw = Tripwire();
      final base = DateTime.now();
      LinkSample sample(double snr, int i) => LinkSample(
            timestamp: base.add(Duration(seconds: i)),
            fromNode: 'meshtastic:local',
            toNode: 'meshtastic:!11111111',
            snr: snr,
          );
      for (var i = 0; i < 12; i++) {
        tw.process(sample(8.0, i));
      }
      expect(tw.drainEvents(), isEmpty);
      tw.process(sample(-10.0, 12));
      final events = [
        ...tw.drainEvents(),
        ...(() {
          tw.process(sample(-10.0, 13));
          return tw.drainEvents();
        })(),
      ];
      expect(events, hasLength(1));
      expect(events.first.linkKey, _linkKey);
    });
  });

  group('unauthenticated Meshtastic samples never bias calibration', () {
    test('spoofed dip during guided calibration collects no samples',
        timeout: const Timeout(Duration(minutes: 2)), () async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      addTearDown(state.dispose);

      // Same fake Meshtastic TCP endpoint as the tripwire test.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      Socket? client;
      final serverSub = server.listen((s) {
        client = s;
      });
      addTearDown(serverSub.cancel);

      var currentSnr = 8.0;
      final sender = Timer.periodic(const Duration(milliseconds: 80), (_) {
        client?.add(_meshPacketFrame(snr: currentSnr));
      });
      addTearDown(sender.cancel);

      state.settings.simulatedMode = false;
      state.radioConfigs.add(RadioConfig(
        driverId: 'meshtastic',
        address: '127.0.0.1:${server.port}',
        label: 'MESHTASTIC',
        pollInterval: 0.25,
      ));
      state.start();
      for (var i = 0; i < 100 && !state.polling; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(state.polling, isTrue);

      // Calm phase: the link is live and polling.
      final calmDeadline = DateTime.now().add(const Duration(seconds: 30));
      while ((state.history[_linkKey]?.length ?? 0) < 6) {
        if (DateTime.now().isAfter(calmDeadline)) {
          fail('calm polls never landed: '
              'history=${state.history[_linkKey]?.length}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }

      // Start guided calibration, then spoof a deep dip (8.0 → -10.0)
      // for 7+ polls — the same stimulus that trips an ungated
      // tripwire, and that would drag the link's static median to
      // -10.0 if it reached the accumulator.
      state.startCalibration();
      currentSnr = -10.0;
      final dipDeadline = DateTime.now().add(const Duration(seconds: 30));
      while ((state.history[_linkKey]?.length ?? 0) < 13) {
        if (DateTime.now().isAfter(dipDeadline)) {
          fail('dip polls never landed: '
              'history=${state.history[_linkKey]?.length}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }

      await state.finishCalibration();
      // The gate: no calibration record at all — every sample during
      // the routine was unauthenticated, so none reached the
      // accumulator and the routine was discarded, not biased.
      expect(state.lastCalibration, isNull);
      expect(state.calibrationState, CalibrationState.idle);
      expect(state.calibrationNote, contains('NO SAMPLES COLLECTED'));
      state.stop();
    });

    test('control: the same dip biases an ungated accumulator', () {
      // Proves the stimulus above is strong enough to bias
      // calibration — so the AppState test passing means the gate
      // works, not that the dip was too weak to matter.
      final ab = AdaptiveBaseline();
      ab.beginGuidedCalibration();
      const link = 'meshtastic:local → meshtastic:!11111111';
      for (var i = 0; i < 6; i++) {
        ab.observeCalibration(linkKey: link, channel: 'mesh', rssi: 8.0);
      }
      for (var i = 0; i < 7; i++) {
        ab.observeCalibration(linkKey: link, channel: 'mesh', rssi: -10.0);
      }
      final rec = ab.finishGuidedCalibration(
        nodes: {
          'meshtastic:local':
              NodePosition(nodeId: 'meshtastic:local', x: 0, y: 0),
          'meshtastic:!11111111':
              NodePosition(nodeId: 'meshtastic:!11111111', x: 60, y: 0),
        },
        vacantSecs: 30,
      );
      expect(rec, isNotNull);
      final meshLink = rec!.links.firstWhere((l) => l.link == link);
      // 6 calm + 7 dipped samples: the static median is dragged from
      // 8.0 down to -10.0 — the spoofed dip biases the anchor.
      expect(meshLink.muCalibDbm, -10.0);
    });
  });
}
