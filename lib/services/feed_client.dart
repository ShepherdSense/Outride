/// Feed client — the web build's connection to one mesh node (or
/// the hub) as a CLIENT.
///
/// The web app never joins the mesh and is never a mesh node: it
/// connects to ONE node's feed server (see feed_server.dart) over
/// WebSocket and views/controls/records through it. The mesh works
/// unchanged underneath; the web app just rides on top of it.
///
/// Connection states are explicit and honest:
/// - disconnected: never connected (or disconnected by the user).
/// - connecting: a connect is in flight.
/// - connected: live snapshots are flowing.
/// - unreachable: the connect failed or the socket dropped, with a
///   plain-language reason in [lastError]. NOTHING that looks like
///   live data is shown in this state, and the app NEVER falls back
///   to simulated data silently — simulated mode is a labeled,
///   explicit toggle only, default OFF (live).
///
/// Record commands go through the feed connection to the ingesting
/// device; recorded files land ON THAT DEVICE (export from there per
/// the recording brief) — the browser never holds the recording.
library;

export 'feed_client_stub.dart' if (dart.library.io) 'feed_client_io.dart' if (dart.library.html) 'feed_client_web.dart';
