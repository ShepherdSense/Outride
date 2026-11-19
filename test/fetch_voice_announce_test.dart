/// AppState-level tests for Fetch voice announcements: the dedupe
/// across polls, the 30 s freshness window, and the replay/mute/
/// off gates in [_maybeAnnounceFetchTrips] (driven through the
/// [AppState.announceFetchTripsForTest] hook — the real entry point
/// is the poll loop). Also the throw-point clearing on Fetch
/// polling stop / FETCH driver removal.
///
/// The voice service and pose provider are fakes injected through
/// the test hooks, so no test touches flutter_tts or the location
/// channel.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:outride/models/fetch_event.dart';
import 'package:outride/services/fetch_driver.dart';
import 'package:outride/services/fetch_voice_alerts.dart';
import 'package:outride/services/operator_pose.dart';
import 'package:outride/services/radio_driver.dart';
import 'package:outride/services/voice_alert_service.dart';
import 'package:outride/state/app_state.dart';

class _FakeSynth implements VoiceSynthesizer {
  final List<String> spoken = [];

  @override
  Future<void> speak(String text) async {
    spoken.add(text);
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> setSpeechRate(double rate) async {}
}

/// Operator stands at 35.0, -79.0; the ball sits ~12 m north, just
/// outside the ~10 m bare-phrase cutoff.
FetchEvent _event({
  bool accel = false,
  bool mic = false,
  bool mmwave = false,
  DateTime? at,
}) =>
    FetchEvent(
      receivedAt: at ?? DateTime.now(),
      accelTrip: accel,
      micTrip: mic,
      mmwaveTrip: mmwave,
      gpsFix: true,
      lat: 35.0 + 0.00011,
      lon: -79.0,
    );

Future<({AppState state, _FakeSynth synth})> _setUp({
  bool enableVoice = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  final state = AppState();
  final synth = _FakeSynth();
  state.voiceAlertServiceForTest = VoiceAlertService(synthesizer: synth);
  // Seed a fresh operator fix so the announce path has a position.
  final pose = OperatorPoseProvider(
      fetchFix: () async =>
          (lat: 35.0, lon: -79.0, accuracyM: 5.0, altitudeM: 0.0));
  await pose.refresh();
  state.operatorPoseForTest = pose;
  if (enableVoice) await state.setFetchVoiceEnabled(true);
  return (state: state, synth: synth);
}

Future<void> _settle() async {
  await Future<void>.delayed(const Duration(milliseconds: 50));
}

void main() {
  group('AppState announce gates', () {
    test('fresh trip speaks with direction and distance', () async {
      final (:state, :synth) = await _setUp();
      addTearDown(state.dispose);
      final driver = FetchDriver();
      addTearDown(driver.dispose);
      driver.ingestForTest(_event(mmwave: true));
      state.announceFetchTripsForTest(driver);
      await _settle();
      expect(synth.spoken, ['Possible person, north, twelve meters']);
    });

    test('same event re-reported does not double-announce', () async {
      final (:state, :synth) = await _setUp();
      addTearDown(state.dispose);
      final driver = FetchDriver();
      addTearDown(driver.dispose);
      // Multi-sensor event: the first announce speaks the
      // person-class channel. Without the dedupe list, the second
      // announce would speak the next unsuppressed sensor
      // ("Movement") — the throttle alone would not stop it.
      driver.ingestForTest(_event(mmwave: true, accel: true));
      state.announceFetchTripsForTest(driver);
      await _settle();
      expect(synth.spoken, ['Possible person, north, twelve meters']);
      state.announceFetchTripsForTest(driver);
      await _settle();
      expect(synth.spoken,
          ['Possible person, north, twelve meters']);
    });

    test('event older than 30 s stays silent; a fresh one speaks',
        () async {
      final (:state, :synth) = await _setUp();
      addTearDown(state.dispose);
      final driver = FetchDriver();
      addTearDown(driver.dispose);
      driver.ingestForTest(_event(
          mic: true,
          at: DateTime.now().subtract(const Duration(seconds: 31))));
      state.announceFetchTripsForTest(driver);
      await _settle();
      expect(synth.spoken, isEmpty);
      driver.ingestForTest(_event(accel: true));
      state.announceFetchTripsForTest(driver);
      await _settle();
      expect(synth.spoken, ['Movement, north, twelve meters']);
    });

    test('replayed trips stay silent, then speak once replay ends',
        () async {
      final (:state, :synth) = await _setUp();
      addTearDown(state.dispose);
      final driver = FetchDriver();
      addTearDown(driver.dispose);
      driver.ingestForTest(_event(accel: true));
      state.replaying = true;
      state.announceFetchTripsForTest(driver);
      await _settle();
      expect(synth.spoken, isEmpty);
      state.replaying = false;
      state.announceFetchTripsForTest(driver);
      await _settle();
      expect(synth.spoken, ['Movement, north, twelve meters']);
    });

    test('muted trips stay silent, then speak once unmuted', () async {
      final (:state, :synth) = await _setUp();
      addTearDown(state.dispose);
      final driver = FetchDriver();
      addTearDown(driver.dispose);
      driver.ingestForTest(_event(accel: true));
      await state.setFetchVoiceMuted(true);
      state.announceFetchTripsForTest(driver);
      await _settle();
      expect(synth.spoken, isEmpty);
      await state.setFetchVoiceMuted(false);
      state.announceFetchTripsForTest(driver);
      await _settle();
      expect(synth.spoken, ['Movement, north, twelve meters']);
    });

    test('voice off stays silent', () async {
      final (:state, :synth) = await _setUp(enableVoice: false);
      addTearDown(state.dispose);
      final driver = FetchDriver();
      addTearDown(driver.dispose);
      driver.ingestForTest(_event(accel: true));
      state.announceFetchTripsForTest(driver);
      await _settle();
      expect(synth.spoken, isEmpty);
    });
  });

  group('throw point clearing', () {
    test('removing the FETCH radio clears the throw point', () async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      addTearDown(state.dispose);
      state.throwPoint = ThrowPoint(
          lat: 35.0, lon: -79.0, at: DateTime.now());
      state.radioConfigs.add(RadioConfig(
          driverId: 'fetch', address: '', label: 'FETCH'));
      await state.removeRadioAt(0);
      expect(state.throwPoint, isNull);
    });

    test('removing another radio keeps the throw point', () async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      addTearDown(state.dispose);
      state.throwPoint = ThrowPoint(
          lat: 35.0, lon: -79.0, at: DateTime.now());
      state.radioConfigs.add(RadioConfig(
          driverId: 'silvus',
          address: '172.17.97.182',
          label: 'SILVUS'));
      await state.removeRadioAt(0);
      expect(state.throwPoint, isNotNull);
    });

    test('stopping Fetch polling clears the throw point', () async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      addTearDown(state.dispose);
      state.settings.simulatedMode = false;
      state.radioConfigs.add(RadioConfig(
          driverId: 'fetch', address: '', label: 'FETCH'));
      state.start();
      // The saved-radio load may still be in flight; start() re-runs
      // when it lands, so wait for the Fetch poller to appear.
      for (var i = 0; i < 20 && !state.hasFetchDriver; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(state.hasFetchDriver, isTrue);
      state.throwPoint = ThrowPoint(
          lat: 35.0, lon: -79.0, at: DateTime.now());
      state.stop();
      expect(state.throwPoint, isNull);
    });
  });
}
