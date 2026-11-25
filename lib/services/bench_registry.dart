/// Bench registry — the single source of truth for the Bench screen.
///
/// One entry per verdict unit (31: 27 items + B20; B5 judged as 5
/// separate arms). The Bench screen renders FROM this registry; no
/// bench metadata is hard-coded in the screen widget.
///
/// Counts: 16 IMPLEMENT / 15 QUEUED-BLOCKED. IMPLEMENT = B1, B4, B7,
/// B9, B10, B11, B12, B14, B20, B-W1, B-W2, B-W3/RuView, B-W4
/// (13 items) + B5 arms sequential-pairwise CI, fading SCI,
/// per-link variance (3 arms). QUEUED-BLOCKED = B2, B3, B6, B8, B13,
/// B15, B16, B17, B18, B19, B-W5, B-W6, B-W7 (13 items) + B5 arms SDP
/// family-optimal CI and Split CI (2 arms). B5.2 Split CI was demoted
/// 2026-11-23 (review fix): its Jaccard shared-dip fraction is a
/// heuristic proxy, not an honest derivation of the P_I/P_D split —
/// the estimator's covariance is isotropic and never built from dip
/// weights. The ultra-lightweight HAR bench (item #9 family) was
/// REMOVED 2026-11-25 (sweep verdict REJECT: training-only repo, no
/// deployment artifacts; an independent baseline appendix measured
/// it as TFLite Micro on classic ESP32 at 204.5 ms avg latency,
/// 315–340 KB model, ~608–645 KB firmware — fails the <100 KB flash
/// / <50 KB RAM / <50 ms node bar on all three axes; do not spend a
/// bench slot re-measuring). B20 added 2026-11-25 (energy-crossover
/// protocol).
///
/// Sources are the short citations from the bench queue
/// (bench-queue-2026-11-06.md) and the dual-WiFi note — the paper is
/// the spec even when the bench cannot run. Pass bars are verbatim
/// from the design doc §1.1; never paraphrased down to a slogan.
library;

/// IMPLEMENT: a harness exists and a Run button is rendered.
/// QUEUED-BLOCKED: no harness; the blocker + unblock line are shown.
enum BenchVerdictKind { implement, queuedBlocked }

/// Which input a harness reads. Drives the Sensors-row pill
/// (`N of M READY`) and the input summary line.
enum BenchInputKind {
  /// RF-track sessions in bench_sessions/ (BenchSession CSV).
  rfTracks,

  /// CSI sessions in csi_sessions/ (bench_csi.dart schema).
  csi,

  /// Energy sessions in energy_sessions/ (bench_energy.dart schema).
  energy,

  /// Both RF-track and CSI sessions.
  rfAndCsi,
}

/// One verdict unit in the registry.
class BenchEntry {
  const BenchEntry({
    required this.id,
    required this.title,
    required this.source,
    required this.passBar,
    required this.kind,
    this.harness,
    this.group,
    this.blocker = '',
    this.unblock = '',
    this.caveat = '',
    this.input = BenchInputKind.rfTracks,
  });

  /// e.g. `B1`, `B5.2`, `B-W3`.
  final String id;

  /// Short title.
  final String title;

  /// Full short citation, e.g. `Yang et al., Drones 2026, 10, 107`.
  final String source;

  /// The verbatim short pass bar from design §1.1.
  final String passBar;

  final BenchVerdictKind kind;

  /// Harness key the Bench screen dispatches on (see [BenchHarness]),
  /// or null when no harness exists.
  final String? harness;

  /// Group header for B5 arms (`B5 — CI bench arms`); null otherwise.
  final String? group;

  /// Exact blocker text (QUEUED-BLOCKED only).
  final String blocker;

  /// One-sentence WHAT WOULD UNBLOCK THIS line (QUEUED only).
  final String unblock;

  /// Caveat shown on the row (e.g. phase-weakness, wall-clock note).
  final String caveat;

  final BenchInputKind input;
}

/// Harness keys. B1's harness is the existing fusion bench
/// (fusion_bench*.dart, built v0.29.6) — surfaced here, not rewritten.
abstract class BenchHarness {
  static const String b1 = 'b1';
  static const String b4 = 'b4';
  static const String b5 = 'b5';
  static const String b7 = 'b7';
  static const String b9 = 'b9';
  static const String b10 = 'b10';
  static const String b11 = 'b11';
  static const String b12 = 'b12';
  static const String b14 = 'b14';
  static const String b20 = 'b20';
  static const String bw1 = 'bw1';
  static const String bw2 = 'bw2';
  static const String bw3 = 'bw3';
  static const String bw4 = 'bw4';
}

/// All 31 verdict units, in bench order. B5 arms carry group
/// `B5 — CI bench arms` so the screen reads 27 items with B5
/// expanded, not 31 flat rows.
const List<BenchEntry> benchRegistry = [
  BenchEntry(
    id: 'B1',
    title: 'ICI-vs-CI fusion bench',
    source: 'Yang et al., Drones 2026, 10, 107; Tao et al., Appl. Sci. '
        '2026, 16, 3159; Tian et al., Sensors 2026, 26, 4251; '
        'Rønning et al., arXiv:2609.25900; Forsling et al., IEEE TAES 2025',
    passBar: 'ICI RMSE < CI RMSE, NEES in 95% bounds; assoc. ≥20% fewer '
        'ID-switches, <5 ms; handover ≥20% fewer fragmentations; '
        'refinements: median NEES / k_pair inflation, Gaussian log score, '
        'λ_min/λ_max of NEES (offline MC) and NIS (online) matrices',
    kind: BenchVerdictKind.implement,
    harness: BenchHarness.b1,
    caveat: 'Paper\'s 684 m absolute RMSE is a 120-km bearing-only '
        'artifact — only relative ordering transfers.',
  ),
  BenchEntry(
    id: 'B2',
    title: 'Backhaul v2 bench (LR-FHSS sizing)',
    source: 'Sanchez-Vital et al., Sensors 2026, 26(21), 6843',
    passBar: 'DR5 vs DR6 vs LoRa SF7/SF10, 22-byte, ground gateway',
    kind: BenchVerdictKind.queuedBlocked,
    blocker: 'No SX1262 hardware in hand (XIAO/Wio-SX1262 kit delayed); '
        'ABP-vs-OTAA decision still open; no LR-FHSS gateway named.',
    unblock: 'SX1262 hardware in hand + ABP-vs-OTAA call + a named '
        'LR-FHSS gateway.',
  ),
  BenchEntry(
    id: 'B3',
    title: 'Gateway-side link-health scorer',
    source: 'Pourghasem et al., Future Internet 2026, 18(1), 38',
    passBar: '≥80% jammed-window detection, ≤1 false alarm / 8 h vs clean '
        'baseline',
    kind: BenchVerdictKind.queuedBlocked,
    blocker: 'No Outride backhaul logs in workspace; no jammer bench set '
        'up; no backhaul-log reader/recorder exists in-app.',
    unblock: 'Backhaul logs from a field deployment + a jammer bench '
        'setup.',
  ),
  BenchEntry(
    id: 'B4',
    title: 'Bounded-replay bench (async corroborator handling)',
    source: 'Tsai et al., IEEE Access 2026, 14, 117754–117774',
    passBar: 'Late-evidence handling removes timing bias, no deadline '
        'misses',
    kind: BenchVerdictKind.implement,
    harness: BenchHarness.b4,
    caveat: 'Deadline numbers are wall-clock phone measurements on '
        'replay, not the paper\'s 200 Hz MCU budgets.',
  ),
  BenchEntry(
    id: 'B5.1',
    title: 'SDP family-optimal CI (reference CI arm)',
    source: 'Pedroso et al., arXiv:2603.20402v2',
    passBar: '"Best possible CI" ceiling vs ICI',
    kind: BenchVerdictKind.queuedBlocked,
    group: 'B5 — CI bench arms',
    blocker: 'Needs an SDP solver; none exists in Dart/app, and the paper '
        'is theory-only with no simulations, numbers, or reference '
        'implementation.',
    unblock: 'A Dart SDP solver, or an offline SDP reference run whose '
        'output can be compared as a CSV.',
  ),
  BenchEntry(
    id: 'B5.2',
    title: 'Split CI arm',
    source: 'Pedroso et al., arXiv:2603.20402v2 (Thm 4); ION GNSS+ 2026 '
        'companion (abstract-only, UNREAD — not cited as findings)',
    passBar: 'Split-CI fusion vs CI/ICI on recorded tracks, NEES in bounds',
    kind: BenchVerdictKind.queuedBlocked,
    group: 'B5 — CI bench arms',
    blocker: 'P_I/P_D split cannot be derived from the estimator\'s '
        'covariance — locals are isotropic σ0²/n + (0.3dt)² with no '
        'per-link covariance component. The Jaccard shared-dip fraction '
        'is a heuristic proxy for the split, not an honest derivation: '
        'it decomposes centroid dip weights and applies that fraction '
        'to a covariance never built that way, and the sequential fold '
        'is exact only for 2 nodes.',
    unblock: 'Rebuilding the local estimator covariance from per-link '
        'contributions so a P_I/P_D split can be derived honestly — a '
        'redesign, not a harness fix.',
    caveat: 'Demoted from IMPLEMENT 2026-11-23 (independent review): '
        'the shared-dip fraction survives in bench_ci_arms.dart only '
        'as a marked unused heuristic, wired to no row.',
  ),
  BenchEntry(
    id: 'B5.3',
    title: 'Concurrent-vs-sequential CI arm',
    source: 'Pedroso et al., arXiv:2603.20402v2; Tu et al., '
        'arXiv:2508.12207v3',
    passBar: 'Sequential-pairwise CI as (expected-worse) control vs '
        'one-step CI',
    kind: BenchVerdictKind.implement,
    harness: BenchHarness.b5,
    group: 'B5 — CI bench arms',
  ),
  BenchEntry(
    id: 'B5.4',
    title: 'Fading SCI arm',
    source: 'Xie/Tu et al., Drones 2026, 10(9), 683',
    passBar: 'Median ANEES/NEES in [0.5, 2], RMSE ≤1.26× EKF, '
        '|log₁₀ ANEES| ≥0.4 orders better than EKF',
    kind: BenchVerdictKind.implement,
    harness: BenchHarness.b5,
    group: 'B5 — CI bench arms',
    caveat: 'No EKF exists in-app; the bar is applied against the '
        'CI arm as the reference and says so in the result. Paper τ '
        'and RMSE figures are NOT ported.',
  ),
  BenchEntry(
    id: 'B5.5',
    title: 'Per-link variance interface arm',
    source: 'Xie/Tu et al., Drones 2026, 10(9), 683',
    passBar: 'Reported variance tracks realised error (ρcov ≤ ~3, '
        'median ~1.3), ANEES in-band',
    kind: BenchVerdictKind.implement,
    harness: BenchHarness.b5,
    group: 'B5 — CI bench arms',
  ),
  BenchEntry(
    id: 'B6',
    title: 'Collaborative-jamming defense bench (Arms A/B/C)',
    source: 'Haque & Saifullah, Proc. ACM MobiHoc \'25, pp. 51–60; '
        'Haque & Saifullah, Proc. EWSN \'26, pp. 107–117 (MJRLoRa); '
        'Dossa et al., IEEE OJ-COMS 2026',
    passBar: 'A: ≥20% recovered PRR; B (MJRLoRa): ≥40% PRR, <20 ms; '
        'C: FSR ≥0.8 at ≤12 dB JSR',
    kind: BenchVerdictKind.queuedBlocked,
    blocker: 'Needs the SDR-bridge bench setup + a jammer bench; neither '
        'exists in the app (no SDR-bridge code at all). Arm B '
        'additionally needs a second gateway transmitter.',
    unblock: 'SDR-bridge bench setup + jammer bench + (for Arm B) a '
        'second gateway transmitter.',
  ),
  BenchEntry(
    id: 'B7',
    title: 'CSI obstruction typing replication',
    source: 'Protsak & Pavlenko, Computer Systems and Networks 8(1), '
        '2026, pp. 203–218, DOI 10.23939/csn2026.01.203',
    passBar: '≥2 node pairs, ≥2 rooms, cross-day; instantaneous classifier '
        '≥80% acc., wall-pair F1 ≥0.70',
    kind: BenchVerdictKind.implement,
    harness: BenchHarness.b7,
    input: BenchInputKind.csi,
    caveat: 'Phase-based arms are expected weak on S3 SISO (single-antenna '
        'phase swamped by CFO/SFO) — a FAIL there is informative, not '
        'surprising. SVM arm is PENDING until a weights sidecar exists.',
  ),
  BenchEntry(
    id: 'B8',
    title: 'Shallow-only EDL uncertainty head',
    source: 'Jia et al., Pervasive and Mobile Computing 119 (2026) 102208',
    passBar: 'Flash <100 KB, SRAM <50 KB, inference <50 ms, beats softmax '
        'on held-out-site OOD',
    kind: BenchVerdictKind.queuedBlocked,
    blocker: 'Firmware/TFLM port to ESP32-S3, not Dart; full system already '
        'over budget (142–145 KB eFlash); no recorded Silvus sessions.',
    unblock: 'A TFLM port that fits the flash budget + recorded Silvus '
        'sessions.',
  ),
  BenchEntry(
    id: 'B9',
    title: 'Multi-target association bench',
    source: 'Bocca, Kaltiokallio, Patwari & Venkatasubramanian, '
        'arXiv:1302.4720v1',
    passBar: 'OMAT ≤0.75 m, Q95 ≤1.5 m, cardinality error ≤0.05, '
        '<100 ms/image',
    kind: BenchVerdictKind.implement,
    harness: BenchHarness.b9,
    caveat: 'MHT rejected for real-time (paper\'s own numbers) — HAC + '
        'gated GNN/SNN + per-track KF only.',
  ),
  BenchEntry(
    id: 'B10',
    title: '1-bit detector back-projection',
    source: 'Yiğitler, Jäntti, Kaltiokallio & Patwari, arXiv:1604.03083v1',
    passBar: 'Mean error ≤0.5 m AND ≤1.5× current RTI error on same data',
    kind: BenchVerdictKind.implement,
    harness: BenchHarness.b10,
    caveat: 'Accuracy arm only; the on-ESP32-S3 cycle-count/RAM arm is '
        'QUEUED-BLOCKED (firmware) — the row never reads PASS on '
        'accuracy alone as if the cost arm had passed.',
  ),
  BenchEntry(
    id: 'B11',
    title: 'ACM path-splitting bench',
    source: 'Abdullah et al., ECTI Trans. EEC 22(2), June 2024',
    passBar: '≥10% MSSIM-equivalent improvement AND no worse localisation '
        '(m) vs baseline',
    kind: BenchVerdictKind.implement,
    harness: BenchHarness.b11,
    caveat: 'LBP-based only; no Tikhonov arm (no Dart Tikhonov exists). '
        'Baseline is the LBP reconstructor built in the harness, stated '
        'in the result — no live Outride reconstructor exists.',
  ),
  BenchEntry(
    id: 'B12',
    title: 'Narrow ESP32 CSI feature A/B',
    source: 'Chaudhari, Preprints.org 202601.2378/v1, Jan 2026',
    passBar: 'CSI features (amplitude mean/var + detrended phase, '
        '100-packet windows) vs RSS-only, scored on detection',
    kind: BenchVerdictKind.implement,
    harness: BenchHarness.b12,
    input: BenchInputKind.csi,
    caveat: 'Phase-based arms are expected weak on S3 SISO — a FAIL there '
        'is informative, not surprising. Fingerprinting stays REJECTED.',
  ),
  BenchEntry(
    id: 'B13',
    title: 'MRS+EHT hovering-rotor accumulation',
    source: 'Tian, Nie, Zhao & Huang, Remote Sens. 2025, 17(21), 3590',
    passBar: 'Hovering-rotor detection at ≥2× the range where NCI fails',
    kind: BenchVerdictKind.queuedBlocked,
    blocker: 'Needs recorded passive range–Doppler data (no passive-radar '
        'subsystem exists in the app at all) AND the cancellation-depth '
        'milestone first.',
    unblock: 'A passive-radar path producing range–Doppler data + the '
        'cancellation-depth milestone.',
  ),
  BenchEntry(
    id: 'B14',
    title: 'KLD-divergence integrity arm (on P21 quarantine bench)',
    source: 'Yu & Liang, Sensors 2025, 25(11), 3526',
    passBar: 'Drift detected before window expires; RF track/alerts unmoved '
        'while quarantined; genuine corroboration not suppressed after',
    kind: BenchVerdictKind.implement,
    harness: BenchHarness.b14,
    caveat: 'Exclusion threshold τ is bench-defined from recorded data '
        '(the paper gives no weight-selection rule and no numeric '
        'values). Fixed-trusted-sensor-1 architecture NOT ported; the '
        'reference is the RF track.',
  ),
  BenchEntry(
    id: 'B15',
    title: 'Gateway-side jam detector (J-DEAS transfer, detector-only)',
    source: 'Del-Valle-Soto et al., J. Sens. Actuator Netw. 2026, 15, 53',
    passBar: 'AUC ≥0.95, F1 ≥0.90 at SF7+SF9, clean-channel duty loss <2%, '
        'must fire when PDR <50%',
    kind: BenchVerdictKind.queuedBlocked,
    blocker: 'No gateway bench, no jammer bench, and no backhaul-log source '
        'in-app; the SNR stream the detector needs dries up under jamming '
        'by the paper\'s own caveat.',
    unblock: 'A gateway bench + jammer bench + a backhaul-log source.',
  ),
  BenchEntry(
    id: 'B16',
    title: 'Entropy-gated quantization (JEAQ-HAR)',
    source: 'Lamaakal et al., Sci Rep 2026, 16:33827',
    passBar: 'Within 1 pp of FP32 on leave-one-deployment-out, ≥20% '
        'latency/energy cut vs INT8 QAT, router actually routes',
    kind: BenchVerdictKind.queuedBlocked,
    blocker: 'Firmware/TFLM port; paper is IMU-only with NO RF/CSI '
        'validation; entropy thresholds must be re-derived on Outride '
        'recordings that do not exist.',
    unblock: 'Recorded Outride sessions to re-derive thresholds + a TFLM '
        'port.',
  ),
  BenchEntry(
    id: 'B17',
    title: 'Continual-learning loop (ACORD-style)',
    source: 'Frederiksen et al., arXiv:2512.13340',
    passBar: '≤50 KB flash, <50 ms on ESP32-S3, ≥10 pp trip-recall gain at '
        'equal FPR, no FPR regression',
    kind: BenchVerdictKind.queuedBlocked,
    blocker: 'On-device retrain loop = firmware; the paper has NO on-MCU '
        'measurement at all (offline sims, batch-256 Adam, GPU-style '
        'distillation); no recorded trip data.',
    unblock: 'Recorded trip data + an on-MCU retrain implementation.',
  ),
  BenchEntry(
    id: 'B18',
    title: 'WBF camera-confirm-tier fusion',
    source: 'Dobrzycki & Bernardos, Applied Intelligence 2026, 56:100, '
        'DOI 10.1007/s10489-026-07142-z',
    passBar: '≥1 pp mAP@50-95 gain AND ≤0.5 pp recall loss vs NMS, <5 ms '
        'on EUD-class hardware, held-out session',
    kind: BenchVerdictKind.queuedBlocked,
    blocker: 'No camera object detector in the app (no bounding boxes '
        'anywhere — ai_classifier.dart is a radio-disturbance MLP) and '
        'no recorded camera sessions. Nothing to fuse.',
    unblock: 'A camera object detector producing boxes + recorded camera '
        'sessions.',
  ),
  BenchEntry(
    id: 'B19',
    title: 'Resonant-tag friendly-ID bench',
    source: 'Vovchuk et al., IEEE Trans. Antennas Propag. 73(6), '
        '3917–3927, June 2025, doi:10.1109/TAP.2025.3540278',
    passBar: 'Tag comb ≥10 dB above untagged blades; ≥90% code '
        'classification at ≥12 dB SNR on ≥4 codes, confusion matrix',
    kind: BenchVerdictKind.queuedBlocked,
    blocker: 'Needs fabricated copper-foil tags + an illuminator near a '
        'fabricable resonance + the SDR bridge; cancellation-depth '
        'milestone first; no radar interrogator in hand.',
    unblock: 'Fabricated tags + an illuminator near a fabricable '
        'resonance + the cancellation-depth milestone.',
  ),
  BenchEntry(
    id: 'B20',
    title: 'Energy-crossover protocol (compute vs communicate)',
    source: 'Siam & Azzedin, Research Square rs-11579488/v1',
    passBar: 'Shepherd\'s own crossover measured (head-only SGD '
        'energy/epoch vs Wi-Fi/HTTP exchange energy/turn)',
    kind: BenchVerdictKind.implement,
    harness: BenchHarness.b20,
    input: BenchInputKind.energy,
    caveat: 'Protocol only: INA238 @ 1 kHz on the 5 V rail + GPIO '
        'phase markers + 60 ms settling pause. The paper\'s claimed '
        'energy figures are NOT imported — the bench measures '
        'Shepherd\'s own numbers or reports pending.',
  ),
  BenchEntry(
    id: 'B-W1',
    title: 'Split-node ambient-link presence',
    source: 'Dual-WiFi note §6 (B-W1) — C3 TX + S3 RX, 3 m apart',
    passBar: 'Moving person crossing a 3 m link: detection ≥90%, FAR ≤5% '
        'on empty-room sessions; held-out 2nd room',
    kind: BenchVerdictKind.implement,
    harness: BenchHarness.bw1,
    input: BenchInputKind.csi,
  ),
  BenchEntry(
    id: 'B-W2',
    title: 'Single-board motion confirm, fenced',
    source: 'Dual-WiFi note §6 (B-W2) — 90 mm TX/RX geometry, '
        'absorber-fence A/B',
    passBar: 'Walking person at 1 m: swing ≥1% above baseline variance; '
        'drift over 60 s <1%. 2 m/3 m: report-only',
    kind: BenchVerdictKind.implement,
    harness: BenchHarness.bw2,
    input: BenchInputKind.csi,
  ),
  BenchEntry(
    id: 'B-W3',
    title: 'RuView phase-variance presence fallback',
    source: 'RuView — lane 6 note (phase-variance fallback; the 92.9% '
        'figure is RUMORED-DISPUTED, blog-only — never cited)',
    passBar: 'Presence/absence ≥90%, FAR ≤5%, on-node decision <50 ms, '
        '<100 KB flash / <50 KB RAM, held-out sessions in 2 rooms',
    kind: BenchVerdictKind.implement,
    harness: BenchHarness.bw3,
    input: BenchInputKind.csi,
    caveat: 'Phase-based arm — expected weak on S3 SISO. Pose models '
        'REJECTED (MM-Fi multi-antenna tensors ≠ S3 SISO).',
  ),
  BenchEntry(
    id: 'B-W4',
    title: 'Split-node breathing attempt (S3-class)',
    source: 'Dual-WiFi note §6 (B-W4) — B-W1 geometry, FFT 0.1–0.5 Hz',
    passBar: 'Breathing within ±2 breaths/min of counted reference at 1 m, '
        '≥80% of 60 s windows; FAR ≤10% empty-room + fan-on',
    kind: BenchVerdictKind.implement,
    harness: BenchHarness.bw4,
    input: BenchInputKind.csi,
    caveat: 'Fan-on negative control is mandatory. Counted reference '
        'comes from the session meta sidecar.',
  ),
  BenchEntry(
    id: 'B-W5',
    title: 'PhaseBeat-style breathing at 2–3 m',
    source: 'Dual-WiFi note §6 (B-W5) — Atheros AR9580 rig',
    passBar: 'Breathing within ±2 breaths/min at 2 m, ≥80% of windows; '
        'fan-on FAR ≤10%',
    kind: BenchVerdictKind.queuedBlocked,
    blocker: 'Needs the Atheros AR9580 rig (5 GHz, 40 MHz, 1 TX × 3 RX, '
        'PC-side processing) — hardware not in hand, PC-side pipeline, '
        'not phone Dart.',
    unblock: 'The AR9580 rig + a PC-side processing pipeline.',
  ),
  BenchEntry(
    id: 'B-W6',
    title: 'Gait-based human-vs-non-human',
    source: 'Dual-WiFi note §6 (B-W6) — Atheros AR9580 rig',
    passBar: '≥90% human-vs-non-human on held-out sessions in 2 rooms '
        '(target ≥85% unseen-environment)',
    kind: BenchVerdictKind.queuedBlocked,
    blocker: 'Same AR9580 rig; needs walking human + dog + vacuum + fan '
        'sessions that do not exist. Large-dog overlap is the known '
        'failure mode.',
    unblock: 'The AR9580 rig + human/dog/vacuum/fan session set.',
  ),
  BenchEntry(
    id: 'B-W7',
    title: 'LiveSense-style monostatic reference',
    source: 'Dual-WiFi note §6 (B-W7) — Intel AX211 laptop + VesperCSI '
        '160 MHz rig',
    passBar: 'Range + Doppler of a walking person at 2–3 m; breathing line '
        'at 2 m; multi-target separation at 0.3 m and 1 m',
    kind: BenchVerdictKind.queuedBlocked,
    blocker: 'Intel AX211 laptop + VesperCSI 160 MHz rig — a reference '
        'measurement of "what doing it properly requires", not a Fetch '
        'bench and not phone code.',
    unblock: 'The AX211 + VesperCSI rig.',
  ),
];

/// Number of runnable bench entries (the pill's M = 13).
///
/// The pill counts harnesses with a runnable input present. The B5
/// arms ride B1's replay (they fuse the same ReplayPoll locals), so
/// they share B1's input readiness and add no separate pill unit:
/// M = the 13 non-B5 IMPLEMENT items (B1, B4, B7, B9, B10, B11, B12,
/// B14, B20, B-W1–B-W4). The B5 group still has its own Run control and
/// its own per-arm result blocks — only the pill folds it into B1.
int get benchRunnableEntryCount {
  return benchRegistry
      .where((e) =>
          e.kind == BenchVerdictKind.implement && e.group == null)
      .length;
}
