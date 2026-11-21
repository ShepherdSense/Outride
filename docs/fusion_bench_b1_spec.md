# B1 Fusion Bench — CI vs ICI vs Naive, Feature-Aided Association, ICI Handover Smoothing

**Status: EXPERIMENTAL — benches built; measurement pending recorded data.**

Code: `lib/services/fusion_bench.dart`, `lib/services/fusion_bench_association.dart`,
`lib/services/fusion_bench_harness.dart`.
Tests: `test/fusion_bench_test.dart`, `test/fusion_bench_association_test.dart`,
`test/fusion_bench_harness_test.dart`.

## What this bench is

The queued B1 bench (see `~/workspace/goals/silvus-rf-sensing-app/hidden_files/bench-queue-2026-11-06.md`):
**covariance-intersection (CI) vs inverse-covariance-intersection (ICI) vs naive
information-form fusion**, over a recorded Outride link session. The Nov 21
research sweep added two arms:

1. **Feature-aided association** (Tao et al., *Appl. Sci.* 2026, 16, 3159, full read)
   — kinematics (Mahalanobis) vs kinematics + one cheap feature vs kinematics + two.
2. **ICI handover smoothing + CATS-style association** (Tian et al., *Sensors* 2026,
   26, 4251, full read) — smoothing/MAE measured separately from association
   accuracy; bidirectional trajectory-similarity matching in the overlap zone as an
   alternative to Mahalanobis-only matching of corroborator tracks to RF tracks.

## Data rule (binding)

**The bench measurement runs ONLY on recorded Outride track sessions.** As of
v0.29.6, no recorded sessions exist in the workspace — verified by search: the
only capture files are Kraken/BEAST zips (different systems), an empty
`shepherd_capture_log_nov2-4.md` template, and Stone Soup stand-in CSVs that are
explicitly synthetic. `runFusionBench` SKIPS (never fails, never passes on
synthetic data) when no recorded session is found and reports
`measurement pending — no recorded data`.

- Session directory: `<repo>/bench_sessions/` (does not exist yet).
- Session format (CSV, per poll, one row per disturbed link):
  `t_iso,link_key,from_node,to_node,snr_db,dip_db,truth_x,truth_y,truth_id`.
  Recorder-format files (`lib/services/recorder.dart` output, no `dip_db` /
  truth columns) are REJECTED with a reason, never scored.
- Unit tests use small hand-constructed fixtures to verify MECHANICS ONLY
  (code runs, scores compute, gates behave). **Fixture numbers are never bench
  results.** Do not generate synthetic sessions; do not run the bench on
  synthetic data without Draco's explicit word.
- Paper numbers are NOT expected Outride gains. Do not cite Tao's 37–54% OSPA
  improvement or Tian's 98.4% / 0.23 m figures as Outride expectations — both
  papers measure different systems (LMB radar tracking; highway
  radar+camera trajectory tracking) and their transfer is unproven until measured.
- Rows with fewer fields than the header are rejected as malformed
  (`FormatException`) — the file is listed in `rejected`, never scored, and
  never crashes the run.

## Base arms

- **CI**: trace-optimal omega on a 0.01 grid, SPD check + diagonal
  regularization (jitter escalates 1e-9 → 1e-3).
- **ICI**: recursive form (Tian eq. 6), omega by minimizing tr(P_f);
  candidates whose information matrix is not SPD are skipped (Tian's
  SPD check). Endpoint guarantee: at omega=0 the ICI information matrix
  is exactly Y_a and at omega=1 exactly Y_b, both SPD, so the closed
  0..1 grid always contains an SPD candidate — ICI never falls back
  and always returns a numeric omega. (An earlier draft counted
  ICI-SPD fallbacks; that branch was dead code and was removed in
  review.)
- **Naive**: information-form sum — the overconfident reference that shows
  what double-counting costs.
- **Consensus scheme**: L rounds of pairwise fusion with a doubly-stochastic
  weight matrix; iteration count per the L-rule
  `L >= max(mesh diameter, ln(N-1) / ln(1/lambda))`, where lambda is the
  second-largest eigenvalue of the weight matrix. Note the driver
  double-counts each node's own information per round (its estimate
  enters both directly and inside the weight-matrix aggregate, which
  includes the self-weight) and runs on row-renormalized active subsets
  that are no longer doubly-stochastic, while the L-rule's lambda2 was
  computed on the full mesh. All arms share the driver, so relative
  comparisons hold — but iteration counts are not directly
  Yang-comparable.
- **Weight variant**: Metropolis weights vs centrality-weighted
  (symmetric sqrt-degree, Sinkhorn-Knopp to doubly-stochastic) — a bench
  variant, not a default.

## Local estimates (bench-side, NOT the app tracker)

The app tracker (`lib/services/tracker.dart`) is a covariance-free grid
search and keeps no state covariance, so the bench carries its own
`(mean, covariance)` estimate type (`Gaussian2`). Per poll, per node, the
bench local estimator takes the dip-weighted centroid of disturbed-link
midpoints (disturbed = dip above `dipThresholdDb`), covariance
`sigma0^2 / nLinks` plus motion growth, CV smoothing. **It is not a Kalman
filter** — a Kalman (or equivalent) is a future refinement, not part of
this build. All arms share the same local estimates, so estimator bias
cancels in relative comparisons.

## Association arms (Tao)

Features, all Outride analogs — dip depth / link-shadow magnitude,
speed/heading consistency, per-node RSSI-drop signature:

- `kinematics` — Mahalanobis distance only (gate: chi-square 2-dof 95% =
  9.21).
- `plusDip` — kinematics + dip-depth mismatch.
- `plusDipAndMotion` — + speed/heading consistency.
- `plusDipMotionAndSignature` — + drop-signature cosine similarity.

Same Hungarian + gating structure for every feature set; thresholds are
Outride-tuned (`AssociationParams`), **NOT** the paper's numbers.
**Association features NEVER create a detection** — the upgrade-only gate
is intact: the RF track stays detection authority; ICI refines only, never
originates or deletes tracks. Association here matches *corroborator*
tracks to RF tracks; it does not decide that a track exists.

**Truth-id scoring:** each corroborator tracklet inherits the truth id(s)
of its own disturbed links (a single id, or unattributed when the links
are mixed or unattributed), and the RF track takes the truth id of the
target its fused estimate is nearest. An identity switch counts only when
the matched tracklet's truth id changes between consecutive polls; a
false track counts only a match to a tracklet carrying a different truth
id than the RF track's. Both are zero by construction in single-target
sessions and measurable only in multi-target sessions — they are never
faked on single-target data. (A node-id change is NOT a switch: in a
single-target session every corroborator is the same target, so a node
change is a coverage handover.)

**Do NOT port from Tao:** the LMB filter, the GCI fusion step, equal
weights, Radar-1-as-reference, or the paper's numeric thresholds (0.85 /
10^-3). The OSPA win in the paper is cardinality only; no NEES is
reported there — the bench scores NEES itself.

## Handover arm (Tian)

- Fragmentation at handover counts two ways: a fused-position jump beyond
  `handoverJumpSigma` fused sigmas at a handover poll — only when the gap
  to the previous fused poll is under 10 s (the `dt < 10 s` guard: a jump
  after a longer silence is a stale-track re-acquisition, not a handover
  break); and a gap of `handoverMissedPolls` or more consecutive polls
  with no fused estimate following a handover that occurred since the last
  poll that produced a fused estimate (counted once per gap).
- Smoothing (position MAE / NEES of the fused track) is scored separately
  from association accuracy (identity switches, cardinality error,
  false-track rate).
- CATS-style matching: bidirectional trajectory similarity — a pair
  matches only when each side is the other's best (threshold 0.5, 0.5/0.5
  spatial/temporal split, the bench's own weighting).

**Do NOT port from Tian:** Deep-SORT / OTTC vision machinery, GMCSC
road-geometry calibration, or the 98.4% / 0.23 m figures as Outride
expectations. The paper's contribution carried over is the *pattern*:
bidirectional trajectory similarity in the overlap zone, and ICI handover
smoothing as a separately-measured quantity.

## Scores and pass bars (verdict thresholds)

| Arm | Pass bar |
| --- | --- |
| Base B1 | ICI RMSE < CI RMSE **and** mean NEES inside 95% bounds |
| Feature-aided association | ≥20% fewer identity switches + cardinality error vs kinematics-only, **no false-track increase**, <5 ms added latency per association step on EUD hardware |
| ICI handover | ≥20% fewer fragmentations / ID-switches at coverage handover vs CI, NEES inside 95% bounds |

NEES bounds: mean of n NEES values ~ chi-square(2n)/n; 95% interval via
Wilson–Hilferty (2-dof per sample). Note the consistent value is a mean
NEES of 2, not 1 — NEES per sample is chi-square with 2 degrees of
freedom.

**Not-applicable verdicts:** a relative bar is NOT EVALUABLE when its
baseline is zero, and reports N/A instead of a vacuous PASS. The handover
bar is N/A when CI has 0 fragmentations or there are no handover polls;
the feature bars are N/A when the kinematics baseline has 0
switches+cardinality error. An N/A verdict is neither a pass nor a fail
and is excluded from the overall verdict (which still requires at least
one applicable verdict). The base B1 bars have no N/A case: NaN RMSE and
empty-NEES both fail.

## What is NOT built here

- Șorecău et al. sweep jamming (threat watch, awareness only — no code,
  no countermeasure).
- Tumanyan et al. SDR LoRa — REJECTED as a build.
