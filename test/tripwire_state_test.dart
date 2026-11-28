import 'package:flutter_test/flutter_test.dart';
import 'package:outride/models/link_sample.dart';
import 'package:outride/services/tripwire.dart';

final _t0 = DateTime(2026, 1, 1, 12);

LinkSample _s(double snr, int i, {String from = 'a', String to = 'b'}) =>
    LinkSample(
      timestamp: _t0.add(Duration(milliseconds: 250 * i)),
      fromNode: from,
      toNode: to,
      snr: snr,
    );

/// Feed [n] quiet polls (tiny deterministic wiggle) starting at index 0.
int _warm(Tripwire tw, int n) {
  for (var i = 0; i < n; i++) {
    tw.process(_s(i.isEven ? 90.0 : 90.2, i));
  }
  return n;
}

void main() {
  group('Tripwire TripState', () {
    test('unknown link starts armed; warmup stays armed', () {
      final tw = Tripwire(config: const TripwireConfig(confirmPolls: 2));
      expect(tw.stateFor('a → b'), TripState.armed);
      _warm(tw, 20);
      expect(tw.stateFor('a → b'), TripState.armed);
    });

    test('armed → tripped → confirmed → cleared → armed', () {
      final tw = Tripwire(config: const TripwireConfig(confirmPolls: 2));
      var i = _warm(tw, 20);

      // First disturbed poll: tripped, no event yet.
      tw.process(_s(78.0, i++));
      expect(tw.stateFor('a → b'), TripState.tripped);
      expect(tw.drainEvents(), isEmpty);

      // Second disturbed poll: confirmation streak reached.
      tw.process(_s(78.0, i++));
      expect(tw.stateFor('a → b'), TripState.confirmed);
      expect(tw.drainEvents(), hasLength(1));

      // Still disturbed: stays confirmed while the episode is open.
      tw.process(_s(78.0, i++));
      expect(tw.stateFor('a → b'), TripState.confirmed);

      // Calm poll: episode ends → cleared, summary recorded.
      tw.process(_s(90.0, i++));
      expect(tw.stateFor('a → b'), TripState.cleared);
      expect(tw.drainClosedEpisodes(), hasLength(1));

      // Next calm poll: transient cleared resolves back to armed.
      tw.process(_s(90.0, i++));
      expect(tw.stateFor('a → b'), TripState.armed);
    });

    test('an unconfirmed dip ends back at armed, never cleared', () {
      final tw = Tripwire(config: const TripwireConfig(confirmPolls: 2));
      var i = _warm(tw, 20);
      tw.process(_s(78.0, i++));
      expect(tw.stateFor('a → b'), TripState.tripped);
      tw.process(_s(90.0, i++));
      expect(tw.stateFor('a → b'), TripState.armed);
      expect(tw.drainEvents(), isEmpty);
      expect(tw.drainClosedEpisodes(), isEmpty);
    });

    test('a new disturbance after a clear goes to tripped, not cleared', () {
      final tw = Tripwire(config: const TripwireConfig(confirmPolls: 2));
      var i = _warm(tw, 20);
      tw.process(_s(78.0, i++));
      tw.process(_s(78.0, i++));
      expect(tw.stateFor('a → b'), TripState.confirmed);
      tw.process(_s(90.0, i++));
      expect(tw.stateFor('a → b'), TripState.cleared);
      tw.process(_s(78.0, i++));
      expect(tw.stateFor('a → b'), TripState.tripped);
    });

    test(
        're-baseline after a lasting level change goes to armed, '
        'never cleared', () {
      final tw = Tripwire(config: const TripwireConfig(maxHoldPolls: 20));
      var i = _warm(tw, 20);
      for (var k = 0; k < 30; k++) {
        tw.process(_s(78.0, i++));
      }
      expect(tw.rebaselineCount, 1);
      // The episode was closed by the re-baseline, but there is
      // nothing to show as cleared — the old level is gone.
      expect(tw.stateFor('a → b'), TripState.armed);
    });

    test('links are independent', () {
      final tw = Tripwire(config: const TripwireConfig(confirmPolls: 2));
      var i = 0;
      for (; i < 20; i++) {
        tw.process(_s(90.0, i));
        tw.process(_s(70.0, i, from: 'b', to: 'a'));
      }
      for (var k = 0; k < 4; k++, i++) {
        tw.process(_s(78.0, i)); // only a→b dips
        tw.process(_s(70.0, i, from: 'b', to: 'a'));
      }
      expect(tw.drainEvents(), hasLength(1));
      expect(tw.stateFor('a → b'), TripState.confirmed);
      expect(tw.stateFor('b → a'), TripState.armed);
      // Calm a→b: only a→b clears.
      tw.process(_s(90.0, i++));
      expect(tw.stateFor('a → b'), TripState.cleared);
      expect(tw.stateFor('b → a'), TripState.armed);
    });
  });
}
