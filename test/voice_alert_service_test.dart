/// Tests for the voice alert service: serialization (one utterance
/// at a time, never speaking over itself), the bounded queue (max 3,
/// oldest dropped), the fixed test phrase, and failure containment
/// (a failed speak never throws out of the service).
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:outride/services/voice_alert_service.dart';

/// Fake synthesizer: speak blocks on a gate the test completes, so
/// "currently speaking" is under test control.
class FakeSynthesizer implements VoiceSynthesizer {
  final List<String> spoken = [];
  final List<double> rates = [];
  Completer<void>? gate;
  bool throwOnSpeak = false;
  int stopCalls = 0;

  /// Hold the next speak call until [completeCurrent] is called.
  void holdNext() {
    gate = Completer<void>();
  }

  void completeCurrent() {
    gate?.complete();
    gate = null;
  }

  @override
  Future<void> speak(String text) async {
    spoken.add(text);
    if (throwOnSpeak) throw StateError('TTS platform failure');
    final g = gate;
    if (g != null) await g.future;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> setSpeechRate(double rate) async {
    rates.add(rate);
  }
}

/// Fake synthesizer whose speak never completes (hung platform TTS).
class _NeverCompletingSynthesizer implements VoiceSynthesizer {
  final List<String> spoken = [];

  @override
  Future<void> speak(String text) {
    spoken.add(text);
    return Completer<void>().future;
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> setSpeechRate(double rate) async {}
}

void main() {
  group('VoiceAlertService queue', () {
    test('first phrase speaks immediately when idle', () async {
      final synth = FakeSynthesizer();
      final svc = VoiceAlertService(synthesizer: synth);
      svc.enqueue('Movement');
      await Future<void>.delayed(Duration.zero);
      expect(synth.spoken, ['Movement']);
      expect(svc.queuedCount, 0);
      await svc.dispose();
    });

    test('no overlap: a second phrase queues while one is speaking',
        () async {
      final synth = FakeSynthesizer()..holdNext();
      final svc = VoiceAlertService(synthesizer: synth);
      svc.enqueue('Movement');
      await Future<void>.delayed(Duration.zero);
      expect(synth.spoken, ['Movement']);
      svc.enqueue('Sound');
      await Future<void>.delayed(Duration.zero);
      // Still only the first utterance spoken; the second waits.
      expect(synth.spoken, ['Movement']);
      expect(svc.queuedCount, 1);
      expect(svc.isSpeaking, isTrue);
      synth.completeCurrent();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(synth.spoken, ['Movement', 'Sound']);
      await svc.dispose();
    });

    test('bounded queue of 3 drops the oldest when full', () async {
      final synth = FakeSynthesizer()..holdNext();
      final svc = VoiceAlertService(synthesizer: synth);
      svc.enqueue('first');
      await Future<void>.delayed(Duration.zero);
      svc.enqueue('a');
      svc.enqueue('b');
      svc.enqueue('c');
      svc.enqueue('d'); // queue full: 'a' (oldest) is dropped
      await Future<void>.delayed(Duration.zero);
      expect(svc.queuedCount, 3);
      synth.completeCurrent();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(synth.spoken, ['first', 'b', 'c', 'd']);
      expect(synth.spoken, isNot(contains('a')));
      await svc.dispose();
    });

    test('speakTest speaks the fixed sample alert', () async {
      final synth = FakeSynthesizer();
      final svc = VoiceAlertService(synthesizer: synth);
      svc.speakTest();
      await Future<void>.delayed(Duration.zero);
      expect(synth.spoken, [VoiceAlertService.sampleAlert]);
      expect(VoiceAlertService.sampleAlert,
          'Movement, north, ten meters');
      await svc.dispose();
    });

    test('a failed speak never throws and the next phrase still speaks',
        () async {
      final synth = FakeSynthesizer()..throwOnSpeak = true;
      final svc = VoiceAlertService(synthesizer: synth);
      svc.enqueue('Movement');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // No throw escaped; the service recovered and is idle.
      expect(svc.isSpeaking, isFalse);
      synth.throwOnSpeak = false;
      svc.enqueue('Sound');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(synth.spoken, contains('Sound'));
      await svc.dispose();
    });

    test('a hung speak times out and later phrases still speak', () {
      fakeAsync((async) {
        final synth = _NeverCompletingSynthesizer();
        final svc = VoiceAlertService(synthesizer: synth);
        svc.enqueue('first');
        async.flushMicrotasks();
        expect(synth.spoken, ['first']);
        expect(svc.isSpeaking, isTrue);
        // The 20 s speak timeout fires; the service recovers
        // instead of staying "speaking" forever.
        async.elapse(VoiceAlertService.speakTimeout +
            const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(svc.isSpeaking, isFalse);
        svc.enqueue('second');
        async.flushMicrotasks();
        expect(synth.spoken, ['first', 'second']);
        unawaited(svc.dispose());
        async.flushMicrotasks();
      });
    });

    test('speech rate is clamped to 0.1-1.0 and forwarded', () async {
      final synth = FakeSynthesizer();
      final svc =
          VoiceAlertService(synthesizer: synth, speechRate: 5.0);
      expect(svc.speechRate, 1.0);
      await svc.setSpeechRate(0.05);
      expect(svc.speechRate, 0.1);
      expect(synth.rates.last, 0.1);
      await svc.dispose();
    });

    test('stop drops the queue', () async {
      final synth = FakeSynthesizer()..holdNext();
      final svc = VoiceAlertService(synthesizer: synth);
      svc.enqueue('Movement');
      await Future<void>.delayed(Duration.zero);
      svc.enqueue('Sound');
      expect(svc.queuedCount, 1);
      await svc.stop();
      expect(svc.queuedCount, 0);
      expect(synth.stopCalls, greaterThan(0));
      synth.completeCurrent();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(synth.spoken, ['Movement']);
      await svc.dispose();
    });
  });
}
