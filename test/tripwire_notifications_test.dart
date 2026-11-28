/// Tests for background tripwire alerts (local notifications,
/// v0.30.0): the notification fires on the SAME trigger as the
/// voice alert — a fresh, deduped Fetch trip producing a phrase —
/// beside it, never suppressing or replacing it.
///
/// The notifier is a fake injected through
/// [AppState.tripwireNotifierForTest], so no test touches
/// flutter_local_notifications or the permission channel. The
/// production notifier's Android-only scope is modelled by the
/// fake's [supported] flag: when false, [ensurePermission] reports
/// denied, exactly like [LocalTripwireNotifier] off-Android.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:outride/models/fetch_event.dart';
import 'package:outride/services/fetch_driver.dart';
import 'package:outride/services/operator_pose.dart';
import 'package:outride/services/tripwire_notifications.dart';
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

class _FakeNotifier implements TripwireNotifier {
  /// Models the platform: false stands in for non-Android, where
  /// the production notifier is an explicit no-op.
  bool supportedValue = true;

  /// Outcome of the in-app permission request.
  bool permissionGranted = true;

  int permissionRequests = 0;
  final List<({String title, String body})> posted = [];

  @override
  bool get supported => supportedValue;

  @override
  Future<bool> ensurePermission() async {
    permissionRequests++;
    if (!supported) return false;
    return permissionGranted;
  }

  @override
  Future<void> postTripAlert({
    required String title,
    required String body,
  }) async {
    posted.add((title: title, body: body));
  }
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

Future<({AppState state, _FakeSynth synth, _FakeNotifier notifier})>
    _setUp({
  bool enableVoice = true,
  bool enableNotifications = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  final state = AppState();
  final synth = _FakeSynth();
  state.voiceAlertServiceForTest = VoiceAlertService(synthesizer: synth);
  final notifier = _FakeNotifier();
  state.tripwireNotifierForTest = notifier;
  // Seed a fresh operator fix so the announce path has a position.
  final pose = OperatorPoseProvider(
      fetchFix: () async =>
          (lat: 35.0, lon: -79.0, accuracyM: 5.0, altitudeM: 0.0));
  await pose.refresh();
  state.operatorPoseForTest = pose;
  if (enableVoice) await state.setFetchVoiceEnabled(true);
  if (enableNotifications) {
    await state.setFetchNotificationsEnabled(true);
  }
  return (state: state, synth: synth, notifier: notifier);
}

Future<void> _settle() async {
  await Future<void>.delayed(const Duration(milliseconds: 50));
}

void main() {
  group('trip notification trigger (same trigger as voice)', () {
    test('fresh trip posts beside the voice alert', () async {
      final (:state, :synth, :notifier) = await _setUp();
      addTearDown(state.dispose);
      final driver = FetchDriver();
      addTearDown(driver.dispose);
      driver.ingestForTest(_event(mmwave: true));
      state.announceFetchTripsForTest(driver);
      await _settle();
      expect(synth.spoken, ['Possible person, north, twelve meters']);
      expect(notifier.posted, hasLength(1));
      expect(notifier.posted.single.title, 'Outride — Fetch trip');
      expect(notifier.posted.single.body,
          'Possible person, north, twelve meters');
    });

    test('notification fires when voice is off', () async {
      final (:state, :synth, :notifier) =
          await _setUp(enableVoice: false);
      addTearDown(state.dispose);
      final driver = FetchDriver();
      addTearDown(driver.dispose);
      driver.ingestForTest(_event(accel: true));
      state.announceFetchTripsForTest(driver);
      await _settle();
      expect(synth.spoken, isEmpty);
      expect(notifier.posted, hasLength(1));
      expect(notifier.posted.single.body, 'Movement, north, twelve meters');
    });

    test('notification fires when voice is muted', () async {
      final (:state, :synth, :notifier) = await _setUp();
      addTearDown(state.dispose);
      final driver = FetchDriver();
      addTearDown(driver.dispose);
      driver.ingestForTest(_event(accel: true));
      await state.setFetchVoiceMuted(true);
      state.announceFetchTripsForTest(driver);
      await _settle();
      expect(synth.spoken, isEmpty);
      expect(notifier.posted, hasLength(1));
    });

    test('no notification when notifications are off (voice still speaks)',
        () async {
      final (:state, :synth, :notifier) =
          await _setUp(enableNotifications: false);
      addTearDown(state.dispose);
      final driver = FetchDriver();
      addTearDown(driver.dispose);
      driver.ingestForTest(_event(accel: true));
      state.announceFetchTripsForTest(driver);
      await _settle();
      expect(synth.spoken, ['Movement, north, twelve meters']);
      expect(notifier.posted, isEmpty);
    });

    test('stale event posts nothing; a fresh one posts', () async {
      final (:state, :synth, :notifier) = await _setUp();
      addTearDown(state.dispose);
      final driver = FetchDriver();
      addTearDown(driver.dispose);
      driver.ingestForTest(_event(
          mic: true,
          at: DateTime.now().subtract(const Duration(seconds: 31))));
      state.announceFetchTripsForTest(driver);
      await _settle();
      expect(synth.spoken, isEmpty);
      expect(notifier.posted, isEmpty);
      driver.ingestForTest(_event(accel: true));
      state.announceFetchTripsForTest(driver);
      await _settle();
      expect(notifier.posted, hasLength(1));
    });

    test('same event re-reported does not double-post', () async {
      final (:state, :synth, :notifier) = await _setUp();
      addTearDown(state.dispose);
      final driver = FetchDriver();
      addTearDown(driver.dispose);
      driver.ingestForTest(_event(mmwave: true, accel: true));
      state.announceFetchTripsForTest(driver);
      await _settle();
      expect(notifier.posted, hasLength(1));
      state.announceFetchTripsForTest(driver);
      await _settle();
      expect(notifier.posted, hasLength(1));
      expect(synth.spoken,
          ['Possible person, north, twelve meters']);
    });
  });

  group('enabling notifications', () {
    test('enabling requests the permission once', () async {
      final setup = await _setUp(enableNotifications: false);
      final state = setup.state;
      final notifier = setup.notifier;
      addTearDown(state.dispose);
      expect(state.fetchNotificationsEnabled, isFalse);
      final ok = await state.setFetchNotificationsEnabled(true);
      expect(ok, isTrue);
      expect(state.fetchNotificationsEnabled, isTrue);
      expect(notifier.permissionRequests, 1);
    });

    test('denied permission keeps notifications off', () async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      addTearDown(state.dispose);
      final notifier = _FakeNotifier()..permissionGranted = false;
      state.tripwireNotifierForTest = notifier;
      final ok = await state.setFetchNotificationsEnabled(true);
      expect(ok, isFalse);
      expect(state.fetchNotificationsEnabled, isFalse);
      expect(notifier.permissionRequests, 1);
    });

    test('unsupported platform keeps notifications off', () async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      addTearDown(state.dispose);
      final notifier = _FakeNotifier()..supportedValue = false;
      state.tripwireNotifierForTest = notifier;
      final ok = await state.setFetchNotificationsEnabled(true);
      expect(ok, isFalse);
      expect(state.fetchNotificationsEnabled, isFalse);
    });

    test('disabling never asks for permission', () async {
      final setup = await _setUp();
      final state = setup.state;
      final notifier = setup.notifier;
      addTearDown(state.dispose);
      final before = notifier.permissionRequests;
      final ok = await state.setFetchNotificationsEnabled(false);
      expect(ok, isTrue);
      expect(state.fetchNotificationsEnabled, isFalse);
      expect(notifier.permissionRequests, before);
    });
  });
}
