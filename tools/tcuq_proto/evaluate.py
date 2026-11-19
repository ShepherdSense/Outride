"""Offline evaluation: TCUQ monitor vs max-confidence baseline.

Runs the paper-faithful monitor (naive lag persistence) and the
Outride transient-aware variant (flip-rate persistence) over
synthetic typing-posterior streams, and compares:

  (a) step-level failure detection (paper's metric): score vs
      step misclassification, AUROC/AUPRC.
  (b) sequence-level trouble separation (the sweep's question):
      sequence-mean score vs INTERFERENCE/FAULT (=1) against
      PASSING/LINGERING (=0), AUROC/AUPRC.
  (c) transient-trap check: per-class flag rates under the
      operational abstain rule, and whether PASSING sequences get
      flagged at a rate that would blow the paper's 15% budget.
  (d) shifted-set check: do shifted mover sequences score higher
      than clean movers (the paper's CID claim, Outride-flavored)?

Operational rule used here (offline approximation of the paper's
streaming conformal + budget controller): a sequence is abstained
when its mean r reaches the dev-set 90th percentile of sequence-
mean r. The guardrail framing is fixed: abstention withholds the
TYPE LABEL + confidence only; the deterministic tripwire alert is
never gated by this score and is not modeled here at all.

Usage: ~/workspace/.mlvenv/bin/python evaluate.py
Writes results.json and results.md next to this file.
"""

import json
import os

import numpy as np
from sklearn.metrics import average_precision_score, roc_auc_score

from sequences import (CLASSES, make_sequences,
                       make_shifted_sequences)
from tcuq import TCUQMonitor

_HERE = os.path.dirname(os.path.abspath(__file__)
)
TROUBLE = {"INTERFERENCE", "FAULT"}
MOVER = {"PASSING", "LINGERING"}


def run_monitor(seqs, transient_aware, weights=None):
    """Run the monitor over every sequence; return per-sequence
    records of per-step signals, maxprob, correctness."""
    out = []
    for s in seqs:
        mon = TCUQMonitor(transient_aware=transient_aware)
        mon.weights = weights
        rows = []
        for p, f in zip(s["posteriors"], s["features"]):
            rows.append(mon.step(p, f))
        scored = [(r, c) for r, c in zip(rows, s["step_correct"])
                  if r["D"] is not None]
        out.append({"label": s["label"], "rows": rows,
                    "scored": scored,
                    "n_steps": len(rows),
                    "n_scored": len(scored),
                    "final_correct": bool(s["step_correct"][-1]),
                    "provenance": s["provenance"]})
    return out


def _signals_of(records):
    X, y = [], []
    for rec in records:
        for r, correct in rec["scored"]:
            X.append([r["D"], r["instab"], r["incons"], r["m"]])
            y.append(0 if correct else 1)
    return np.array(X), np.array(y)


def _r_of(records, weights, lam=0.7):
    """Compute U and r from stored signals + fitted weights."""
    w, b = weights
    for rec in records:
        for r, _ in rec["scored"]:
            sig = np.array([r["D"], r["instab"], r["incons"], r["m"]])
            u = 1.0 / (1.0 + np.exp(-(float(w @ sig) + b)))
            r["U"] = float(u)
            r["r"] = float(lam * u + (1.0 - lam) * (1.0 - r["maxprob"]))
    return records


def _auc_pair(score, target):
    score = np.asarray(score, dtype=float)
    target = np.asarray(target, dtype=int)
    if len(np.unique(target)) < 2 or len(score) == 0:
        return None, None
    return (float(roc_auc_score(target, score)),
            float(average_precision_score(target, score)))


def _seq_scores(records, key):
    """Sequence-level scores: mean of a per-step quantity."""
    vals, labels = [], []
    for rec in records:
        if rec["n_scored"] == 0:
            continue
        vals.append(float(np.mean([r[key] for r, _ in rec["scored"]])))
        labels.append(1 if rec["label"] in TROUBLE else 0)
    return np.array(vals), np.array(labels)


def _flag_rates(records, threshold):
    """Per-class fraction of sequences with mean r >= threshold,
    plus kept-sequence final-typing accuracy."""
    rates, kept_acc = {}, {}
    for label in CLASSES:
        recs = [r for r in records if r["label"] == label
                and r["n_scored"] > 0]
        if not recs:
            rates[label] = None
            kept_acc[label] = None
            continue
        flagged = [np.mean([x["r"] for x, _ in r["scored"]]) >= threshold
                   for r in recs]
        rates[label] = float(np.mean(flagged))
        kept = [r for r, f in zip(recs, flagged) if not f]
        kept_acc[label] = (float(np.mean([r["final_correct"]
                                          for r in kept]))
                           if kept else None)
    return rates, kept_acc


def main():
    print("generating synthetic sequences (SYNTHETIC-ONLY) ...")
    dev = make_sequences(250, seed=101)
    test = make_sequences(250, seed=202)
    shifted = make_shifted_sequences(100, seed=303)
    print(f"  dev={len(dev)} test={len(test)} "
          f"shifted={len(shifted)} sequences")

    results = {"provenance": "SYNTHETIC-ONLY",
               "dev_n": len(dev), "test_n": len(test),
               "shifted_n": len(shifted)}
    variants = {}
    for name, ta in (("naive", False), ("transient_aware", True)):
        print(f"variant: {name}")
        dev_rec = run_monitor(dev, ta)
        X, y = _signals_of(dev_rec)
        mon = TCUQMonitor(transient_aware=ta)
        w, b = mon.fit_logistic(X, y)
        test_rec = _r_of(run_monitor(test, ta), (w, b))
        dev_rec = _r_of(dev_rec, (w, b))

        # (a) step-level failure detection
        s_r, t_r = [], []
        s_b, t_b = [], []
        for rec in test_rec:
            for r, correct in rec["scored"]:
                s_r.append(r["r"])
                t_r.append(0 if correct else 1)
                s_b.append(1.0 - r["maxprob"])
                t_b.append(0 if correct else 1)
        auroc_r, auprc_r = _auc_pair(s_r, t_r)
        auroc_b, auprc_b = _auc_pair(s_b, t_b)

        # (b) sequence-level trouble separation
        seq_r, seq_y = _seq_scores(test_rec, "r")
        seq_b, _ = _seq_scores(test_rec, "maxprob")
        seq_b = 1.0 - seq_b
        auroc_seq_r, auprc_seq_r = _auc_pair(seq_r, seq_y)
        auroc_seq_b, auprc_seq_b = _auc_pair(seq_b, seq_y)

        # per-signal sequence-level AUROC (trouble separation)
        per_signal = {}
        for key in ("D", "instab", "incons", "m"):
            v, yv = _seq_scores(test_rec, key)
            a, p = _auc_pair(v, yv)
            per_signal[key] = {"auroc": a, "auprc": p}

        # (c) operational flag rates: threshold = dev 90th pct of
        # sequence-mean r
        dev_seq_r, _ = _seq_scores(dev_rec, "r")
        q = float(np.quantile(dev_seq_r, 0.90))
        rates, kept_acc = _flag_rates(test_rec, q)
        # reference: final-typing accuracy with no abstention
        ref_acc = {}
        for label in CLASSES:
            recs = [r for r in test_rec if r["label"] == label]
            ref_acc[label] = float(np.mean([r["final_correct"]
                                            for r in recs]))

        variants[name] = {
            "logistic_weights": [float(v) for v in w],
            "logistic_bias": float(b),
            "step_failure_detection": {
                "tcuq_r": {"auroc": auroc_r, "auprc": auprc_r},
                "baseline_1_minus_maxprob": {"auroc": auroc_b,
                                             "auprc": auprc_b},
                "n_steps": len(s_r),
            },
            "sequence_trouble_separation": {
                "tcuq_mean_r": {"auroc": auroc_seq_r,
                                "auprc": auprc_seq_r},
                "baseline_mean_1_minus_maxprob": {
                    "auroc": auroc_seq_b, "auprc": auprc_seq_b},
                "per_signal_mean": per_signal,
                "n_sequences": len(seq_r),
            },
            "operational_rule": {
                "threshold_dev_p90_seq_mean_r": q,
                "flag_rate_per_class": rates,
                "kept_final_typing_accuracy": kept_acc,
                "reference_final_typing_accuracy_no_abstain": ref_acc,
            },
        }
        print(f"  step failure: TCUQ AUROC={auroc_r:.3f} "
              f"vs baseline {auroc_b:.3f}")
        print(f"  seq trouble:  TCUQ AUROC={auroc_seq_r:.3f} "
              f"vs baseline {auroc_seq_b:.3f}")
        print(f"  flag rates: {rates}")

    # (d) shifted-set check with the transient-aware variant (the
    # candidate) -- refit-free: reuse its test-time weights via a
    # fresh monitor run + stored weights is complex, so instead
    # report mean per-step signals and baseline scores, which do
    # not need the combiner, plus r recomputed from the variant
    # weights stored above.
    w = np.array(variants["transient_aware"]["logistic_weights"])
    b = variants["transient_aware"]["logistic_bias"]
    shifted_rec = _r_of(run_monitor(
        [s for _, s in shifted], True), (w, b))
    shift_names = [n for n, _ in shifted]
    clean_movers = [r for r in _r_of(run_monitor(
        [s for s in test if s["label"] in MOVER], True), (w, b))]
    clean_mean_r = float(np.mean(
        [np.mean([x["r"] for x, _ in r["scored"]])
         for r in clean_movers if r["n_scored"] > 0]))
    shifted_rows = {}
    for name in sorted(set(shift_names)):
        recs = [r for nm, r in zip(shift_names, shifted_rec)
                if nm == name and r["n_scored"] > 0]
        shifted_rows[name] = {
            "n": len(recs),
            "mean_seq_r": float(np.mean(
                [np.mean([x["r"] for x, _ in r["scored"]])
                 for r in recs])) if recs else None,
            "mean_seq_baseline": float(np.mean(
                [np.mean([1.0 - x["maxprob"] for x, _ in r["scored"]])
                 for r in recs])) if recs else None,
        }
    results["variants"] = variants
    results["shifted_check_transient_aware"] = {
        "clean_mover_mean_seq_r": clean_mean_r,
        "shifted": shifted_rows,
    }
    print(f"  clean mover mean r: {clean_mean_r:.3f}")
    for k, v in shifted_rows.items():
        print(f"  shifted {k}: mean r {v['mean_seq_r']:.3f} "
              f"(baseline {v['mean_seq_baseline']:.3f})")

    with open(os.path.join(_HERE, "results.json"), "w") as f:
        json.dump(results, f, indent=2)
    print("wrote results.json")
    return results


if __name__ == "__main__":
    main()
