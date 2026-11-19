"""Build Outride typing-posterior sequences from synthetic data.

DATA HONESTY: no recorded Outride disturbance sequences exist in
this workspace (see tools/train_disturbance_clf.py docstring: the
corpus is synthetic, seed 7, and "no recorded link-shadow image
dataset exists"). Every sequence here is SYNTHETIC-ONLY, generated
by that script's own event generators (gen_passing / gen_lingering /
gen_interference / gen_fault).

ONLINE-TYPING SIMULATION: the shipped classifier classifies CLOSED
events (one 10-feature vector per event). A phone-tier typing stream
re-classifies as samples arrive, so each event's dip series is
turned into a posterior stream by classifying PREFIX windows:
at step k the features are extracted from dips[:k] with elapsed
time k/4 s (the generators sample at 4 Hz). Prefix features are
off-distribution relative to whole-event training features -- that
is inherent to simulating an online tier from an event classifier,
and the results below measure the "prefix-typing + monitor" system,
not the shipped event classifier's whole-event accuracy.

Posterior computation reuses the SHIPPED weights
(assets/models/disturbance_clf.json) with a numpy forward pass
verified bit-exact against test/ai_golden.json (max abs diff
~1.6e-17). No retraining: the backbone is frozen, exactly as
TCUQ requires.

SHIFTED SETS (test only, mover classes only): label-preserving
distortions the training corpus never produced, standing in for
the paper's CID/OOD evaluation:
  gain      dips x 1.6, threshold unchanged (amplitude shift).
  spikes    random 1-sample spikes added to a mover series.
  mixed     PASSING/LINGERING series + sine-flicker overlay
            (mover inside a noisy RF environment).
  square    interference with a square-wave flicker family, which
            no training generator produces (novel pattern family).

Each sequence dict: label (true event class), posteriors (T x 4),
features (T x 10, scaled), step_correct (bool per step), plus the
event's context (threshold, simul, cross, mesh) and provenance.
"""

import json
import math
import os
import random
import sys

import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(os.path.dirname(_HERE))
sys.path.insert(0, os.path.join(_ROOT, "tools"))
import train_disturbance_clf as tdc  # noqa: E402

CLASSES = ["PASSING", "LINGERING", "INTERFERENCE", "FAULT"]
GENERATORS = tdc.GENERATORS

_MODEL = json.load(open(os.path.join(_ROOT, "assets", "models",
                                     "disturbance_clf.json")))
_MEAN = np.array(_MODEL["scaler_mean"])
_SCALE = np.array(_MODEL["scaler_scale"])
_LAYERS = [(np.array(l["W"]), np.array(l["b"]))
           for l in _MODEL["layers"]]
_MODEL_CLASSES = list(_MODEL["classes"])  # sklearn order: alphabetical
_IDX = {c: i for i, c in enumerate(_MODEL_CLASSES)}


def _forward_posterior(feat10):
    """Shipped MLP forward pass -> posterior over _MODEL_CLASSES."""
    x = (np.asarray(feat10, dtype=float) - _MEAN) / _SCALE
    for i, (W, b) in enumerate(_LAYERS):
        x = W @ x + b
        if i < len(_LAYERS) - 1:
            x = np.maximum(x, 0.0)
    e = np.exp(x - x.max())
    return e / e.sum()


def _prefix_steps(n, max_steps=64, min_prefix=4):
    """Step boundaries: prefixes from min_prefix to n, capped at
    max_steps, always including the full series as the final step
    (the event-close typing)."""
    if n <= min_prefix:
        return [n]
    stride = max(1, (n - min_prefix) // (max_steps - 1))
    steps = list(range(min_prefix, n, stride))
    if steps[-1] != n:
        steps.append(n)
    return steps


def event_to_sequence(label, series, thr, simul, cross, mesh):
    """One synthetic event -> posterior stream over prefix windows."""
    n = len(series)
    posteriors = []
    features = []
    correct = []
    true_idx = _IDX[label]
    for k in _prefix_steps(n):
        prefix = series[:k]
        feat = tdc.extract_features(prefix, thr, k / 4.0,
                                    simul, cross, mesh)
        scaled = (np.array(feat) - _MEAN) / _SCALE
        post = _forward_posterior(feat)
        posteriors.append(post)
        features.append(scaled)
        correct.append(int(np.argmax(post)) == true_idx)
    return {
        "label": label,
        "posteriors": np.array(posteriors),
        "features": np.array(features),
        "step_correct": np.array(correct, dtype=bool),
        "n_samples": n,
        "threshold": thr,
        "simul": simul,
        "cross": cross,
        "mesh": mesh,
        "provenance": "SYNTHETIC-ONLY (train_disturbance_clf generators)",
    }


def _gen_event(label, rng_state=None):
    """Generate one event exactly as make_dataset does (context
    logic mirrored: cross = simul>1 and rand<0.35, mesh U[2,40])."""
    thr = random.uniform(4.0, 10.0)
    dips, dur, simul = GENERATORS[label](thr)
    cross = simul > 1 and random.random() < 0.35
    mesh = random.randint(2, 40)
    return label, dips, thr, simul, cross, mesh


def make_sequences(n_per_class, seed):
    """Deterministic sequence set: seed the global generators, then
    generate n_per_class events per class in CLASSES order."""
    random.seed(seed)
    np.random.seed(seed)
    seqs = []
    for label in CLASSES:
        for _ in range(n_per_class):
            ev = _gen_event(label)
            seqs.append(event_to_sequence(*ev))
    return seqs


# ------------------------------------------------------------- shifts
def _shift_gain(series, thr):
    return [min(30.0, d * 1.6) for d in series]


def _shift_spikes(series, thr):
    out = list(series)
    for _ in range(max(2, len(out) // 12)):
        i = random.randrange(len(out))
        out[i] = out[i] + random.uniform(1.0, 3.0) * thr
    return out


def _shift_mixed(series, thr):
    f = random.uniform(0.5, 3.0)
    ph = random.uniform(0, 6.28)
    return [d + 0.8 * thr * abs(math.sin(ph + f * i / len(series) * 6.28))
            for i, d in enumerate(series)]


def _shift_square_flicker(series, thr):
    # Novel interference family: square-wave on/off flicker. Used
    # as the event itself (label INTERFERENCE, shifted family).
    n = len(series)
    peak = random.uniform(1.05, 3.0) * thr
    out = []
    on = True
    left = random.randint(1, 6)
    for _ in range(n):
        if left == 0:
            on = not on
            left = random.randint(1, 6)
        left -= 1
        out.append(peak if on else peak * random.uniform(0.0, 0.2))
    return tdc._noisy(out, thr, sigma=0.25)


SHIFTS = {
    "gain": _shift_gain,
    "spikes": _shift_spikes,
    "mixed": _shift_mixed,
}


def make_shifted_sequences(n_per_class, seed):
    """Mover-class events (PASSING/LINGERING) under each shift, plus
    square-wave INTERFERENCE as a novel-family case. Test only."""
    random.seed(seed)
    np.random.seed(seed)
    seqs = []
    for label in ("PASSING", "LINGERING"):
        for shift_name, fn in SHIFTS.items():
            for _ in range(n_per_class):
                _, dips, thr, simul, cross, mesh = _gen_event(label)
                seqs.append((shift_name, event_to_sequence(
                    label, fn(dips, thr), thr, simul, cross, mesh)))
    for _ in range(n_per_class):
        thr = random.uniform(4.0, 10.0)
        dur = random.uniform(1.0, 40.0)
        n = max(8, int(dur * 4))
        base = [0.0] * n
        dips = _shift_square_flicker(base, thr)
        seqs.append(("square", event_to_sequence(
            "INTERFERENCE", dips, thr, 1, False, random.randint(2, 40))))
    return seqs
