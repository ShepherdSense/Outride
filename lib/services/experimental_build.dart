/// Experimental-build identity (branch-only).
///
/// This whole tree IS the experimental branch: the constant below is a
/// build-time marker, never a setting, never toggleable. The live
/// v0.29.7 tree does not contain this file's `true` value — it is
/// introduced here so the pill, the Settings panel, the Bench header,
/// the web simulated-mode default, and the feed server all agree on
/// which build they are in, from one place.
library;

/// True in this (experimental) tree; false/absent on main.
const bool kIsExperimentalBuild = true;

/// Full experimental version string, carried at every version surface.
const String kExperimentalVersion = '0.29.7-experimental';

/// The live release this build is cut from.
const String kExperimentalBaseVersion = '0.29.7';
