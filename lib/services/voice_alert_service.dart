/// Voice alert service: thin flutter_tts wrapper behind an abstract
/// interface, so tests never touch the platform TTS channel.
///
/// Serialization: utterances speak one at a time. A phrase that
/// arrives while one is speaking queues behind it; the queue holds
/// at most 3 and drops the OLDEST when full (a stale alert is worse
/// than a dropped one — the operator needs the newest trip, not a
/// backlog). The current utterance is stopped before a new one
/// starts only via [stop]; queued phrases never interrupt the one
/// in flight.
///
/// A failed speak must never crash the app or the poll loop: every
/// platform error is caught and logged via debugPrint only.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// TTS backend. Production = [FlutterTtsVoiceSynthesizer]; tests
/// use a fake that completes on demand.
abstract class VoiceSynthesizer {
  /// Speak [text]. Completes when the utterance finishes (when the
  /// backend supports completion); may throw on platform failure.
  Future<void> speak(String text);

  /// Stop any utterance in progress.
  Future<void> stop();

  /// Speech rate, 0.1 (slowest) to 1.0 (normal platform rate).
  Future<void> setSpeechRate(double rate);
}

/// flutter_tts implementation of [VoiceSynthesizer].
class FlutterTtsVoiceSynthesizer implements VoiceSynthesizer {
  FlutterTtsVoiceSynthesizer({FlutterTts? tts}) : _tts = tts ?? FlutterTts();

  final FlutterTts _tts;
  bool _configured = false;

  Future<void> _ensureConfigured() async {
    if (_configured) return;
    try {
      await _tts.setLanguage('en-US');
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
      // Speak futures complete when the utterance finishes, so the
      // service can serialize without guessing at durations.
      await _tts.awaitSpeakCompletion(true);
      _configured = true;
    } catch (e) {
      debugPrint('Fetch voice: TTS configure failed: $e');
    }
  }

  @override
  Future<void> speak(String text) async {
    await _ensureConfigured();
    await _tts.speak(text);
  }

  @override
  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (e) {
      debugPrint('Fetch voice: TTS stop failed: $e');
    }
  }

  @override
  Future<void> setSpeechRate(double rate) async {
    await _ensureConfigured();
    try {
      await _tts.setSpeechRate(rate.clamp(0.1, 1.0));
    } catch (e) {
      debugPrint('Fetch voice: TTS setSpeechRate failed: $e');
    }
  }
}

/// Serialized spoken-alert service. Owns the queue; the phrase logic
/// lives in [FetchVoiceAlerts] (see fetch_voice_alerts.dart).
class VoiceAlertService {
  VoiceAlertService({
    required VoiceSynthesizer synthesizer,
    double speechRate = 0.5,
  })  : _synthesizer = synthesizer,
        _speechRate = speechRate.clamp(0.1, 1.0);

  final VoiceSynthesizer _synthesizer;

  /// Fixed sample alert for the Settings "Test voice" button.
  /// Cardinal only: heading is always null in v1, so only cardinal
  /// directions are ever produced — a relative term here would
  /// demonstrate a phrase v1 can never speak.
  static const String sampleAlert = 'Movement, north, ten meters';

  /// Max queued (not yet speaking) utterances; oldest dropped first.
  static const int maxQueue = 3;

  /// Max time one utterance may hold the speaker. A speak future
  /// that never completes (hung platform TTS) used to leave
  /// [_speaking] true forever, silently killing every later alert
  /// as the bounded queue filled. On timeout the speaker resets
  /// and the queue drains normally; the orphaned speak future is
  /// simply abandoned.
  static const Duration speakTimeout = Duration(seconds: 20);

  double _speechRate;
  final List<String> _queue = [];
  bool _speaking = false;
  bool _disposed = false;

  /// Speech rate, 0.1–1.0. Applied to the synthesizer on next speak.
  double get speechRate => _speechRate;

  Future<void> setSpeechRate(double rate) async {
    _speechRate = rate.clamp(0.1, 1.0);
    try {
      await _synthesizer.setSpeechRate(_speechRate);
    } catch (e) {
      debugPrint('Fetch voice: setSpeechRate failed: $e');
    }
  }

  /// Phrases waiting to speak (not counting the one in flight).
  int get queuedCount => _queue.length;

  /// True while an utterance is in flight.
  bool get isSpeaking => _speaking;

  /// Queue [phrase] to speak. Never throws; never interrupts the
  /// utterance in flight. When the queue is full the oldest queued
  /// phrase is dropped to make room.
  void enqueue(String phrase) {
    if (_disposed) return;
    final text = phrase.trim();
    if (text.isEmpty) return;
    if (_queue.length >= maxQueue) _queue.removeAt(0);
    _queue.add(text);
    unawaited(_pump());
  }

  /// Speak the fixed sample alert (Settings "Test voice").
  void speakTest() => enqueue(sampleAlert);

  /// Stop the current utterance and drop the queue.
  Future<void> stop() async {
    _queue.clear();
    try {
      await _synthesizer.stop();
    } catch (e) {
      debugPrint('Fetch voice: stop failed: $e');
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _queue.clear();
    try {
      await _synthesizer.stop();
    } catch (_) {}
  }

  Future<void> _pump() async {
    if (_speaking || _queue.isEmpty || _disposed) return;
    _speaking = true;
    final text = _queue.removeAt(0);
    try {
      await _synthesizer.setSpeechRate(_speechRate);
      await _synthesizer.speak(text).timeout(
        speakTimeout,
        onTimeout: () {
          debugPrint(
              'Fetch voice: speak timed out after ${speakTimeout.inSeconds} s; recovering');
        },
      );
    } catch (e) {
      // A failed speak must never crash the app or the poll loop.
      debugPrint('Fetch voice: speak failed: $e');
    } finally {
      _speaking = false;
      if (_queue.isNotEmpty && !_disposed) unawaited(_pump());
    }
  }
}
