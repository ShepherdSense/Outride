# Meshtastic Driver Spec

`lib/services/meshtastic_driver.dart` — driverId `meshtastic`.

## What it does

Connects to a Meshtastic node's client API over TCP (default port 4403),
performs the `want_config` handshake, and maintains the mesh's NodeDB:

- **Node positions** — every mesh node's GPS position → the tracking map
  (auto-placed via `_applyMeshPositions`; a dragged node keeps its manual
  position).
- **Per-packet link series (2026-11-28, improvement #1)** — EVERY
  received MeshPacket is logged into `MeshLinkSeries` (shared store in
  `lib/services/meshtastic_link_series.dart`) as sender → our node,
  with `rx_snr`, `rx_rssi`, timestamp, hop count, and portnum. The
  store is a bounded ring buffer (512 samples/edge, 256 edges) with a
  step-change detector (`detectStep`: median of last K vs median of
  prior window). A step is CONSISTENT WITH a link disturbance, never
  proof of one; Meshtastic is NOT tripwire-grade.
- **Coarse link data** — two LinkSample families:
  - `meshtastic:local → meshtastic:!<id>` — SNR/RSSI at which *our*
    node heard that node (from `NodeInfo.snr` / per-packet `rx_rssi`).
  - `meshtastic:!<a> → meshtastic:!<b>` — neighbor edges with SNR (from
    the NeighborInfo module, portnum 71, when the mesh broadcasts it).
- **Channel-utilization telemetry** — ChUtil / AirUtil from
  `DeviceMetrics` (telemetry portnum 67, and `NodeInfo.device_metrics`),
  recorded into the series and into `MeshChannelUtilization`.
- **Probe reports** — Outride link-reports on private portnum 300
  (see `meshtastic_probe.dart`) are decoded into series edges
  reporter → heard (sender → neighbor), the NeighborInfo /
  LinkSample convention, so the series edge and the neighbor table
  agree on direction (fixed 2026-11-28: they used to disagree).
  The report's `senderNodeNum` is cross-checked against the
  packet's `from`; a mismatch is malformed and dropped (counted in
  `malformedCount`).
- **Node loss** — nodes silent > 2× `sampleMaxAge` are pruned; disappearance
  shows as lost links, not phantom data.

## Design decision — RX-only stance CHANGED (2026-11-28)

The driver historically never transmitted on the mesh. That stance
changed with improvement #2, and the change is recorded here, in the
driver header, and in `docs/meshtastic_hygiene_config.md` — not slipped
in silently. When the operator explicitly opts in to probing
(`MeshtasticProbeSender.enabled`, OFF by default), Outride transmits
normal Meshtastic broadcast packets on OUR OWN channel via the local
node's client API (`ToRadio{packet}`, portnum 300 link-reports).
That is legitimate operation of our own mesh, not an attack: ordinary
mesh traffic, broadcast, on a private portnum, carrying only link
measurements our nodes already made. Nothing here jams, deauths,
spoofs, or touches any other network. With probing off (the default)
the driver is RX-only exactly as before. Probing is also gated by a
channel-utilization guard (refuses above a projected 10%).

## New files (2026-11-28)

- `lib/services/meshtastic_proto.dart` — shared protobuf wire
  helpers + `MeshPacketInfo` decode (incl. `rx_rssi` sign-extension).
- `lib/services/meshtastic_link_series.dart` — `MeshLinkSample` /
  `MeshLinkSeries` ring buffer + step detector + `MeshChannelUtilization`.
- `lib/services/meshtastic_probe.dart` — "ORT1" v1 link-report payload
  (portnum 300), `MeshtasticProbeSender` (OFF by default, 1–5 min
  cadence, ≤10% utilization guard), `ProbeChannelGuard`.
- `lib/services/meshtastic_mqtt_tap.dart` — `MeshtasticMqttTap`
  (`mqtt_client`, QoS 0): subscribes to OUR PRIVATE broker, ingests
  every `ServiceEnvelope` into the same series. Throws for the public
  broker `mqtt.meshtastic.org`. Coverage stat: `packetsSeen`.
- `lib/services/meshtastic_mesh_config.dart` — `MeshtasticMeshConfig`
  with `validate()` (32-byte PSK, hop limit 1–7, ≤3 admin keys, AEAD
  required, `ignore_mqtt` required on infrastructure and whenever
  downlink is on) and `authenticated` (AEAD authenticates on its
  own; without AEAD only STRICT signing does).
- `docs/meshtastic_hygiene_config.md` — the locked deployment config.
- `LinkSample` gains `rssi` (dBm, nullable) and `authenticated`
  (default false = untrusted fusion input: corroborate/upgrade,
  never veto; Meshtastic never vetoes a Silvus tripwire).

## Protocol

Framing (streaming transports): 4-byte header `[0x94, 0xC3, lenMSB, lenLSB]`
+ protobuf payload. Non-header bytes are debug text and are skipped.

Client → radio: `ToRadio{want_config_id}` (field 3, varint).
Radio → client: `FromRadio` stream. The radio answers the handshake with
its full NodeDB (`node_info` packets), then live `packet`s.

Protobuf is decoded by the shared minimal wire reader
(`MeshProtoReader` in `meshtastic_proto.dart`: varint,
fixed32/sfixed32/float32, length-delimited; unknown fields skipped, so
firmware additions can't break the parse). The driver used to carry
its own private copy; it was unified onto the shared reader in the
2026-11-28 review fix round (the len-0 bug had existed in both
copies). Only these fields are read
(verified against meshtastic/protobufs `mesh.proto`, `telemetry.proto`,
`mqtt.proto` on 2026-11-28 — master, current at that date):

| Message | Field | Wire | Meaning |
|---|---|---|---|
| FromRadio | 2 | LEN | MeshPacket |
| FromRadio | 3 | LEN | MyNodeInfo (our node number) |
| FromRadio | 4 | LEN | NodeInfo |
| MyNodeInfo | 1 | varint | my_node_num |
| NodeInfo | 1 | varint | node number |
| NodeInfo | 3 | LEN | Position |
| NodeInfo | 4 | 32-bit | snr (float, dB) |
| NodeInfo | 6 | LEN | DeviceMetrics (ChUtil/AirUtil) |
| Position | 1,2 | 32-bit | latitude_i, longitude_i (sfixed32, ×1e-7 deg) |
| MeshPacket | 1 | 32-bit | from (fixed32) |
| MeshPacket | 2 | 32-bit | to (fixed32) |
| MeshPacket | 4 | LEN | Data (decoded) |
| MeshPacket | 8 | 32-bit | rx_snr (float) |
| MeshPacket | 9 | varint | hop_limit |
| MeshPacket | 12 | varint | rx_rssi (int32, sign-extended from 32 bits) |
| MeshPacket | 15 | varint | hop_start |
| Data | 1 | varint | portnum |
| Data | 2 | LEN | payload |
| Telemetry | 2 | LEN | device_metrics |
| DeviceMetrics | 3 | 32-bit | channel_utilization (float, %) |
| DeviceMetrics | 4 | 32-bit | air_util_tx (float, %) |
| NeighborInfo | 4 | LEN | neighbors (repeated) |
| Neighbor | 1 | varint | node_id |
| Neighbor | 2 | 32-bit | snr (float) |
| ToRadio | 1 | LEN | packet (MeshPacket to send) |
| ToRadio | 3 | varint | want_config_id |
| ServiceEnvelope | 1 | LEN | MeshPacket |
| ServiceEnvelope | 2 | LEN | channel_id (string) |
| ServiceEnvelope | 3 | LEN | gateway_id (string) |

**CORRECTION (2026-11-28): the deep-dive report claimed `rx_rssi`
was MeshPacket field 9. It is field 12; field 9 is `hop_limit`.**
Reading field 9 as RSSI would silently record hop-limit values
(0–7) as RSSI. Verified verbatim against `mesh.proto` (master):
`from`=1, `to`=2, `channel`=3, `decoded`=4, `encrypted`=5, `id`=6,
`rx_time`=7, `rx_snr`=8, `hop_limit`=9, `want_ack`=10,
`priority`=11, **`rx_rssi`=12**, `delayed`=13, `via_mqtt`=14,
`hop_start`=15, `public_key`=16, `pki_encrypted`=17, `next_hop`=18,
`relay_node`=19, `tx_after`=20, `transport_mechanism`=21 (plus
`xeddsa_signed`=22 in current master). Hop count is
`hop_start − hop_limit` when both are known; `hop_start` 0 means
unknown (firmware before 2.3.0 never populated it), not direct.

`NEIGHBORINFO_APP` = portnum 71. `TELEMETRY_APP` = portnum 67.
Outride probe = portnum 300 (private range 256–511). Other portnums
are ignored for payload purposes, but the packet itself is still
recorded in the link series.

Node IDs follow the ecosystem convention: `meshtastic:!<8 hex digits>`
(e.g. `meshtastic:!a1b2c3d4`), matching `docs` in `lib/utils/node_ids.dart`.

## Timing characteristics

- `sampleMaxAge` = 15 min. Meshtastic telemetry moves on the mesh's own
  slow cadence (position/neighbor broadcasts are minutes apart by
  design) — a few-minute-old SNR is still live evidence.
- The TCP socket persists across polls; reconnect is automatic.
- `poll()` settles 350 ms so the first NodeDB burst lands before sampling.

## Discovery

`RadioDiscovery.scanMeshtastic(cidr)` probes TCP 4403 with the
`want_config` handshake and requires a framed FromRadio header back.
Settings → "Find radios on LAN" runs the Silvus and Meshtastic scans
back-to-back (progress bar split 50/50) and results are tagged with
their driver type — tap to add as the right radio kind.

## USB serial

Raw serial ports are not opened (no serial dependency on any platform).
`MeshtasticDriver.fromAddress('serial:...')` throws with guidance:
run the standard serial-to-TCP bridge on the PC, then add the bridge
address. Documented here so the failure is actionable, not silent.

## Honest scope (also in code)

- Positions update on the mesh's cadence (minutes), not seconds.
- Neighbor SNR is one number per edge — link *health*, not a fast
  disturbance signal. A body crossing a LoRa link *does* move RSSI/SNR
  (LoRa is fade-resistant, not fade-proof), so large disturbances still
  register — but this is coarse presence/health sensing. A step change
  in the per-edge series is CONSISTENT WITH a disturbance, never proof
  of one.
- **Tripwire-grade sensing is Path 2** (SX1276 LoRa backhaul nodes with
  edge tripwires); see `docs/lora_nodes_spec.md`. Meshtastic is never
  labelled tripwire-grade anywhere in code or docs.
- Meshtastic corroboration is never-subtractive: it must never delete
  or downgrade a detection on its own. Unauthenticated mesh data is
  untrusted fusion input (corroborate/upgrade, never veto), and
  Meshtastic samples never veto a Silvus tripwire.
- Encrypted meshes: the client API decrypts locally, so telemetry still
  flows — same physical-layer argument as the rest of Outride.
- `probe()` validates the handshake; `emptyHint` covers "connected but
  no nodes yet".
- Socket binds, parse errors, and MQTT disconnects are surfaced or
  logged, never swallowed silently (driver drops are visible as empty
  polls + `emptyHint`; the probe sender records `lastError`; the tap
  records `lastError` / `disconnectCount` / `malformedCount`).

## Tests

`test/lora_nodes_test.dart`: synthetic protobuf frames (built from the
field table above) verify NodeInfo position/SNR decode, NeighborInfo
edge decode via MeshPacket, framer resync past debug text, portnum
filtering, address parsing, and the `serial:` guidance error.

New in 2026-11-28 (`test/meshtastic_*_test.dart`):
`meshtastic_link_series_test.dart` (ring-buffer bounds, step-change
detection incl. a flat-series negative test, prune, utilization
cap),
`meshtastic_probe_test.dart` (payload encode/decode round-trip,
cadence guard, probing-off default),
`meshtastic_mqtt_tap_test.dart` (ServiceEnvelope decode incl.
`rx_rssi` sign handling, fake-broker subscribe),
`meshtastic_mesh_config_test.dart` (`validate()` accepts the locked
config, rejects the default key / short PSK / hop limit > 7 / > 3
admin keys), plus driver tests for `rx_rssi`/hop-count parsing via
the existing `ingestBytesForTest` hook (real framed FromRadio bytes;
series records SNR + RSSI + hop count).
