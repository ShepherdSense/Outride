# Outride 0.29.7-experimental — branch-only notes

**EXPERIMENTAL BUILD — UNTESTED. Do not use for live operations.**

This directory exists only on the `experimental/bench-apps` branch. It is
never on main, and nothing here touches the v0.29.7 release, the public sim,
or any other project.

## What this build is

Outride v0.29.7 plus three experimental pieces, all gated behind the
experimental toggle and the EXPERIMENTAL identity (amber pill, Settings
panel, Bench header, version `0.29.7-experimental`):

1. **Bench area** (Sensors → Bench): 31 queued measurement benches with
   their source paper, pass bar, and run status. 15 IMPLEMENT harnesses run
   on recorded input; 16 QUEUED-BLOCKED rows name their blocker and what
   would unblock them. With no input every harness reports
   "measurement pending — no recorded data". No synthetic data anywhere.
2. **Field-session recording** (Bench screen → Record a session): records
   real link sessions in the BenchSession format the harnesses read
   (dip_db from a vacant-baseline window + operator-declared scripted
   truth), plus optional sections for CSI summaries, trip events, camera
   events, sweep frames, and backhaul. Files land in `bench_sessions/` in
   the app documents dir. There is no share sheet in the app — copy files
   out via USB/file manager.
3. **Live web build**: the same app compiled for web, with the simulated
   engine replaced by a live feed. The web app is a CLIENT: it connects to
   one mesh node (or hub) over the local network and views/controls/records
   through it. It never joins the mesh — meshing stays exactly as it is
   (EUD nodes mesh over internal Wi-Fi, multicast-beacon discovery +
   4-digit PIN join), and the web app just rides on top. If no feed source
   is reachable it says NO FEED SOURCE REACHABLE and shows nothing that
   looks like live data; simulated mode is a labeled toggle only, default
   OFF.

## The three deliverables

All three are attached to the same prerelease, tag
`experimental-2026-11-23` (no `v` prefix — a `v*` tag would trip the main
build-apps.yml release job and could displace v0.29.7 as Latest),
prerelease true, make_latest false:

| Asset | Launch |
|---|---|
| `Outride-0.29.7-experimental.apk` | Install on the EUD. Serves the live feed on port 49163 while it runs. |
| `Outride-0.29.7-experimental-windows.zip` | Extract and run the Windows app. Same feed server on port 49163. |
| `Outride-0.29.7-experimental-web.zip` | Extract, serve locally, open in a browser (see below). |

### Web build launch

```sh
unzip Outride-0.29.7-experimental-web.zip
cd build/web        # the zip contains build/web, not web
python -m http.server 8000
```

Then open http://localhost:8000 in a browser. In the Bench screen's live-feed
panel, enter the ingesting node's LAN address as `host:49163` (e.g.
`192.168.1.10:49163`) and connect. Record start/stop commands go through the
feed to that node; recorded files land on the node, not in the browser.

> **Port 49163 is unauthenticated and LAN-reachable:** anyone on the local
> network can read the live feed and send `record_start` / `record_stop`.
> Test use on a trusted network only.

## How to supply sessions

- **Record in the app:** Sensors → Bench → Record a session. Pick a
  template (empty baseline / moving crossings / move-in-then-stand-still),
  label, waypoints A/B in field metres, baseline window (vacant, default
  10 s). Keep the area clear during the baseline, then walk A → B for
  moving templates. Stop writes the session + `<session>.meta.json` +
  `<session>.nodes.json` sidecars.
- **Copy files in by hand:** RF-track CSVs into `bench_sessions/`
  (`t_iso,link_key,from_node,to_node,snr_db,dip_db,truth_x,truth_y,truth_id`
  + `<session>.nodes.json` sidecar); CSI CSVs into `csi_sessions/`
  (`t_iso,link_id,subcarrier,amp,phase` + `<session>.meta.json` sidecar).
  Malformed files are listed with a reason, never silently skipped.
- **What the app can and cannot record:** the apps record RF link sessions
  (B1/B4/B5/B7/B9/B10/B11/B14), backhaul gap summaries (B3/B6/B15 context),
  CSI aggregate summaries (not per-subcarrier CSI — the Sensor Protocol
  UDP 49160 path carries only 1 s aggregated motion observations, so
  B7/B12/B-W benches need externally recorded CSI CSVs), SDR sweep peaks
  (B13/B19 context — band energy, not IQ/range–Doppler), trip events
  (B17), and camera motion events + snapshot refs (B18 — no detector
  boxes exist in the app). Silvus sessions (B8/B16) and SX1262 backhaul
  (B2) need hardware that is not in hand yet.

## What is NOT verified

- **Not verified on-device/EUD.** The APK Gradle build could not run in
  the build sandbox (Gradle daemon IPC dead end — see the CHANGELOG entry);
  the GitHub workflow must exercise the real APK build.
- **Not verified in a real browser.** The web build was built, served
  locally, and curl-checked, and the feed handshake was exercised with a
  scripted WebSocket client — but no live-browser check has happened (open
  the built web app in a real browser, connect to a real feed source,
  confirm live data renders). That check is still outstanding.
- **No bench has passed on real data yet.** Every harness reports pending
  until Draco supplies recorded field sessions.

## Building

The workflow `.github/workflows/build-experimental.yml` (workflow_dispatch
only) runs `flutter test`, `flutter analyze`, `flutter build apk --debug`,
`flutter build windows --release`, and `flutter build web --release`, then
creates the prerelease. Locally, the same commands work except the APK
Gradle build in this sandbox (see above); `flutter build web --release`
and `flutter test` run clean here.
