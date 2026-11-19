# TCUQ offline prototype — NOT shipped code

Offline-only evaluation of the TCUQ temporal-consistency monitor
(Lamaakal et al., arXiv:2508.12905, §3 — signal definitions
verified against the paper text) on Outride typing-posterior
streams. Nothing here is imported by, linked to, or shipped in
the app. No on-device port, no publishing.

## Verdict: DROP (see results.md)

The monitor does not beat a max-confidence baseline on Outride
data on any tested question, and its trouble-separation AUROC is
below chance (0.33) because FAULT — a pinned flatline — is the
most temporally consistent class in the taxonomy. The paper's
vision/audio numbers do not transfer to this domain.

## Files

- `tcuq.py` — the monitor: 4 signals (multi-lag JSD divergence,
  feature instability, decision inconsistency, confidence/margin
  proxy), logistic combiner, streaming quantile tracker, plus the
  Outride transient-aware variant (flip-rate persistence).
- `sequences.py` — synthetic sequence generation from
  `tools/train_disturbance_clf.py` generators + the frozen shipped
  MLP (forward pass verified bit-exact vs `test/ai_golden.json`).
- `evaluate.py` — the experiment: failure detection, trouble
  separation, operational flag rates, shifted-set check.
- `results.json` / `results.md` — numbers and interpretation.

## Data honesty

SYNTHETIC-ONLY. No recorded Outride sequences exist; the corpus
is the training script's synthetic generators. Posterior streams
simulate online typing by classifying prefix windows of each
event's dip series — prefix features are off-distribution relative
to whole-event training, so results measure the "prefix-typing +
monitor" system, not the shipped classifier's whole-event accuracy.

## Guardrail

Abstention withholds ONLY the type label + confidence. It NEVER
suppresses the deterministic tripwire alert. This prototype
contains no alerting logic.

## Run

```
~/workspace/.mlvenv/bin/python evaluate.py
```
