# Outride v0.28.0 — Automatic EUD-to-EUD Meshing (Fleet)

Status: SPEC (2026-11-17). Draco's call, voice: multiple EUDs running Outride connect to each other automatically — no manual IP entry, no manual pairing — as soon as Outride recognizes other Outride devices. Join is gated by a 4-digit PIN on a dialer-style keypad inside Outride. Companion specs: `fusion_architecture_spec.md` (fusion-on-connect), `mesh_mode_spec.md`, `sensor_protocol_spec.md`, `predator_integration_spec.md` (CoT multicast pattern), `zmeta_adapter_spec.md` (X25519 pairing pattern).

## 1. Goal

A fire team of EUDs forms one Outride fleet by proximity on the same Wi-Fi network. The lead creates a fleet with four digits; every other EUD hears it and joins by dialing the same four digits; after that, Outride remembers the fleet and auto-rejoins on sight. The operator experience is only ever four digits on a dialer. All sound crypto lives underneath and never leaks complexity into the UI.

## 2. What already exists (integration points — real files)

- `lib/services/cot_publisher.dart` / `cot_listener.dart` — CoT multicast `239.2.3.1:6969`, lazy-bind socket with shared bind future, serialized start/stop, `MulticastLock`, 60 s window, 256-entry cap, 30 s max clock skew, never-throws datagram path. The fleet service copies this shape; it does not touch these files.
- `lib/services/multicast_lock.dart` — `MulticastLock.acquire()` via MethodChannel `outride/multicast_lock` (already in `MainActivity.kt`).
- `lib/services/node_udp_hub.dart` — process-wide shared UDP 49160 listener, refcounted, 16 KB datagram cap, 2000/s flood guard, `allowedSources` allowlist. Peer data flows through this hub.
- `lib/services/sensor_protocol.dart` — `SensorProtocol.parseUdpJson` / `toUdpJson`, lenient-by-design, never throws. The only parser peer data ever passes through.
- `lib/services/zmeta_pairing.dart` — X25519 keygen via `package:cryptography` (`zmetaGenerateWgKeypair`), private key never leaves the device, secrets in `flutter_secure_storage`, never SharedPreferences. Fleet key exchange follows this pattern.
- `lib/services/device_autoconnect.dart` — `DeviceAutoConnect` 5 s poll cadence, dedupe-by-address, never-overlapping ticks. Fleet beacon cadence matches it.
- `lib/services/radio_driver.dart` — `RadioConfig.driverId` (`'silvus'` real vs `'sim'`); `driverFor(config)` builds the driver. Role label (§6) derives from this, not from a new flag.
- `lib/screens/settings.dart` — Settings screen; ZMeta join is a `showDialog<ZmetaJoinResult>` from here (`zmeta_join_dialog.dart`). Fleet entry follows the same pattern.
- `lib/main.dart` — 8 fixed bottom tabs already (Alerts, Tracking, Beam, WiFi, Drone, Fetch, Spectrum, Settings). No 9th tab: see §7.
- `pubspec.yaml` — `cryptography: ^2.7.0`, `crypto: ^3.0.6`, `flutter_secure_storage: ^11.2.0`, `shared_preferences: ^2.3.2`. No new crypto dependency (see §5).

## 3. Discovery protocol

**Decision: dedicated fleet multicast group `239.2.3.2`, port 6970, TTL 1.** Reusing `239.2.3.1:6969` would put JSON beacons on the CoT wire where TAK / Predator parsers and `CotListener` must silently drop them, and would blur the interop boundary.
A sibling group in the same administratively-scoped range keeps CoT multicast untouched and lets the fleet socket live or die independently of CoT ingest.

**Beacon (UDP multicast, JSON, plaintext — salt and fleet ID are public values; nothing secret is ever in a beacon):**

```json
{"type":"fleet_beacon","v":1,"fleet_id":"<32 hex chars>",
 "salt_b64":"<16 random bytes, base64>",
 "node_id":"<stable per-device id, 16 hex chars>",
 "callsign":"OUTRIDE-<short>",
 "app_version":"0.28.0","has_silvus":true,
 "member_count":3,"t":1731849600}
```

- `fleet_id`: 128-bit random hex, generated once by the lead at creation. `salt_b64`: 16 random bytes, generated with the fleet. Both are public; secrecy is not their job (§5).
- `node_id`: generated once per device at first Fleet use, stored in SharedPreferences. `callsign`: the existing CoT callsign-prefix setting (`AppSettings.cotCallsignPrefix`, default `OUTRIDE-`) plus the first 6 chars of `node_id`.
- `has_silvus`: true iff a non-`sim` radio config exists and its driver is currently live (same liveness the dashboard already shows). Re-evaluated on every beacon; a radio unplug flips the role label within one interval.
- `t`: unix seconds, sender clock. Receivers reject beacons with |skew| > 30 s (same `maxClockSkew` as `CotListener`).

**Interval / dedup / expiry:** beacon every 5 s (same cadence as `DeviceAutoConnect`). Receivers key peers by `node_id` (upsert on repeat, as `CotListener` keys observations by callsign). A peer is declared gone after 15 s without a beacon (3 missed intervals) and dropped from the Fleet screen. Cap: 64 peers held.

**Multiple fleets heard:** all are listed on the Fleet screen as "Fleet \<first 6 of fleet_id\> — N members". Outride auto-rejoins only the remembered fleet (§4). It never joins a second fleet unprompted and never merges fleets. Dialing a PIN attempts a join against the fleet whose beacon the operator tapped.

## 4. Fleet lifecycle

1. **Create (lead):** Fleet screen → "Create fleet" → dialer pad → 4 digits → "Create". Lead generates `fleet_id` + `salt`, derives the fleet key (§5), stores the fleet record, and starts beaconing as a member. No lead-only state exists after this point.
2. **Join:** an unjoined EUD hearing a fleet beacon taps it, dials the same 4 digits, and runs the admission exchange (§5). On success it stores the fleet record and starts beaconing as a member. On failure: "Wrong PIN — try again" (no detail about which step failed).
3. **Remembered fleet (auto-rejoin):** SharedPreferences holds metadata (`fleet_id`, `salt_b64`, `node_id`, `joined_at`); `flutter_secure_storage` holds the key (`fleet_key_b64`, the 32-byte derived key). Same split as ZMeta ingest tokens. **Never stored: the raw PIN.** The PIN cannot be recovered from the device; a forgotten PIN means the lead creates a new fleet.
   On startup, if a fleet record exists and its `fleet_id` is heard in a beacon, Outride re-runs admission silently (stored key, no dialer) and rejoins. If the fleet is not heard, nothing happens — no error, no prompt.
4. **Lead leaves — no single point of failure:** every joined member beacons the fleet (`fleet_id` + `salt` + its own `node_id`). Admission of a late joiner is answered by ANY current member, not only the lead (any member holding the fleet key can verify the join proof, §5).
   If the lead's EUD leaves or dies, the fleet keeps beaconing and admitting. If the last member leaves, the fleet ceases to exist; a new fleet is created from scratch.
5. **Forget fleet:** Settings → Fleet → "Forget fleet" (with a confirm step). Deletes the SharedPreferences record AND the secure storage key, stops beaconing, drops all peers. The EUD is unjoined until it creates or joins again.

## 5. Crypto honesty (non-negotiable)

**Four digits = 10,000 combinations. The PIN is an ADMISSION CODE, never the encryption key itself.** Anyone who could observe the network and brute-force 10,000 PINs offline against a beacon would win if the PIN were the key — so the design never lets that happen:

- **Fleet key derivation:** `Argon2id(PIN, salt)` via `package:cryptography` (already in `pubspec.yaml` — no new dependency). Parameters for a phone-class CPU: memory 64 MiB, iterations 3, parallelism 1, output 32 bytes (~0.5–1 s per derivation — acceptable once per join, and the cost is what makes offline guessing expensive).
  If `cryptography`'s Argon2id is unavailable at build time, the fallback is PBKDF2-HMAC-SHA256, 600,000 iterations (OWASP floor), 32-byte output. Either way the KDF choice is recorded in the stored record (`kdf` field) so a future version never mis-derives.
- **Real key exchange (X25519, mirroring `zmeta_pairing.dart`):** (1) Joiner derives the candidate fleet key from the dialed PIN + beacon salt, generates an ephemeral X25519 keypair (`zmetaGenerateWgKeypair` pattern — private key never leaves the device), and sends a unicast UDP join request to the beaconing member's address on port 6970: `{type:"fleet_join", fleet_id, node_id, callsign, eph_pub_b64, proof_b64}` where `proof_b64` is HMAC-SHA256(fleet_key, eph_pub || node_id || fleet_id).
  (2) The member holds the fleet key and verifies the HMAC. Wrong PIN ⇒ HMAC fails ⇒ silent drop (no "wrong PIN" oracle beyond the joiner's own timeout) and the attempt counts toward rate limiting (below).
  (3) On HMAC success the member replies with its own ephemeral X25519 public key **plus its own proof**: `{type:"fleet_join_reply", fleet_id, node_id, eph_pub_b64, proof_b64}` where `proof_b64` is HMAC-SHA256(fleet_key, member_eph_pub || member_node_id || fleet_id). The joiner verifies that proof with the candidate key BEFORE deriving the session key or storing the fleet record — a reply with a bad or wrong-key proof is rejected exactly like a failed join ("Wrong PIN — try again", no oracle), so a fake member on the same Wi-Fi that holds no fleet key cannot complete admission from the joiner's side. On proof success both sides compute the shared secret and HKDF-SHA256 it (info `"outride-fleet-v1"`) into the 32-byte **session key**. The fleet key is used only for admission; all peer traffic is encrypted under the session key (AES-256-GCM via `package:cryptography`, 12-byte random nonce per datagram, AAD = `fleet_id`).
  (4) Session keys are per-pair (joiner ↔ each member) and rotate on every rejoin; there is no fleet-wide shared traffic key to steal from one captured EUD and reuse everywhere.
- **Rate limiting (makes 10,000 PINs impractical):** each member allows 5 failed join attempts per source IP per 60 s; on the 5th failure that IP is locked out with exponential backoff: 30 s, 60 s, 120 s, 300 s (cap).
  A global cap of 10 failed attempts per minute across all sources triggers a 60 s fleet-wide join freeze. At the post-lockout rate, exhausting 10,000 PINs takes weeks of continuous attempts against a live fleet the operators can see. The UI shows only "Wrong PIN — try again" / "Too many attempts — wait 60 seconds"; no counts, no lockout timers.
- **Interop boundary (standing principle):** encryption stays INSIDE the fleet. The open surfaces are untouched: gateway UDP JSON (49160 plaintext `sensor_obs`), CoT multicast (`239.2.3.1:6969`), and ZMeta ingest keep exactly their current wire formats. Fleet-encrypted traffic never leaves the fleet socket (6970) or the encrypted fleet envelope on 49160 (§6).

## 6. Roles and peer data flow

- **Sensing node** — EUD with a live Silvus radio (`has_silvus` true). Contributes its link measurements to the mesh.
- **Fusion/display peer** — EUD without a radio (`has_silvus` false). Receives the fused picture and displays it; contributes no RF measurements. The Fleet screen labels every member `SENSING` or `FUSION PEER` next to its callsign, and the label follows the live `has_silvus` beacon field — never a one-time claim at join.
- **Peer data path (no new pipeline):** a sensing node sends its observations to joined peers as `SensorProtocol.toUdpJson` payloads, encrypted under the pairwise session key and wrapped in one new envelope on the EXISTING 49160 hub socket: `{"type":"fleet_data","fleet_id":"…","from_node":"…","nonce_b64":"…","ct_b64":"…"}`.
  The receiver's fleet service decrypts, verifies `fleet_id` + AAD, and feeds the inner JSON straight into `SensorProtocol.parseUdpJson` — the same parser, the same lenient never-throws contract, the same sensor bus downstream. A failed decrypt drops the datagram silently (same as a malformed sensor line).
  Sensor IDs from peers are prefixed with the sender callsign (`OUTRIDE-<short>:<sensor>`, within the 48-char `_id` cap) so a peer's `rf1` can never collide with local `rf1`.
- **Fusion rule (standing):** peer observations enter the confidence merger as corroboration/upgrade only — the same contract as `CotListener` (boost ≥ 0, never subtractive). The RF tripwire stays detection authority: a peer can upgrade a track's confidence, never create a track alone and never veto one.
  Fusion follows `fusion_architecture_spec.md` §1 (fusion-on-connect: connection is the only admission test).

## 7. Fleet screen UX (tired-operator test)

**New files:** `lib/screens/fleet_screen.dart` (`FleetScreen`), `lib/services/fleet_service.dart` (`FleetService`: beaconing, listening, admission, session keys, peer table), `lib/services/fleet_dialer.dart` (pure dialer-pad widget + PIN state, unit-testable without a socket), `lib/services/fleet_crypto.dart` (pure functions: KDF, HMAC proof, X25519 exchange, AES-GCM envelope encode/decode — no I/O, no clock).

**Modified files:**
- `lib/main.dart` (no new tab — 8 tabs already fill the bar; Fleet is reached from Settings).
- `lib/screens/settings.dart` (new "Fleet" section: status line, "Open Fleet" button, "Forget fleet").
- `lib/state/app_state.dart` (owns the `FleetService` lifecycle alongside `CotPublisher`/`CotListener`, exposes `fleetPeers` + `fleetStatus`).
- `lib/screens/dashboard.dart` (one-line fleet status chip on the Alerts tab: `FLEET 3 · 2 SENSING` or `NOT IN A FLEET` — tap opens the Fleet screen).

**Layout (dark mode, purple accents — `theme.dart` `OutrideColors`):** top shows own status (`IN FLEET <id…>` / `NOT IN A FLEET`), own role badge (`SENSING` / `FUSION PEER`), member count.
Middle lists joined EUDs — callsign, role badge, link state (`LIVE` / `STALE` / `GONE` by beacon age), last-seen seconds — then fleets heard but not joined ("Fleet … — N members — tap to join").
Bottom is a big dialer pad (1–9, 0, four filled dots as digits are entered, backspace key). "Create fleet" for the lead; joining is tap-a-fleet → dial 4 digits → auto-submit on the 4th digit. No keyboard, no IP field, no second app, no terminal.
Failure states in plain words, never a code: "Wrong PIN — try again", "Too many attempts — wait a minute", "Wi-Fi off — fleet unavailable", "No fleet heard — check Wi-Fi".

## 8. Discovery lifecycle, permissions, degraded networks

- **Foreground service:** fleet beaconing/listening runs under a NEW Android foreground service (none exists today — no `FOREGROUND_SERVICE` permission or `startForeground` call is in the tree) with a persistent notification ("Outride Fleet — N members"), started when the operator opens Fleet / joins or creates, stopped on "Forget fleet" or when fleet is disabled in Settings.
  The service owns the 6970 socket + `MulticastLock`; killing the app ends beaconing honestly — a dead EUD stops advertising within 15 s via peer expiry, it never lingers as a ghost member. No WorkManager, no alarms.
- **Permission posture (v0.27.2, `ble_scan.dart`):** permissions up front, denial shows a Settings message, never a silent fail. Fleet needs NO new runtime permission (Wi-Fi multicast is not BLE and needs no location grant). The one adjacent case is the Android 13+ notification permission for the foreground-service notification: if denied, the service still runs — no blocking prompt.
- **Wi-Fi off:** Fleet screen shows "Wi-Fi off — fleet unavailable"; beaconing/listening stop; peers expire after 15 s. Re-enabling Wi-Fi resumes automatically (service rebinds the socket, same as `CotListener._socketDied` recovery).
- **Multicast blocked (AP isolation, guest network, VPN):** no beacons are ever heard, so no fleets list and no peers appear. After 15 s of listening with zero beacons the screen says "No fleet heard — this network may block device discovery (AP isolation)".
  Outride never claims a fleet exists that it cannot hear, and never falls back to a cloud relay or an IP scan (`discovery.dart` subnet scanning is for radios, not for fleet — out of scope).

## 9. Threat model (brief)

Adversary: anyone on the same Wi-Fi/LAN segment (the fleet's whole threat surface is the local segment; there is no internet path).

- **Beacon spoofing:** beacons are plaintext by design, so a fake fleet/member can be listed. Joining still needs the PIN + HMAC proof; a fake member with no fleet key cannot complete admission, and its `fleet_data` fails decrypt and is dropped. Worst case is a phantom fleet name on the screen.
- **PIN brute force (10,000 combos):** §5 rate limiting + lockout + global freeze makes it weeks of noisy attempts, visible to the operators. Offline brute force is impossible: the beacon carries no PIN verifier — the HMAC proof can only be checked live by a member holding the fleet key.
- **Fleet impersonation:** copying a heard `fleet_id` still needs the PIN to admit anyone, and the copy's members hold a different fleet key — the two fleets cannot decrypt each other's traffic. Operators see two fleets with the same short ID; the fix is operational (new fleet, new PIN), not cryptographic.
- **Traffic injection (forged `fleet_data` on 49160):** AES-256-GCM + AAD (`fleet_id`) per pairwise session key — a forged datagram fails authentication and is dropped before `parseUdpJson`. Injection can only cause a dropped datagram, never a false track — and the tripwire never takes a track from a peer alone (§6).
- **Eavesdropping:** beacons, yes (public values only: IDs, salt, role, count); peer sensor data, no (encrypted under pairwise session keys).
- **Replay:** beacons are idempotent upserts (harmless). `fleet_data` replays are dropped: random 12-byte GCM nonces, receivers drop any (nonce, sender) repeat within the session.

**Defensive-only:** sensing and fusion only. No jamming, no deauth, no transmit-to-disrupt, and no change to the RF sensing pipeline beyond ingesting peer data through the existing Sensor Protocol (§6).
Nothing here transmits except fleet beacons, admission messages, and our own sensor observations to admitted peers.

## 10. Test plan for the builder

Unit tests the spec expects (pure functions first — same pattern as `cot_listener.dart`'s socket-free `handleDatagram`/`checkCoincidence`):

1. KDF determinism: same PIN + salt ⇒ same 32-byte key, twice; different salt ⇒ different key; wrong PIN ⇒ different key. (Both Argon2id and the PBKDF2 fallback if both ship.)
2. PIN rate-limit behavior: 5 failures from one IP ⇒ lockout; backoff 30/60/120/300 s; global 10/min ⇒ 60 s freeze; a success resets the per-IP counter; lockout expiry re-admits.
3. Beacon parse/encode round-trip: `fleet_beacon` JSON ⇒ struct ⇒ JSON identical; malformed JSON / missing `fleet_id` / bad `t` / skew > 30 s ⇒ dropped, never throws.
4. Fleet persistence round-trip: store record ⇒ reload ⇒ same `fleet_id`/`salt`; secure-storage key survives reload; raw PIN absent from both stores (assert no 4-digit PIN string is persisted anywhere); "Forget fleet" deletes both stores.
5. Role labeling: `has_silvus` true ⇒ `SENSING`, false ⇒ `FUSION PEER`; toggling the beacon field flips the label; a sensing node that loses its radio flips within one interval.
6. Dedup/expiry: repeat beacons from one `node_id` ⇒ one peer; 15 s silence ⇒ peer `GONE` and removed; 64-peer cap drops the oldest, never crashes.
7. Envelope round-trip: `fleet_data` encrypt ⇒ decrypt ⇒ inner `sensor_obs` parses via `SensorProtocol.parseUdpJson`; tampered ciphertext / wrong `fleet_id` AAD / replayed nonce ⇒ dropped.
8. Dialer: 4 digits ⇒ auto-submit; 5th digit ignored; backspace clears one dot; non-digit input impossible.

**What must NOT be tested on synthetic data:** nothing here needs RF recordings. There is no RF sensing change in this feature — no link measurements, no tripwire thresholds, no detection claims — so no capture data, no walk/drive tests, and no synthetic RF scenarios are required or wanted.
Field validation is operational only: two real EUDs on one Wi-Fi network create, join, auto-rejoin after restart, and survive the lead's EUD leaving.

## Open questions for Draco

1. Should a fleet have a human-readable name (lead types one at creation) or is the short fleet ID enough on the Fleet screen?
2. Maximum fleet size to design for — fire team (~6) or a larger element (~20) — for the 64-peer cap and beacon traffic?
3. Should auto-rejoin also work when the EUD restarts on a different Wi-Fi network that happens to carry the same fleet, or only on the network where it joined?
