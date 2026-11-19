/// "The Fetch" view — live fused data from the throwable sensor ball.
///
/// EXPERIMENTAL. Shows, all live from the ball's fused events over
/// UDP 49160 (via the Fetch driver):
///   - per-sensor trip indicators: accel / mic / mmWave / BLE / Wi-Fi
///   - live gauges: mag_g (1.0 g rest baseline) and mic_rms (150000
///     trip line)
///   - GPS: fix status, sats, lat/lon when fixed
///   - event feed, newest first (last ~100), with BLE/Wi-Fi
///     corroboration context per event
///
/// HONEST SCOPE (shown on the view itself): presence/movement data
/// from a ball that hears, feels, and sees motion and reports its own
/// position. Never identity, never a camera feed, never fire-control.
/// BLE/Wi-Fi tripwires watch device addresses, never who owns them;
/// the ball is listen-only. The ball's position is plotted as
/// coordinates only — there is no map marker in v1 (the Tracking map
/// is a field-local projection, not a geo map; plotting the ball on it
/// is follow-up work).
///
/// When no FETCH driver is added the view degrades to a setup hint —
/// absence of a driver is never presented as "nothing is happening".
library;

import 'package:flutter/material.dart';

import '../models/fetch_event.dart';
import '../services/fetch_driver.dart';
import '../services/node_udp_hub.dart';
import '../state/app_state.dart';
import '../theme.dart';

/// Display metadata per tripwire channel.
const Map<FetchTripSensor, ({String label, String hint})> _sensorMeta = {
  FetchTripSensor.accel: (
    label: 'ACCEL',
    hint: 'BMI160 |mag−1g| > 0.35 g',
  ),
  FetchTripSensor.mic: (
    label: 'MIC',
    hint: 'INMP441 RMS > 150k',
  ),
  FetchTripSensor.mmwave: (
    label: 'MMWAVE',
    hint: 'LD2420 OT1 presence',
  ),
  FetchTripSensor.ble: (
    label: 'BLE',
    hint: 'New advertiser / RSSI jump > 15 dB',
  ),
  FetchTripSensor.wifi: (
    label: 'WI-FI',
    hint: 'New BSSID / RSSI jump > 15 dB',
  ),
};

String _clock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:'
    '${t.minute.toString().padLeft(2, '0')}:'
    '${t.second.toString().padLeft(2, '0')}';

String _age(DateTime t, DateTime now) {
  final s = now.difference(t).inSeconds;
  if (s < 5) return 'just now';
  if (s < 60) return '${s}s ago';
  final m = s ~/ 60;
  if (m < 60) return '${m}m ago';
  return '${m ~/ 60}h ${m % 60}m ago';
}

/// Fraction of a gauge bar a value fills (0..1), clamped. Testable
/// in isolation: the mag_g rest marker (1.0 g / 2.0 max) and the mic
/// trip line (150k / 300k max) must both sit at exactly 0.5.
@visibleForTesting
double fetchGaugeFraction(double? value, double max) =>
    value == null ? 0.0 : (value / max).clamp(0.0, 1.0);

class FetchScreen extends StatelessWidget {
  const FetchScreen({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final driver =
            state.hasFetchDriver ? state.fetchDriver : null;
        final now = DateTime.now();
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _header(),
            const SizedBox(height: 12),
            if (driver == null) ...[
              _setupHint(),
            ] else ...[
              _statusCard(driver, now),
              const SizedBox(height: 12),
              _voiceCard(state, now),
              const SizedBox(height: 12),
              _tripGrid(driver, now),
              const SizedBox(height: 12),
              _gaugesCard(driver),
              const SizedBox(height: 12),
              _gpsCard(driver, now),
              const SizedBox(height: 12),
              _feedCard(driver, now),
            ],
            const SizedBox(height: 12),
            const _ScopeNote(),
          ],
        );
      },
    );
  }

  Widget _header() {
    return const OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Wrap, not Row: title + chip must flow onto two lines on
          // a narrow phone instead of overflowing (same lesson as
          // the 2026-10-20 field-map header overflow).
          Wrap(
            spacing: 10,
            runSpacing: 6,
            children: [
              Text('THE FETCH', style: TextStyle(
                fontFamily: OutrideType.mono,
                fontSize: 16,
                fontWeight: FontWeight.w700,
                letterSpacing: 3,
                color: OutrideColors.onDark,
              )),
              OutrideChip(
                  label: 'EXPERIMENTAL', color: OutrideColors.purple),
            ],
          ),
          SizedBox(height: 6),
          Text(
            'Throwable sensor ball — fused presence/movement events. '
            'One ball, five tripwires: accel, mic, mmWave, BLE, Wi-Fi.',
            style: TextStyle(
              fontFamily: OutrideType.mono,
              fontSize: 12,
              color: OutrideColors.muted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _setupHint() {
    return const OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('NO FETCH DRIVER', style: TextStyle(
            fontFamily: OutrideType.mono,
            fontSize: 13,
            fontWeight: FontWeight.w700,
            letterSpacing: 2,
            color: OutrideColors.amber,
          )),
          SizedBox(height: 8),
          Text(
            'The ball is not connected. Add the driver, then feed it:\n\n'
            '1. Settings → Radios → add FETCH (throwable sensor ball), '
            'then press Start — the driver only listens while polling '
            'is running.\n'
            '2. Bench (no LoRa yet): run tools/fetch_serial_bridge '
            'to forward the ball\'s serial JSON to UDP 49160.\n'
            '3. Later: the LoRa link carries the same JSON — no app '
            'change needed.',
            style: TextStyle(
              fontFamily: OutrideType.mono,
              fontSize: 12,
              color: OutrideColors.onDark,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusCard(FetchDriver driver, DateTime now) {
    final latest = driver.latest;
    final bound = NodeUdpHub.isBound;
    final err = NodeUdpHub.lastError;
    return OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('INGEST — UDP 49160', style: OutrideType.section(11)),
          const SizedBox(height: 8),
          Row(
            children: [
              OutrideChip(
                label: bound ? 'LISTENING' : 'NOT LISTENING',
                color: bound ? OutrideColors.green : OutrideColors.red,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  bound
                      ? 'Shared node socket — the ball talks, Outride listens.'
                      : (err ?? 'Socket not bound — check the driver is polling.'),
                  style: const TextStyle(
                    fontFamily: OutrideType.mono,
                    fontSize: 12,
                    color: OutrideColors.muted,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _kv('Events ingested', '${driver.ingestedCount}'),
          _kv('Malformed skipped', '${driver.malformedCount}'),
          _kv('Last event',
              latest == null ? '— none yet' : '${_clock(latest.receivedAt)} (${_age(latest.receivedAt, now)})'),
        ],
      ),
    );
  }

  /// Voice alerts + throw point (EXPERIMENTAL). "Mark throw"
  /// records where the ball was thrown from, so trips can be spoken
  /// relative to the throw point when the ball has no GPS fix
  /// (indoors, GPS usually dies). The mute toggle is fast silence
  /// without turning the feature off in Settings.
  Widget _voiceCard(AppState state, DateTime now) {
    final tp = state.throwPoint;
    final tpLabel = tp == null
        ? 'No throw point'
        : 'Throw point set ${_age(tp.at, now)}';
    return OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('VOICE ALERTS — EXPERIMENTAL',
              style: OutrideType.section(11)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutrideChip(
                label: state.fetchVoiceEnabled
                    ? (state.fetchVoiceMuted ? 'ON — MUTED' : 'ON')
                    : 'OFF',
                color: state.fetchVoiceEnabled && !state.fetchVoiceMuted
                    ? OutrideColors.green
                    : OutrideColors.muted,
              ),
              ElevatedButton(
                onPressed: () => state.markThrowPoint(),
                child: const Text('Mark throw'),
              ),
              OutlinedButton(
                onPressed: tp == null
                    ? null
                    : () => state.clearThrowPoint(),
                child: const Text('Clear throw point'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  tpLabel,
                  style: const TextStyle(
                    fontFamily: OutrideType.mono,
                    fontSize: 12,
                    color: OutrideColors.onDark,
                  ),
                ),
              ),
              const Text('MUTE',
                  style: TextStyle(
                    fontFamily: OutrideType.mono,
                    fontSize: 12,
                    color: OutrideColors.muted,
                  )),
              const SizedBox(width: 6),
              Switch(
                value: state.fetchVoiceMuted,
                onChanged: (v) => state.setFetchVoiceMuted(v),
              ),
            ],
          ),
          if (state.throwPointError != null) ...[
            const SizedBox(height: 6),
            Text(
              state.throwPointError!,
              style: const TextStyle(
                fontFamily: OutrideType.mono,
                fontSize: 12,
                color: OutrideColors.amber,
              ),
            ),
          ],
          const SizedBox(height: 6),
          const Text(
            'Spoken trips go to this EUD only. With a throw point, '
            'trips speak as "from throw point" + direction + distance; '
            'without one and without a ball GPS fix, they speak the '
            'trip alone — never a guessed direction.',
            style: TextStyle(
              fontFamily: OutrideType.mono,
              fontSize: 11,
              color: OutrideColors.muted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _tripGrid(FetchDriver driver, DateTime now) {
    return OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('TRIPWIRES — LAST TRIP PER SENSOR',
              style: OutrideType.section(11)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final s in FetchTripSensor.values)
                _tripChip(driver, s, now),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'A trip means "something moved / sounded / appeared near the '
            'ball" — presence only. A quiet sensor means nothing fired, '
            'not that nothing is there.',
            style: TextStyle(
              fontFamily: OutrideType.mono,
              fontSize: 11,
              color: OutrideColors.muted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _tripChip(FetchDriver driver, FetchTripSensor sensor, DateTime now) {
    final meta = _sensorMeta[sensor]!;
    final trippedNow = driver.latestTripped(sensor);
    final last = driver.lastTripAt(sensor);
    final color = trippedNow ? OutrideColors.amber : OutrideColors.muted;
    return Container(
      width: 156,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: OutrideColors.surface2,
        border: Border.all(
            color: trippedNow ? OutrideColors.amber : OutrideColors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(meta.label,
                  style: OutrideType.chip(color)),
              const Spacer(),
              Text(trippedNow ? 'TRIPPED' : 'QUIET',
                  style: OutrideType.chip(color)),
            ],
          ),
          const SizedBox(height: 4),
          Text(meta.hint,
              style: const TextStyle(
                fontFamily: OutrideType.mono,
                fontSize: 10,
                color: OutrideColors.muted,
              )),
          const SizedBox(height: 4),
          Text(
            last == null
                ? 'last trip: never'
                : 'last trip: ${_clock(last)} (${_age(last, now)})',
            style: const TextStyle(
              fontFamily: OutrideType.mono,
              fontSize: 10,
              color: OutrideColors.onDark,
            ),
          ),
        ],
      ),
    );
  }

  Widget _gaugesCard(FetchDriver driver) {
    final latest = driver.latest;
    return OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('LIVE READINGS — LATEST EVENT', style: OutrideType.section(11)),
          const SizedBox(height: 12),
          _GaugeBar(
            label: 'MAG_G',
            value: latest?.magG,
            max: 2.0,
            threshold: 1.0,
            thresholdLabel: '1.0 g rest',
            format: (v) => '${v.toStringAsFixed(2)} g',
            tripped: latest?.accelTrip ?? false,
          ),
          const SizedBox(height: 14),
          _GaugeBar(
            label: 'MIC_RMS',
            value: latest?.micRms,
            max: 300000,
            threshold: FetchEvent.micTripThreshold,
            thresholdLabel: 'trip 150k',
            format: (v) => v >= 1000
                ? '${(v / 1000).toStringAsFixed(1)}k'
                : v.toStringAsFixed(0),
            tripped: latest?.micTrip ?? false,
          ),
          const SizedBox(height: 8),
          const Text(
            'mag_g sits near 1.00 g at rest; mic RMS is 24-bit samples '
            '(room floor ~10–35k on the bench). Bars show the latest '
            'event, not a live stream — the ball only sends on a trip.',
            style: TextStyle(
              fontFamily: OutrideType.mono,
              fontSize: 11,
              color: OutrideColors.muted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _gpsCard(FetchDriver driver, DateTime now) {
    final gps = driver.latestGps;
    final fixed = gps?.gpsFix ?? false;
    return OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('GPS — BALL POSITION', style: OutrideType.section(11)),
          const SizedBox(height: 8),
          Row(
            children: [
              OutrideChip(
                label: fixed ? 'FIX' : 'NO FIX',
                color: fixed ? OutrideColors.green : OutrideColors.muted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  fixed
                      ? 'Position is where the ball is, not a target.'
                      : 'No fix yet — the ball needs sky view. Indoors '
                          'this reads NO FIX; that is expected, not a fault.',
                  style: const TextStyle(
                    fontFamily: OutrideType.mono,
                    fontSize: 12,
                    color: OutrideColors.muted,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _kv('Satellites', gps?.sats == null ? '—' : '${gps!.sats}'),
          _kv('Latitude',
              gps?.lat == null ? '—' : gps!.lat!.toStringAsFixed(6)),
          _kv('Longitude',
              gps?.lon == null ? '—' : gps!.lon!.toStringAsFixed(6)),
          _kv('Last update',
              gps == null
                  ? '— none yet'
                  : '${_clock(gps.receivedAt)} (${_age(gps.receivedAt, now)})'),
        ],
      ),
    );
  }

  Widget _feedCard(FetchDriver driver, DateTime now) {
    final events = driver.events;
    return OutridePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Expanded so the title wraps instead of overflowing
              // on a narrow phone.
              Expanded(
                child: Text('EVENT FEED — NEWEST FIRST',
                    style: OutrideType.section(11)),
              ),
              Text('${events.length} kept',
                  style: OutrideType.section(10)),
            ],
          ),
          const SizedBox(height: 8),
          if (events.isEmpty)
            const Text(
              'Listening on UDP 49160 — no Fetch events yet. Plug the '
              'ball in, press Start, and start the bridge, or wait for '
              'a trip.',
              style: TextStyle(
                fontFamily: OutrideType.mono,
                fontSize: 12,
                color: OutrideColors.muted,
              ),
            )
          else
            for (final e in events) _eventRow(e, now),
        ],
      ),
    );
  }

  Widget _eventRow(FetchEvent e, DateTime now) {
    final tripped = e.trippedSensors;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: OutrideColors.surface2,
        border: Border.all(color: OutrideColors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(_clock(e.receivedAt),
                  style: OutrideType.rowValue(OutrideColors.onDark)),
              const SizedBox(width: 8),
              Text(_age(e.receivedAt, now),
                  style: OutrideType.rowLabel()),
              const Spacer(),
              if (tripped.isEmpty)
                const Text('NO TRIP FLAGS',
                    style: TextStyle(
                      fontFamily: OutrideType.mono,
                      fontSize: 10,
                      color: OutrideColors.muted,
                    )),
            ],
          ),
          // Trip chips wrap below the clock row: all five firing at
          // once must never overflow the card, on any width.
          if (tripped.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final s in tripped)
                  OutrideChip(
                      label: _sensorMeta[s]!.label,
                      color: OutrideColors.amber),
              ],
            ),
          ],
          const SizedBox(height: 6),
          Wrap(
            spacing: 14,
            runSpacing: 2,
            children: [
              _mini('mag_g',
                  e.magG == null ? '—' : '${e.magG!.toStringAsFixed(2)} g'),
              _mini('mic_rms',
                  e.micRms == null
                      ? '—'
                      : e.micRms! >= 1000
                          ? '${(e.micRms! / 1000).toStringAsFixed(1)}k'
                          : e.micRms!.toStringAsFixed(0)),
              _mini('BLE nearby', e.bleNearby == null ? '—' : '${e.bleNearby}'),
              _mini('Wi-Fi beacons',
                  e.wifiBeacons == null ? '—' : '${e.wifiBeacons}'),
              _mini('GPS',
                  e.gpsFix && e.lat != null && e.lon != null
                      ? '${e.lat!.toStringAsFixed(4)}, ${e.lon!.toStringAsFixed(4)}'
                      : 'no fix'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _mini(String label, String value) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
              text: '$label ',
              style: const TextStyle(
                fontFamily: OutrideType.mono,
                fontSize: 11,
                color: OutrideColors.muted,
              )),
          TextSpan(
              text: value,
              style: const TextStyle(
                fontFamily: OutrideType.mono,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: OutrideColors.onDark,
              )),
        ],
      ),
    );
  }

  Widget _kv(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: Text(label, style: OutrideType.rowLabel()),
          ),
          Expanded(
            child: Text(value, style: OutrideType.rowValue(OutrideColors.onDark)),
          ),
        ],
      ),
    );
  }
}

/// Horizontal bar gauge with a threshold marker line.
///
/// [value] null = no reading yet (empty bar, "—"). The marker sits at
/// threshold/max across the bar; the label names what the marker is
/// (rest baseline for mag_g, trip line for mic_rms).
class _GaugeBar extends StatelessWidget {
  const _GaugeBar({
    required this.label,
    required this.value,
    required this.max,
    required this.threshold,
    required this.thresholdLabel,
    required this.format,
    required this.tripped,
  });

  final String label;
  final double? value;
  final double max;
  final double threshold;
  final String thresholdLabel;
  final String Function(double) format;
  final bool tripped;

  @override
  Widget build(BuildContext context) {
    final v = value;
    final frac = fetchGaugeFraction(v, max);
    final tfrac = fetchGaugeFraction(threshold, max);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: OutrideType.rowLabel()),
            const Spacer(),
            Text(
              v == null ? '—' : format(v),
              style: OutrideType.readout(
                  20, tripped ? OutrideColors.amber : OutrideColors.onDark),
            ),
          ],
        ),
        const SizedBox(height: 6),
        LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            return SizedBox(
              height: 14,
              child: Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: OutrideColors.surface2,
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(color: OutrideColors.border),
                    ),
                  ),
                  if (v != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        width: w * frac,
                        decoration: BoxDecoration(
                          color: (tripped
                                  ? OutrideColors.amber
                                  : OutrideColors.purple)
                              .withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(7),
                        ),
                      ),
                    ),
                  Positioned(
                    left: w * tfrac - 1,
                    top: 0,
                    bottom: 0,
                    child: Container(
                      width: 2,
                      color: OutrideColors.onDark,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 4),
        Text(
          '▲ $thresholdLabel',
          style: const TextStyle(
            fontFamily: OutrideType.mono,
            fontSize: 10,
            color: OutrideColors.muted,
          ),
        ),
      ],
    );
  }
}

class _ScopeNote extends StatelessWidget {
  const _ScopeNote();

  @override
  Widget build(BuildContext context) {
    return const Text(
      'SCOPE: The Fetch reports presence and movement near itself — a '
      'thrown ball that hears, feels, and sees motion. It never '
      'identifies anyone, never carries a camera, and never aims '
      'anything. Voice alerts say "possible person", "movement", or '
      '"sound" plus a position — never enemy, friendly, civilian, or '
      'armed status. The operator decides what a detection is. '
      'BLE/Wi-Fi tripwires watch device addresses, never '
      'who owns them, and the ball itself is listen-only: it never '
      'joins, connects, or transmits to disrupt.',
      style: TextStyle(
        fontFamily: OutrideType.mono,
        fontSize: 11,
        color: OutrideColors.muted,
        height: 1.6,
      ),
    );
  }
}
