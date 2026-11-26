# GL.iNet Router Support (EXPERIMENTAL)

> **Status: EXPERIMENTAL — unverified on hardware.** No GL.iNet router was in
> hand while this was built. The implementation is verified against the
> GL.iNet SDK 4.0 API guide, the gli4py reference library
> (`~/workspace/tools/gli4py`), its mock fixtures, and golden crypt vectors
> from Python's `crypt` module — but it has never talked to a real router.
> Treat the first live login as a bench test, not a shipped feature.

## What it is

A read-only client for GL.iNet travel routers running **firmware 4.x**
(GL-MT3000, GL-AXT1800, GL-B1300, and similar), for the Radios & Networks
screen: show the router's model/firmware, WAN/Wi-Fi state, load, and the
list of connected clients — the LAN the Outride mesh is sitting on.

- Service: `lib/services/glinet_router.dart` (`GlinetRouter`)
- Crypto: `lib/services/glinet_crypt.dart` (pure-Dart Unix crypt)
- Tests: `test/glinet_router_test.dart`, `test/glinet_crypt_test.dart`
  (51 tests, all passing)

## API surface

```dart
final router = GlinetRouter(); // default http://192.168.8.1/rpc
final probe = await router.probe();
if (!probe.isGlinet4x) { /* not a 4.x router — say so, don't guess */ }
await router.login(username: 'root', password: password);
final info = await router.routerInfo();     // system.get_info
final status = await router.routerStatus(); // system.get_status
final load = await router.routerLoad();     // system.get_load
final clients = await router.listClients(); // clients.get_list
await router.logout();
```

| Method | Returns | Notes |
| --- | --- | --- |
| `probe({username})` | `GlinetProbeResult` | Unauthenticated challenge call. **Never throws** — unreachable / wrong-shape answers come back as `reachable: false` with a human-readable `error`. |
| `login({username, password})` | `void` | Challenge → cipher → hash → `login`. Keeps the SID in memory only. |
| `routerInfo()` | `GlinetRouterInfo` | Model, firmware version/date/type, MAC, serial, vendor, board model, OpenWrt version, CPU count. Throws `GlinetFirmwareTooOldException` below 4.0. |
| `routerStatus()` | `GlinetRouterStatus` | Networks (WAN/WWAN/tethering, online/up), Wi-Fi radios (SSID, band, channel, up, guest), services, client counts, uptime, memory, load average, mode. |
| `routerLoad()` | `GlinetRouterLoad` | Memory total/free/buff-cache, 1/5/15 min load averages. |
| `listClients()` | `List<GlinetClient>` | MAC, IP, name, alias, online, interface (`cable`/`2.4G`/`5G`), blocked, online time, tx/rx counters, vendor, class. |
| `logout()` | `void` | Best-effort; always clears the local SID. |

`GlinetRouter({Uri? rpcUri, http.Client? httpClient, GlinetPost? post, Duration timeout})` —
pass `post` (or an `http.Client`) in tests to inject a fake transport; the
default posts to the router over plain HTTP with a 10 s timeout.

All models parse **leniently**: a missing or oddly-typed field degrades to
`null` / empty / a default — a well-formed response never throws from
parsing. The one hard requirement is a firmware version in `get_info`,
because 4.x-ness cannot be verified without it.

## Auth flow

Transport is HTTP POST to `{router}/rpc`, JSON-RPC 2.0,
`Content-Type: application/json`, `{"jsonrpc": "2.0", "method": ..., "params": ..., "id": N}`.

1. **Challenge** — `method: "challenge"`, params `{"username": "<user>"}` →
   `result: {"alg": <int>, "salt": "<str>", "nonce": "<str>",
   "hash-method": "<str>"}`. `alg` 1 = MD5-crypt, 5 = SHA-256-crypt,
   6 = SHA-512-crypt; `hash-method` defaults to `md5` when absent.
2. **Cipher password** — `unix_crypt(password, "$<alg>$<salt>$")`, implemented
   in pure Dart in `glinet_crypt.dart` from Drepper's public-domain
   MD5-crypt / SHA-crypt specification (digests from the `crypto` package,
   already a dependency — no new dependencies). Verified byte-for-byte
   against Python's `crypt` module for all three variants, including
   `rounds=N`, empty/long passwords, and over-long salts.
3. **Login hash** — `H("<username>:<cipher_password>:<nonce>")`, hex-encoded,
   where `H` is md5 / sha256 / sha512 per the challenge's `hash-method`.
4. **Login** — `method: "login"`, params `{"username", "hash"}` →
   `result: {"sid": "<session>"}`. The SID is valid ~5 minutes, refreshes
   on use, and lives **in memory only**.
5. **Calls** — `method: "call"`, params `[sid, module, function, ...extra]`.

## Read-only — and why

This service implements **only** the four read calls above. It deliberately
has no reboot, no port-forward write, no Wi-Fi config change, no client
block, no LED/VPN/tailscale control — even though the router API offers
them and gli4py wraps them. Outride is defensive-only: it observes the
network it operates on, it never reconfigures someone else's router.
Any future write capability needs its own explicit decision, its own
review, and its own user confirmation — it does not belong in this service
by accretion.

## Errors

Typed exceptions, all with human-readable messages safe to show:

| Exception | Meaning |
| --- | --- |
| `GlinetUnreachableException` | Connection refused / DNS / timeout. |
| `GlinetNotRouterException` | Something answered, but it is not a GL.iNet firmware 4.x router (non-JSON answer, missing `result`, or a challenge that is not a 4.x challenge / names an unsupported cipher). |
| `GlinetFirmwareTooOldException` | A GL.iNet answered but reports firmware older than 4.0 (pre-4.0 uses a different REST API). |
| `GlinetAuthException` | Wrong username/password (`-32000`), no session, or an expired SID (`-1`, which also clears the local session). |
| `GlinetLockoutException` | Too many failed logins (`-32003`) — wait a few minutes. |
| `GlinetApiException` | Anything else: HTTP 5xx, internal error (`-32603`), method not found (`-32601`), unknown RPC code (carries `code`). |

Error codes follow gli4py's `error_handling.py` RPC error map. `probe()`
is the only method that never throws.

## Security notes

- The password is **never persisted and never logged**. It is used only to
  compute the cipher password and login hash inside `login()` and is then
  dropped. Only the hash derivatives cross the wire.
- The SID is **never logged** and never written to storage.
- The router's default RPC endpoint is **plain HTTP on the LAN** — the API
  has no TLS option there. Use it only on a trusted local network.
- The router also returns each Wi-Fi radio's password (`passwd`) in
  `get_status`; this client **never parses or stores it** (same redaction
  gli4py does).
- No synthetic or sample data is ever presented as measurement: `probe()`
  reports reachability honestly, and the models carry only what the router
  actually returned.

## What is unverified on hardware

- **Everything live.** No GL.iNet hardware was available: no real
  `challenge`/`login` round-trip, no real `get_info`/`get_status`/
  `get_load`/`get_list` response, no SID lifetime observed, no lockout
  observed, no firmware-version edge cases (e.g. 4.8+ response changes).
- **The `logout` call shape.** The gli4py mock server takes
  `logout` with params `{"sid": ...}`; that is what this client sends.
  The call is best-effort (the local SID is cleared regardless), so a
  shape mismatch here is harmless — the SID expires server-side anyway.
- **Field variance across models/firmwares.** Parsing is lenient by
  design, but a model that reports e.g. `load_average` as strings or
  omits `client` entirely has only been exercised with synthetic variants
  in the tests, not with real firmware.
- **Timeouts on slow routers.** 10 s per call is a guess; tune from live
  behaviour if a router answers slowly.

## Verification performed

- `flutter test test/glinet_crypt_test.dart test/glinet_router_test.dart` —
  **51 tests, all passing.** Crypt vectors are golden values from Python's
  `crypt` module (glibc); router fixtures are the gli4py mock fixtures
  (`system_info.json`, `system_status.json`, `system_load.json`,
  `clients.json`) — library fixtures, clearly labelled in the test file,
  not live data.
- `flutter analyze` clean on all four files.
- No new pub dependencies; no v0.30.0 content; dark theme untouched.

## RPC methods implemented (exact list)

`challenge`, `login`, `logout`, and `call` with
`system.get_info`, `system.get_status`, `system.get_load`,
`clients.get_list`. Nothing else.
