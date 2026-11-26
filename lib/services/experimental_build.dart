/// Experimental-build identity.
///
/// This is the live-release tree: the constant below is a build-time
/// marker, never a setting, never toggleable. It is `false` here — the
/// experimental branch carries the same file with `true`, so the pill,
/// the Settings panel, the Bench header, the web simulated-mode
/// default, and the feed server all agree on which build they are in,
/// from one place.
///
/// The file arrived on main with the Settings-overflow fix (c6b0b16),
/// whose Settings panel already imported it; main never had the file,
/// so the import was dangling until this file landed.
library;

/// True on the experimental branch; false here (live release).
const bool kIsExperimentalBuild = false;

/// Full version string, carried at every version surface. On main this
/// is the live release version; on the experimental branch it is the
/// `-experimental` string.
const String kExperimentalVersion = '0.30.0';

/// The live release this build is cut from. On main, the same as
/// [kExperimentalVersion].
const String kExperimentalBaseVersion = '0.30.0';
