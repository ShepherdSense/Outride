/// Default-LIVE resolution (v0.29.7): fresh installs on real apps open
/// LIVE at full capability; the public web sim always runs simulated.
///
/// The problem: fresh downloads of the APK / Windows app opened in
/// simulated mode because the AppSettings constructor defaulted
/// `simulatedMode` to true and CI built plain release with no override,
/// so the top bar read SIMULATED and every feed was synthetic demo
/// data. There is no literal "DEMO" text in the UI — SIMULATED is what
/// people saw.
///
/// The fix, in one place so it stays testable:
///   - a fresh install on a real app (Android/Windows) defaults to
///     LIVE: [kSimulatedModeFreshDefault] is false;
///   - the web sim always runs simulated (it has no radios): [isWeb]
///     true forces simulated regardless of any stored value;
///   - an existing install's stored operator choice wins on non-web.
///
/// Pure Dart — no Flutter widgets — so it stays unit-testable. The
/// [isWeb] parameter is the testable seam for the web force: kIsWeb is
/// a compile-time constant, so production passes it in and tests drive
/// the parameter directly (the same DI pattern as the Cloudflare probe
/// override in AppState).
library simulated_mode;

/// Fresh-install default on real apps: LIVE (false). The sim feed only
/// starts when the operator turns simulated mode on in Settings, or
/// when the web force below applies.
const bool kSimulatedModeFreshDefault = false;

/// Resolve the effective simulated mode at startup.
///
/// - [isWeb] true (the public web sim) → always true: the sim has no
///   radios and must never open LIVE, whatever is stored or defaulted.
/// - [isExperimentalBuild] true → the web force does NOT apply: the
///   experimental web build is a live-feed client (default LIVE, feed
///   from a mesh node), and simulated mode is an explicit labeled
///   toggle only. The public sim stays locked to simulated.
/// - Otherwise a stored operator choice ([stored]) wins when present.
/// - Otherwise the fresh-install default: LIVE ([kSimulatedModeFreshDefault]).
bool resolveSimulatedMode({
  bool? stored,
  required bool isWeb,
  bool isExperimentalBuild = false,
}) {
  if (isWeb && !isExperimentalBuild) return true;
  return stored ?? kSimulatedModeFreshDefault;
}
