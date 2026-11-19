# Outride Fusion Architecture Spec

Status: written 2026-10-28 from Draco's directives. Concept + architecture spec —
not a build log. Companion specs: `sensor_protocol_spec.md`,
`confidence_math.md`, `mesh_mode_spec.md`, `zmeta_adapter_spec.md`,
`prc163_ground_tracks_spec.md`, `predator_integration_spec.md`,
`fieldwatch_borrow_v0260_spec.md`, `pmr_monitor_spec.md`.

## 1. The rule

Outride is the fusion of all data.

- **Universal ingestion (2026-10-17, his words):** "if it can sense
  something I want it integrated to feed outride."
- **Multi-effect (2026-10-28, his words):** never tie to one sensing
  effect. Even with a Silvus radio on the EUD, other sensors connect
  at the same time.
- **Fusion-on-connect (2026-10-28, his words):** as long as a node can
  connect to Outride, its data gets fused. Connection is the only
  admission test for fusion — there is no second, per-sensor opt-in
  gate standing between a connected node and the fused picture.
- **ZMeta analogy (2026-10-28, his words):** just as ZMeta fuses data
  from a vast number of sources at the operational/strategic level,
  Outride fuses data from all connected nodes at the tactical level.

## 2. Definitions

- **Node:** anything connected to Outride, regardless of what it is
  or how it connects. A Silvus radio, an ESP32, a phone, a lidar
  module, a mmWave module, a camera, an SDR, a CoT feed, a
  BEAST+ bearing, a PRC-163 position — all nodes, equal at the
  fusion layer.
- **Connected (admitted):** the node has passed the transport's
  admission control and its observations reach the ingest layer.
  Admission control is about *who may connect* (pairing, PSK,
  trusted-sender allowlist, gateway platform binding); it is not a
  second fusion decision. Once admitted, data is fused.
- **Disturbance:** any sensor's report that something changed or
  moved in its field — an RF link dip, a lidar range change, a
  mmWave motion event, a CSI pose shift, a camera motion cue.
  Disturbances are the common currency of fusion.
- **Fused picture:** the single time-aligned view built from all
  admitted nodes' disturbances — tracks, confidence, and the
  evidence sheet. It is a scene model, not a photograph (see §9).

## 3. Principles

1. **Fusion-on-connect.** An admitted node's data enters the fusion
   pipeline by default. (This supersedes the older per-feed opt-in
   defaults — see §10 — which existed to limit false alarms. Under
   this spec, quality control moves into the merger's gating, not
   into on/off switches.)
2. **Corroborate, never veto.** A sensor may raise confidence, add
   detail, or refine a track. It may never cancel a detection on
   its own. The RF tripwire stays the detection authority: a
   detection originates from the RF layer, and other layers confirm,
   refine, or leave it alone.
3. **Independent sensing.** No sensor reads another sensor's signal.
   The lidar does not read the Silvus mesh; the mmWave module does
   not read the lidar. Each instrument measures the world directly.
   Fusion happens at the track/confidence level, combining
   independent measurements of the same world.
4. **Simultaneity.** Outride shows disturbances from the Silvus
   mesh network at the same time as disturbances from every other
   connected sensor. One timeline, one picture — never sequential
   views, never either/or.
5. **Confirm-only layers stay confirm-only.** Cameras, cooperative
   Remote ID contacts, and hypothesis-labeled signature matches may
   upgrade a track. They never originate one.
6. **Event-only contracts are respected.** Where a node reports
   events only (e.g. a sensor ball reporting motion yes/no, no raw
   streams), fusion consumes events. It never demands a raw stream
   the node does not send.
7. **No silent degradation.** A dead, stale, or jammed feed is
   reported as degraded (stale-on-error, band-degraded alerts),
   never quietly dropped from the picture while pretending the
   picture is whole.

## 4. Ingest: how nodes connect

All ingest converges on typed observations. The wire format is the
Outride Sensor Protocol (`sensor_protocol_spec.md`): typed
RANGE / BEARING / SPECTRUM / BINARY / ENERGY / MOTION messages
over UART text lines and UDP 49160 JSON, consumed by
`generic_sensor_driver.dart` and the node UDP hub
(`node_udp_hub.dart`: flood guard, trusted-sender allowlist).

| Node class | Path into Outride | Observation types |
|---|---|---|
| Silvus mesh radios (SC4200P pair) | `silvus_api.dart` keep-alive polling | Link disturbances → tripwire / mesh imaging |
| ESP32 sensor nodes (CSI, IMU, mmWave) | UDP 49160 JSON / ESP-NOW relay | MOTION, ENERGY, RANGE |
| Lidar modules (single-point ToF, 2D scan) | Sensor Protocol UART/UDP | RANGE (+ scan geometry where offered) |
| mmWave modules (60 GHz A121-class, 24 GHz) | Sensor Protocol UART/UDP/SPI bridge | RANGE, MOTION, BINARY (presence) |
| WiFi CSI nodes (ESP32 CSI, Intel 5300, Nexmon) | Sensor Protocol UDP | MOTION, pose cues (see §8) |
| Phone / EUD tier | `phone_tier.dart`, `wifi_sense.dart`, `ble_scan.dart`, `remote_id_service.dart` | WiFi/BLE presence, Remote ID (cooperative only), Hunt proximity |
| SDR bridge (RTL-SDR/Pluto, RX-only) | `sdr_bridge.py` → UDP JSON; PMR monitor → UDP 49161 | SPECTRUM, BINARY, ENERGY, Doppler refs |
| LoRa backhaul nodes | LoRa PSK-encrypted link → gateway → UDP JSON | MOTION, RANGE (event reports) |
| Cameras (ONVIF / motion webhook / X10D RTSP) | `camera_driver.dart`, drone tab | Confirm-only visual cue |
| CoT feeds (Predator-RF, BEAST+ bearings, PRC-163 PLI, TAK) | `cot_listener.dart` (multicast 239.2.3.1:6969, TAK TCP 8087) | BEARING, friendly ground tracks, emitter corroboration |
| Meshtastic nodes | `meshtastic_driver.dart` (TCP 4403) | MOTION, position |

Transport note (EUD): the Silvus link, Wi-Fi feeds, BLE feeds,
and UDP feeds run concurrently. The phone's single USB port is the
only one-accessory-at-a-time constraint, and wireless nodes do not
need it.

## 5. Time alignment

Simultaneity is only real if observations share a clock.

- Every observation carries a timestamp at ingest. Field-kit nodes
  use GPS/PPS time sync where available (NMEA UTC epoch, wrap-safe
  clocks); phone-tier observations use device time.
- The merger weights freshness explicitly: merged confidence
  `w_s = freshness · health · quality` (`confidence_math.md`).
  Stale observations decay; they do not linger as current truth.
- Per-node and per-link baselines are kept separately
  (`adaptive_baseline.dart`). A baseline is never global across
  nodes, links, or sensor types — each instrument is judged
  against its own history.
- Cross-sensor coincidence windows are explicit where they exist
  (e.g. Predator emitter-track corroboration: 50 m coincidence,
  upgrade-only). No silent window is assumed.

## 6. Fusion pipeline

Stages, with the services that own them:

1. **Ingest + validate.** Typed observations arrive; malformed
   packets are rejected, never coerced into a detection.
   (`generic_sensor_driver`, `sensor_protocol`, `node_udp_hub`,
   `radio_driver`, `cot_listener`.)
2. **Baseline + detect.** Each instrument's disturbance is judged
   against its own adaptive baseline: RF link dips and variance
   channel (`adaptive_baseline`, `tracker`), SDR occupancy and
   Doppler refs, lidar range deltas, mmWave motion events, CSI
   motion/pose shifts.
3. **Corroborate.** Independent observations of the same region
   and window raise confidence and add attributes (range from
   lidar/mmWave, bearing from DF/CoT, pose from CSI, visual
   confirmation from a cued camera). Corroboration is
   upgrade-only. (`confidence_merger`, `track_consistency`,
   `tracker_gating`, `ai_classifier` disturbance labels.)
4. **Merge + track.** The gated confidence merger combines RF base
   confidence with corroboration; the tracker stitches fixes into
   tracks with size / distance / speed / heading estimates and
   inbound/outbound state against the draggable defended point.
   (`tracker`, `track_stitcher`, `track_consistency`.)
5. **Present.** One picture, three surfaces: the tracking screen
   (merged CONFIDENCE row, blobs/trails, health overlay), the
   evidence sheet (event timeline scrubber, per-event triage
   ACK / FALSE ALARM, experimental sections labeled as such), and
   outbound feeds — CoT emit (`cot_publisher`, 1 Hz/track
   throttle) and ZMeta emit-only (`zmeta_adapter`).

What the pipeline never does: it never lets a confirm-only layer
originate a track; never lets a signature hypothesis present as
identity (HYPOTHESIS / USER-ADDED labels stay on); never fuses a
packet that fails its `"experimental": true` honesty marking
(PMR monitor rule); never presents a cooperative Remote ID
contact as a detection.

## 7. Relationship to ZMeta

Outride fuses at the tactical level; ZMeta fuses at the
operational/strategic level. The analogy is structural, not a
merger of the two systems:

- Outride's fused picture is the tactical input. It is emitted
  upward through the emit-only ZMeta adapter
  (`zmeta_adapter.dart`, `power_dbm: 0.0` sentinel for passive
  links) to the gateway, which enforces platform binding.
- ZMeta's fusion above Outride is out of Outride's scope and
  never feeds detection authority back down into Outride's
  tracker. Fusion flows up; authority stays tactical.
- The same rule that governs Outride's own layers governs the
  boundary: Outride's emit is observation, not command.

## 8. WiFi CSI pose in this architecture

WiFi CSI pose estimation (the `wifi-densepose` concept vetted
2026-10-09) is a corroboration layer in this architecture, not a
detection layer and not a Silvus capability:

- It requires per-subcarrier CSI. Silvus links report per-link
  SNR/MCS, not CSI — they cannot feed a pose model, and no spec
  here claims otherwise.
- The CSI sources are ESP32 CSI nodes, Intel 5300-class tools, or
  Nexmon-patched Broadcom — admitted as ordinary Sensor Protocol
  nodes.
- A pose estimate enters fusion as a coarse stick-figure cue:
  joint positions with confidence, upgrade-only, labeled as
  model inference, never as a sighting and never as identity.
- The vetted `wifi-densepose` repo itself is not a dependency:
  3 commits, copy-pasted install instructions, license mismatch,
  and a false hardware-agnostic claim. Any pose capability is
  built from the CSI sources above, not cloned from that repo.

## 9. Honest limits: what the fused picture is and is not

The fused picture is a rendered scene model: positions, sizes,
speeds, headings, and rough poses on one map, updating live.
It is not a photograph, and no combination of these sensors
makes it one:

| Layer | What it actually contributes | Resolution / honesty note |
|---|---|---|
| RF tomography | Disturbance blobs, trails | Meter-scale; never silhouettes |
| Lidar | Surface geometry point cloud | Centimeter geometry; no color/texture; LOS only |
| mmWave | Sparse points + Doppler velocity | Coarse; velocity is its strength, shape is not |
| WiFi CSI pose | Inferred joint positions | Coarse, model-inferred; ghost/swapped joints possible |
| Camera (cued) | Actual pixels | Only with LOS + light; the only photographic layer |
| SDR / spectrum | Occupancy, signatures, Doppler | Detection/cueing, not imaging |

Consequences, stated plainly in-app and in chat: the fused view
never shows a face, clothing, held objects, or readable detail;
pose figures are model guesses, not sightings; RF-silent
fiber-optic FPV drones remain invisible to the RF layer (other
layers may still catch them, and that is exactly why fusion
exists); two nodes remain tripwire-only and tracking needs three
or more positioned nodes, whatever else is connected.

## 10. Open build items (carrying this spec into code)

1. **Default flip:** change per-feed opt-in defaults to
   fused-on-connect per §3.1, with merger gating as the quality
   control. Feeds affected: Wi-Fi/BLE signature library
   (currently default off), BSense tracker gating (currently
   opt-in), Hunt heat-map mode (currently opt-in). Each flip
   ships with its honesty label intact (HYPOTHESIS, PROXIMITY
   ONLY, PHONE-RANGE).
2. **Node onboarding checklist for each new sensor class:**
   transport + admission control, Sensor Protocol type mapping,
   timestamp source, per-node baseline procedure, coincidence
   window (if any), honesty label, merger weight treatment.
   - **Fetch (sensor ball), onboarded 2026-11-12 — deliberate
     deviations recorded, not silent drift:** transport is the
     shared UDP 49160 hub (same flood guard, 16 KB cap, optional
     source allowlist) but the wire format is the ball's bespoke
     FUSED JSON, not the typed Sensor Protocol RANGE/BINARY/MOTION
     observations; merger weight is explicitly zero (display-only,
     staged — whether Fetch trips feed the tripwire is a follow-up
     operator decision, so §3.1 fusion-on-connect as written is
     not yet met for this class); timestamps are receive time (§5
     satisfied — the ball sends no clock); the per-node baseline
     lives on the ball (first two radio scans after boot, ~10 s);
     admission control is the hub allowlist, off by default, same
     as the other sensor drivers.
3. **Fused-view rendering:** single tracking-screen surface
   showing Silvus disturbances and all other connected sensors'
   disturbances on one timeline, with per-source badges and a
   degraded-feed indicator per §3.7.
4. **Fetch voice alerts (EXPERIMENTAL, 2026-11-12):** spoken Fetch
   trip alerts through the EUD audio output (on-device flutter_tts,
   offline; Settings default OFF, rate 0.1–1.0, mute toggle on the
   Fetch tab). Position sources, in priority order: (a) live ball
   GPS fix in the event + fresh operator fix (≤ 60 s); (b) recorded
   throw point (session-only) + fresh operator fix — the phrase
   says "from throw point" so the operator knows it is not a live
   fix; (c) neither — the sensor phrase alone, never a guessed
   direction. Direction comes ONLY from positions: the ball's
   sensors (mic, mmWave, BLE, Wi-Fi) cannot give a bearing, and
   nothing here implies otherwise. Wording rule: the Fetch senses
   movement/presence — it never identifies anyone as an enemy, a
   friendly, or a civilian, and never states armed status; mmWave
   is the person-class channel ("Possible person"), the rest stay
   neutral ("Movement" / "Sound" / "New radio" / "New Wi-Fi"); the
   operator decides what a detection is. Limits: indoor GPS
   usually dies, so indoor alerts are direction-free; audio reach
   is this EUD only (whole-team distribution needs a radio bridge,
   out of scope); no RSSI ranging — the FUSED wire format carries
   no RSSI fields (ble_nearby/wifi_beacons are counts only);
   compass heading is DEFERRED — no verified heading ships in v1,
   so phrases use cardinal directions until compass validation on
   the EUD. Under ~10 m the alert speaks the sensor phrase only,
   with no direction or distance: at CQB ranges the bearing is
   dominated by GPS error (each fix ±several m), and at 0 m the
   bearing of identical points is atan2(0,0) = 0 ("north") — a
   direction invented where none exists. One channel per event: a
   multi-sensor event speaks only its highest-priority
   unsuppressed channel (person-class first), never one utterance
   per tripped sensor. Throttle: same sensor suppressed 10 s, a different
   sensor breaks through immediately, utterances serialize through
   a bounded queue of 3 (oldest dropped). A hung speak times out
   after 20 s and the service recovers instead of going silent
   forever. Voice alerts read Fetch
   events only — the driver stays display-only, merger weight
   zero, never drives the tripwire.
5. **Admission ≠ trust:** gateway allowlist / PSK / pairing
   controls remain the connection gate. A node that cannot
   authenticate does not connect and therefore is not fused —
   that is admission working, not a fusion opt-out.
6. **No scope change to the defensive-only boundary:**
   CONTRIBUTING.md still governs. Fusion adds sensing, never
   transmit-to-disrupt.

## 11. Sources and provenance

- Directives: 2026-10-17 universal ingestion (dated log
  `memory/2026-10-17.md`); 2026-10-28 multi-effect and
  fusion-on-connect (this conversation; MEMORY.md).
- Architecture facts: `~/workspace/rf_sentry/` services and docs
  as inventoried for v0.27.0 (CHANGELOG v0.27.0 → v0.15.x,
  `lib/services/`, `docs/`), and the Outride capabilities list
  delivered 2026-10-28.
- ZMeta: github.com/JTC-byte/zmeta-spec (downstream consumer
  only); Outride = tactical, ZMeta = operational/strategic.
- WiFi CSI pose vetting: 2026-10-09 `wifi-densepose`
  assessment (dated log `memory/2026-10-09.md`).
