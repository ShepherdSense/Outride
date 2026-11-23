/// Feed server — the ingest side of the experimental live web build.
///
/// The experimental native apps (Android + Windows) SERVE the live
/// feed the web app connects to. The mesh itself is untouched:
/// EUD nodes still mesh with each other over internal Wi-Fi
/// (multicast-beacon discovery + 4-digit PIN join, fleet key
/// underneath). The feed server lives ON one mesh node (or the hub)
/// and serves a web CLIENT; the web app never joins the mesh and is
/// never itself a mesh node — a browser cannot do multicast/UDP peer
/// discovery.
///
/// Transport: plain HTTP + WebSocket on port 49163 (dart:io only —
/// this file is the conditional export; the web build gets the stub).
/// No new dependencies. Experimental-branch only: the server is
/// started from AppState.start() only when [kIsExperimentalBuild]
/// is true and this is not the web build, and it never changes live
/// fleet behavior — it only broadcasts what the app already observes
/// and accepts record start/stop commands for the bench recorder.
///
/// Protocol (JSON):
///   Server → client, `GET /status`:
///     {"ok":true,"app_version":"0.29.7-experimental","mode":"live",
///      "recording":false,"clients":1}
///   Server → client, WS `/feed`:
///     {"type":"hello","app_version":"...","mode":"live",
///      "recording":false}
///     {"type":"snapshot","t":"...","app_version":"...",
///      "mode":"live","links":[{"link_key","from","to","snr_db",
///      "dip_db"}],"events":[{"t","link_key","size_estimate"}],
///      "nodes":N,"polling":true,"recording":false}
///     {"type":"record_result","id":N,"ok":true,"summary":"..."}
///     {"type":"record_status","recording":false,"rows":0,"path":""}
///   Client → server, WS `/feed`:
///     {"id":N,"cmd":"ping"}
///     {"id":N,"cmd":"record_start","template":"movingCrossings",
///      "label":"...","waypoint_a":[x,y],"waypoint_b":[x,y],
///      "baseline_s":10,"notes":"...","illuminator_band":""}
///     {"id":N,"cmd":"record_stop"}
///     {"id":N,"cmd":"record_status"}
library;

export 'feed_server_stub.dart' if (dart.library.io) 'feed_server_io.dart';
