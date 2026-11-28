# Meshtastic Mesh Hygiene Config — Locked Deployment Config

Outride's locked, documented Meshtastic deployment configuration
(improvements #4 + #5). This is CONFIG ONLY: every value below is
set on the nodes themselves (Meshtastic app / CLI / admin messages),
not in Outride's code — except the validated model in
`lib/services/meshtastic_mesh_config.dart`, which enforces the
lockable parts (`validate()`) so a bad config fails loudly instead
of shipping silently.

Meshtastic here is a **link-health / presence layer, NOT
tripwire-grade sensing**. Nothing in this doc changes that: the
Silvus layer and the SX1276 backhaul nodes keep the tripwire job.
A parallel investigation is testing whether tripwire-grade is even
possible over Meshtastic; do not pre-empt it, and never label
Meshtastic tripwire-grade anywhere.

## The locked config (summary)

| Setting | Locked value |
|---|---|
| Modem preset | MediumFast (dense); LongFast only for sparse / long-range legs |
| Hop limit | 3 |
| Roles | ROUTER only on powered, elevated, fixed nodes; CLIENT elsewhere; CLIENT_MUTE on battery sensing nodes |
| NodeInfo interval | 3 h (10800 s) |
| Telemetry | deliberate intervals; 30 min mesh default where enabled; disable where unneeded |
| Position | deliberate intervals; smart broadcast on |
| PSK | 32 bytes (AES-256). NEVER the published default key `AQ==` |
| AEAD (`use_aead`) | ON (firmware 2.8.1+) |
| Signed broadcasts | BALANCED policy (firmware 2.8+) |
| Admin | at most 3 admin public keys, session passkeys |
| Zero-cost hops | favorite ROUTER chains (firmware ≥ 2.7.11) |
| MQTT | `lora.ignore_mqtt=true` on ALL infrastructure nodes; downlink OFF unless needed |
| Probing (Outride, portnum 300) | OFF by default; opt-in only; utilization guard ≤ 10% |

## 1. Modem preset

- **MediumFast for dense deployments** (3.52 kbps, 148 dB link
  budget) instead of the LongFast default — ~3.4× the on-air
  capacity for −5 dB link budget. North Georgia's metro mesh
  migrated LongFast → MediumFast for exactly this reason once
  LongFast saturated.
- **LongFast only for sparse / long-range legs** (1.07 kbps,
  153 dB). A 32-byte LongFast packet costs ~477 ms airtime;
  MediumFast ~140 ms; ShortFast ~40 ms (Semtech time-on-air
  formula as implemented in Meshtastic's `getPacketTime`).
- Never mix presets on one mesh: nodes on different presets cannot
  hear each other. A US node whose region is first set from its own
  screen starts on LONG_TURBO instead of LongFast — check the preset
  after first setup.

## 2. Hop limit

- **3.** The docs say it plainly: "Really, 3 is fine."
- 7 is the wire-format ceiling (3 bits in the header), not a
  target. Raising the hop limit above 3 needs a measured reason
  (a bench delivery-ratio measurement), never a hunch.
- Hop count on any received packet is `hop_start − hop_limit`
  (Outride records it per packet in the link series).

## 3. Device roles

| Role | Use in our deployments |
|---|---|
| ROUTER | Powered, elevated, FIXED nodes only. Prioritises forwarding; stays awake to relay; always rebroadcasts. |
| ROUTER_LATE | Supplemental coverage, powered fixed nodes. Rebroadcasts once, after all other modes. |
| CLIENT | Default. Everywhere else. |
| CLIENT_MUTE | Battery sensing nodes that must not relay. Sends/receives, never repeats. |
| CLIENT_HIDDEN | Like CLIENT_MUTE, plus hides from the node list; stealth / power savings. |
| SENSOR / TRACKER | Only where that role's priority traffic is actually wanted. |

- **Never ROUTER on a battery node.** No published controlled
  ROUTER-vs-CLIENT battery measurement exists, but the mechanism
  guarantees higher TX count (ROUTER rebroadcasts even after
  hearing another relay), and a relay that never sleeps burns
  ~0.36 Wh/day on RX alone (SX1262 LoRa RX 4.6 mA × 3.3 V).
- `ROUTER_CLIENT` was removed in firmware 2.3.15; `REPEATER`
  removed in 2.7.11 (use Router). ROUTER misuse causes packet
  collisions, decreased range ("hop gobbling"), and asymmetric links.

## 4. Traffic discipline

- **NodeInfo stays at 3 h.** It is the only regular broadcast
  traffic without extra config.
- **Telemetry / position intervals are set deliberately, never left
  at defaults.** Firmware defaults drift by version — the module
  page says telemetry mesh default 1800 s (30 min); the current
  mesh-algo page says off by default with 1 h when enabled (12 h
  for ROUTER/ROUTER_LATE); the 2.7 page says 30 min. **Cite the
  firmware version when quoting an interval.**
- **Disable telemetry on nodes that don't need it.** In the North
  Georgia capture, ~89% of unique packets were the network
  describing itself (nodeinfo 42.9% · position 26.7% ·
  telemetry 18.9%).
- **>40-node auto-scaling:** `ScaledInterval = Interval × (1.0 +
  (N−40) × 2^SF / (BW_kHz × 100))`; on LongFast each node over 40
  adds 0.08192 — 62 online nodes stretches 1 h → ~168 min.
  ROUTER, ROUTER_LATE, SENSOR, TRACKER, TAK_TRACKER are not scaled.
- **NeighborInfo is informative-only** (does not affect routing),
  off by default, minimum update interval 4 h, default 6 h, SNR
  only (no RSSI). Outride does not rely on it for sensing — the
  per-packet link series (improvement #1) and the probe payload
  (improvement #2) are the sensing inputs.
- **Stagger our own nodes' intervals** where the deployment allows
  (non-overlapping telemetry/position windows per node) — the
  cheapest schedule discipline available without touching the
  protocol. Keep ROUTER count minimal; separate sensing traffic
  from chat traffic by channel where possible.

## 5. Encryption and authentication (improvement #5, config now)

- **32-byte PSK (AES-256)** on our private channel. 16-byte keys
  give AES-128; 0-byte keys give no encryption. The PSK is held as
  bytes and never logged.
- **NEVER the published default key `AQ==`.** `AQ==` is the 1-byte
  shorthand for the published 16-byte default key — anyone can read
  that channel. 1-byte PSK values 2–255 are public derivations of
  the same key. `MeshtasticMeshConfig.validate()` rejects the
  default key in both its 1-byte and 16-byte forms, and rejects any
  PSK that is not exactly 32 bytes.
- **AEAD ON (`use_aead`, firmware 2.8.1+).** AES-CCM under the same
  PSK, 12-byte auth tag per packet. AES-CTR (the default) has no
  integrity check and no forward secrecy: without AEAD, a tampered
  packet decrypts to garbage that looks like data. No fallback — a
  node without the setting relays the packet undecrypted.
- **Signed broadcasts, BALANCED policy (firmware 2.8+).** XEdDSA
  signatures from each node's X25519 key pair. BALANCED rejects
  unsigned broadcasts from nodes known to sign; STRICT rejects all
  unsigned broadcasts. A broadcast too large to carry a signature
  within the 255-byte frame is sent unsigned — size the probe
  payload with that in mind.
- **Admin restricted to our 3 admin public keys** (firmware cap:
  3). Remote admin uses DM encryption; state-changing messages
  must carry an 8-byte session passkey valid 300 s after issue.
- **Trust rule (standing fusion rule): unauthenticated mesh data is
  UNTRUSTED fusion input.** It may corroborate or upgrade, never
  veto — and Meshtastic samples never veto a Silvus tripwire.
  Outride marks this in code: `LinkSample.authenticated` is true
  when the channel is AEAD (the AES-CCM tag authenticates every
  packet, regardless of signing policy) or, without AEAD, when the
  signing policy is STRICT (all unsigned broadcasts rejected).
  AEAD-on + BALANCED is authenticated; AEAD-off + BALANCED is not
  — BALANCED still accepts unsigned broadcasts from nodes not
  known to sign. See `MeshtasticMeshConfig.authenticated`.
  A spoofed NodeInfo can already move a node on our map
  (trust-on-first-use, no central authority) — treat map placement
  from unsigned sources as provisional.
- **Channel hash note:** a secondary channel with no PSK uses the
  primary channel's key. Every channel we operate carries its own
  32-byte PSK.

## 6. Zero-cost hops

- **Favorite our ROUTER chains (firmware ≥ 2.7.11).** A hop is
  preserved (costs no hop budget) iff the relaying node is
  ROUTER / ROUTER_LATE / CLIENT_BASE, it is not the packet's first
  hop, and the previous relay is in your favorites AND is
  ROUTER / ROUTER_LATE. Max hop limit is still 7. This extends
  reach past 7 physical relays on favorited router chains.
- Matching uses the 8-bit `relay_node`, so collisions are possible
  (~0.4% at 10–100 nodes) but "rare and harmless" per the
  Meshtastic post; dedup prevents loops.

## 7. MQTT hygiene (improvement #3)

- **Private broker only — never `mqtt.meshtastic.org` for our
  channel.** The public server enforces a zero-hop policy, caps
  location precision at 10–16 bits on the default PSK, and the docs
  warn against using the default key on a private broker. The tap
  (`MeshtasticMqttTap`) throws if pointed at the public broker.
- **`lora.ignore_mqtt=true` on ALL infrastructure nodes**
  (firmware ≥ 2.2.19). A gateway that uplinks LoRa→MQTT and
  downlinks MQTT→LoRa can loop indefinitely; this is the documented
  mitigation. `validate()` rejects an infrastructure config with
  it off.
- **Downlink OFF** unless a specific use case needs it.
- Gateway topics: `msh/REGION/2/e/CHANNELNAME/USERID`. Per-channel
  Uplink/Downlink default false — enable Uplink only on our gateway
  nodes, on our channel.
- The public-broker defaults (`meshdev` / `large4cats`) are
  published credentials — never use them on our broker.
- **LAN-only transport (no TLS in the tap).** The tap connects
  plain TCP port 1883, so broker credentials go in cleartext —
  run the broker on our own private network only. There is no
  TLS/secure flag in `MeshtasticMqttTap` (doc note is the fix for
  now; a secure port-8883 option is a follow-up, not this round).
- **Scope the subscribe topic when wiring.** The tap's default
  topic `msh/#` ingests every channel on the broker. When the app
  wires the tap, scope it to our channel/region, e.g.
  `msh/US/2/e/<channel>/#`, so other channels' traffic never
  enters our series.

## 8. Probing (Outride link-report, portnum 300)

- **OFF by default.** The probe sender (`MeshtasticProbeSender`)
  refuses to transmit until the operator opts in. Fail-safe default.
- **Cadence 1–5 min, default 5 min.** The channel-utilization
  guard refuses to send when the projected utilization would
  exceed 10% (arithmetic: 32-byte LongFast ≈ 477 ms airtime; a
  10-node mesh at 1 probe/node/5 min adds ~4.8% once the relay
  multiplier is counted — origin-only it would be ~1.6%). The
  guard caps the own-TX projection (origin + relay estimate), not
  a guarantee about total channel load: feed it the freshest
  observed ChUtil (telemetry, percent) when available.
- **Primary channel unless told otherwise.** Probes go out on the
  PRIMARY channel (index 0) unless the caller passes a `channel`
  to `buildToRadioFrame`/`sendOnce`. The earlier claim "on OUR OWN
  channel" holds only when the deployment channel IS the primary;
  on a secondary channel, pass its index explicitly, or the probe
  transmits on the wrong channel, possibly the public default,
  with the wrong PSK.
- **Second TCP connection (unverified).** The sender dials a fresh
  TCP 4403 connection per probe while the driver holds its own
  persistent one. Whether a node's client API tolerates a second
  concurrent client is unverified — bench item 7 below. If it
  disrupts the driver stream, the fallback is to send probes
  through the driver's existing socket.
- **DESIGN DECISION (explicit):** probing changes the driver's
  historical RX-only stance — Outride now transmits normal mesh
  packets on our own channel when probing is enabled. Recorded in
  the driver header, the driver spec, and here. Transmitting to
  disrupt is outside the boundary, full stop; these are ordinary
  broadcasts on our own channel carrying only link measurements.
- Payload format ("ORT1", version 1) and portnum 300 (private
  range 256–511) are documented in `meshtastic_probe.dart`.

## 9. Upstream items (doc only — NOT code)

- Extend the `ack_proof` HMAC pattern (firmware 2.8.1+, currently
  advisory-only for DM ACKs) toward authenticated sensing payloads.
- Register the Outride sensing payload in the 3rd-party portnum
  range (64–127) once the bench proves its value, with a public
  spec. Until then it stays on private portnum 300.
- Propose a NeighborInfo RSSI field and a shorter minimum interval
  for private channels upstream.

## 10. Bench verification checklist

Before a deployment is called good, confirm on the bench:

1. MediumFast + this config holds delivery ratio ≥ 90% at traffic
   levels where LongFast + defaults drop below 80% (measure, don't
   assume — the collapse margin is thin: LongFast saturates at
   ~11 nodes at 1 msg/node/min, MediumFast at ~12.6 in simulation).
2. The MQTT tap sees ≥ 95% of the packets the local node's radio
   sees, plus packets from nodes out of the local node's range.
3. A bench injection of an unsigned/spoofed NodeInfo is rejected
   under STRICT policy while legitimate traffic flows. Under
   BALANCED it is NOT rejected for an unknown spoofer — BALANCED
   only rejects unsigned broadcasts from nodes known to sign — so
   bench item 3 is satisfiable only under STRICT for this case.
   (Under the locked AEAD-on config this framing is about the
   no-AEAD case: with AEAD on, a spoofed NodeInfo is already
   rejected by the AEAD tag, which fails to verify — STRICT adds
   nothing there.)
4. Probing holds its controlled cadence for 24 h with channel
   utilization under 10% and delivery ratio ≥ 90%.
5. Per-edge link series show ≥ 1 sample per 15 min per active
   edge, and a shadowed link shows a visible step change.
6. The firmware fills in `from`/`id` on a probe frame that leaves
   them unset (the sender relies on this — unverified on
   hardware). Confirm on the Heltec bench: send one probe and
   check the received packet carries our node's number and a
   real packet id.
7. A second concurrent TCP 4403 client (the probe sender, while
   the driver holds its persistent connection) does not disrupt
   the driver stream on a real Heltec node. If it does, the
   fallback is to send probes through the driver's existing
   socket — do not wire the sender in until this passes.
8. The MQTT tap survives a broker drop: kill the broker, confirm
   the tap reconnects and resubscribes on its own. Reconnect is
   tap-owned with backoff (5 s → 30 s → 60 s cap) and a circuit
   breaker that stops after 10 consecutive failed reconnects and
   surfaces the give-up in `lastError` — library auto-reconnect
   is OFF (mqtt_client 10.14.0 has no backoff knob and would retry
   with no delay). Watch `disconnectCount` / `reconnectCount` /
   `reconnectAttempts`.

## 11. Wiring checklist — making the package exercisable (review item 16)

The probe sender, MQTT tap, mesh config, and `detectStep` currently
have ZERO call sites in `lib/` — the package is built and tested
but inert in the app. The minimal safe wiring done in this round is
one public read path: the bench reads the driver's series through
the already-public `MeshtasticDriver.linkSeries` field (no settings
UI, no app instantiation). Full wiring is an explicit follow-up
decision for Jeremy, not a silent gap — the exact call sites, when
he approves them:

| Piece | Future call site |
|---|---|
| `MeshtasticMeshConfig` | Construct once (locked config + operator PSK) and pass as `MeshtasticDriver(meshConfig: ...)`; its `authenticated` marks emitted `LinkSample.authenticated`. |
| `MeshtasticMqttTap` | Instantiate once with our private broker host + a channel-scoped topic (`msh/US/2/e/<channel>/#`, not the `msh/#` default) and the SAME `MeshLinkSeries` the driver uses, so tap and driver feed one store; `connect()` on app start (or when the Meshtastic radio is enabled); `lastMessageAt` is the liveness check. |
| `MeshtasticProbeSender` | Instantiate once, `enabled: false` until the operator opts in; `sendOnce` / `startPeriodic` only after bench items 6–7 (§10) pass; pass the freshest telemetry ChUtil (percent) as `observedUtilizationPercent`, and the deployment channel index when it is not primary. |
| `detectStep` | Consume on the bench / a link-health view: `driver.linkSeries.detectStep(from, to)` per edge; a returned step is an estimate, never a detection on its own. |
| ChUtil → guard | Feed `driver.channelUtilization.latest(node).chUtil` (percent) into the sender's `observedUtilizationPercent` so the guard projects on observed load, not 0. |
| `LinkSample.rssi` / `.authenticated` | Consumers are the fusion layer (rssi as a second link-quality signal; authenticated as the untrusted-input flag) — no consumer exists yet; wire when the fusion side is ready. |

Do NOT add settings UI for probing or instantiate the probe sender
/ tap in the app until Jeremy explicitly approves that step — the
bench items in §10 (especially 6–8) are the gate.
