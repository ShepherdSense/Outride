# Dashboard & Provisioning Key Rules — FORWARD DESIGN RULES

**Status: design rules for a dashboard that does not exist yet. No code
changes, no vulnerability fix.**

Outride today has NO MeshMonitor-style public dashboard, and its LoRa
backhaul PSK never leaves the node/gateway status pages. Nothing in this
document describes a Outride vulnerability. These rules exist so that if
a Outride dashboard or API is ever built, it does not repeat the
key-disclosure failures found in another project's dashboard in May
2026. Any future dashboard implementation must satisfy all five rules
before it ships; a dashboard that cannot satisfy Rule 1 and Rule 2 does
not ship.

## Sources (and what each one actually is)

Two disclosures are often merged. They are NOT the same disclosure, and
this document keeps them separate:

- **MeshMonitor Security Advisory, May 2026 — read in full.** A
  web-dashboard API bug class: dashboard endpoints serialized raw key
  material (channel PSKs, device private keys, source credentials) to
  callers who should never have seen it. Eight findings (MM-SEC-1
  through MM-SEC-8), all fixed on main at advisory time, pending
  release. Rules 1, 2, and 4 below come from this advisory.
- **CVE-2025-52464 — description WIDELY REPORTED; GHSA text UNREAD.**
  A Meshtastic *firmware* issue: duplicated X25519 device identity
  keypairs shipped in firmware 2.5.0 to before 2.6.11, via cloned
  "golden image" flashing and low-entropy first-boot key generation.
  This is about **device identity keys, not channel PSKs**. Rule 3
  below comes from this disclosure. Do not cite it as a PSK
  disclosure.

## Rule 1 — Project key material OUT of every API response

Any future Outride dashboard or API serving channel information must
**project key material out** — never serialize a raw key row.

- The pattern is the MeshMonitor MM-SEC-2 fix: a shared
  `transformChannel` projection that **omits the PSK and exposes only a
  derived `pskSet: boolean`** (key present / key absent). The boolean
  is the only key-related field any channel endpoint may return.
- This applies to **every** endpoint shape, not just the obvious list
  endpoint: list, poll, detail, debug, and export endpoints alike.
  The advisory's MM-SEC-6/7 lesson is that the leaks came from the
  routes nobody audited — a debug pass-through (`SELECT * FROM
  channels` behind an unrelated permission) and a second router file
  the main fix missed. A new endpoint that returns channel rows must
  go through the same projection; there is no "internal-only" or
  "debug-only" exception, because debug endpoints are exactly what
  leaked.
- The same projection rule covers any other secret-shaped field
  (source credentials, tokens, private keys): strip by default, allow
  only an explicit boolean or redacted marker through. The advisory's
  MM-SEC-1/8 fixes used shared strip helpers (`stripSecretSettings`,
  `stripSourceSecrets`) rather than per-route hand edits, so a new
  route inherits the protection instead of needing to remember it.

## Rule 2 — Key endpoints are ADMIN-gated, not merely authenticated

Any endpoint that reads, rotates, or manages key material must require
**admin**, not just an authenticated session.

- The advisory's MM-SEC-5 lesson: a device security-keys endpoint
  returned the local node's PKI **private key** to any authenticated
  caller (`requireAuth()` only). The fix was `requireAdmin()`.
  "Logged in" is not a privilege level for key material.
- Scope note from the same advisory: a **device key is
  broader-scoped than a channel PSK** — it authenticates the device
  across every PKI interaction, while a PSK only protects one
  channel. Key endpoints must be gated at the level the broadest key
  they can return demands, and per-row authorization (this channel,
  this device) must be checked against the URL's `:id`, not a static
  permission for a different object (the advisory's MM-SEC-4 lesson:
  static `channel_0:write` gating let a user mutate *any* channel).

## Rule 3 — Provisioning: never pre-generate, clone, or early-generate keys

- **Never pre-generate or clone key material into a firmware image.**
  Outride's PSK model already follows this: per-deployment
  operator-set PSK, no compiled-in default, no golden image, no
  first-boot keygen. Any future provisioning flow must keep it that
  way — a key generated once and flashed into a batch is a batch-wide
  compromise, not a convenience.
- **Never generate on-device keys before entropy is established.**
  The CVE-2025-52464 failure mode was first-boot key generation on
  platforms whose randomness pool was not initialized (reported:
  NRF52 falling back to timestamp-derived randomness; builds that
  never seeded `random()` at all), producing low-entropy keys.
- **Directly relevant to Outride's roadmap:** if ML-KEM key
  generation ever moves onto the ESP32 itself (today the refresh runs
  over Wi-Fi with keys generated elsewhere), the ESP32 RNG seeding
  must be verified **before the first keygen** — same bug class as
  the 2012 Heninger low-entropy key studies. A keygen step that
  cannot prove its entropy source is ready must refuse to run, not
  generate anyway.

## Rule 4 — Incident response: if a PSK ever leaks, ROTATE — don't just patch

If any Outride surface ever did expose a PSK, patching the endpoint
is **not** the response. The response is **rotate the PSK**.

- Reason: a leaked PSK decrypts not only current traffic but
  **previously recorded traffic** (the advisory states this impact
  explicitly for channel PSKs). Closing the endpoint stops future
  reads; it does nothing about recordings already captured.
- Outride already has the rotation mechanism: key-ID +
  monotonic-counter rotation, dual-key window, gateway-pushed,
  fail-closed (see the LoRa key-refresh design). Incident response
  is: push a new key-ID, confirm the fleet has moved, retire the
  old key-ID. The endpoint patch is step two, not step one.
- The same logic applies to a leaked device key (Rule 2's scope
  note): rotation/revocation of the device identity, not just the
  endpoint fix.

## Rule 5 — Future MEASURE candidate (low priority, NOT a build item)

A gateway duplicate/low-entropy key scanner: flag two nodes
presenting the same public key, or a key that fails a basic entropy
check. This mirrors the detection pattern in MeshMonitor's own
security tooling (`keyIsLowEntropy`, `duplicateKeyDetected`, 24-hour
scan, with a documented benign exception for renumbered keys).

- Priority: **low, future measurement only.** It is listed here so
  the idea is recorded, not so it gets built now. Outride's
  per-deployment operator-set PSK model makes batch-cloned PSKs
  unlikely; the scanner's value would be against device identity
  keys if those ever exist on Outride nodes.
- If ever built, it must carry the same benign-exception discipline:
  a scanner that cannot explain its false positives will be ignored
  or disabled.

## What this document does NOT claim

- It does not claim Outride has, or had, any of the MeshMonitor
  findings. Outride has no such dashboard.
- It does not claim CVE-2025-52464 affects Outride's PSK. It does
  not — different key type, different failure.
- It does not authorize building a dashboard. It only constrains
  one, if one is ever built.

## See also

- LoRa key-refresh design (key-ID + monotonic-counter rotation,
  dual-key window, fail-closed) — the mechanism Rule 4 relies on.
- LoRa PSK codec design (per-deployment operator-set PSK, no
  compiled-in default) — the provisioning posture Rule 3 protects.
- Research lane notes: `~/memory/topics/outride_research/lane5_encryption.md`
  (2026-10-26 sweep update: MeshMonitor advisory + CVE-2025-52464
  split disclosure).
