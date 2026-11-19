"""TCUQ temporal-consistency monitor, offline prototype.

Implements the four signals of Lamaakal et al., arXiv:2508.12905, §3,
verified against the paper text (not second-hand summaries):

  D_t   multi-lag predictive divergence: sum over lags L={1,2,4} of
        w^(l) * JSD(p_t || p_{t-l}), weights proportional to 1/l.
  1-S_t feature instability: 1 - mean cosine similarity between the
        current feature vector and lagged feature vectors.
  1-c_t decision inconsistency: 1 - mean indicator[argmax_t == argmax_{t-l}].
  m_t   confidence/margin proxy: a_m*(1-maxprob) + (1-a_m)*(1-margin),
        margin = top1 - top2 posterior. (The paper leaves the blend
        weight unnamed in §3; a_m = 0.5 here, stated not hidden.)

  U_t = sigmoid(w . s_t + b), logistic combiner fitted once offline.
  r_t = lam * U_t + (1-lam) * (1 - maxprob), lam = 0.7 (paper default).

Streaming conformal layer: a memory-constant quantile tracker over r_t
(stochastic-approximation update toward the (1-alpha) quantile,
alpha = 0.1 default, with a warm-up phase that defaults to
conservative behavior). The paper's streaming quantile adapts under
drift and therefore does NOT carry split conformal's finite-sample
coverage guarantee -- this prototype reports an empirical abstention
rate, never "guaranteed coverage".

TRANSIENT-AWARE VARIANT (Outride adaptation, not in the paper):
  The paper's (1-c_t) penalizes ANY recent label flip. A genuine
  Outride PASSING event is transient by design -- a fast pass looks
  like a flip -- so naive persistence would flag real passes as
  uncertain. The transient-aware variant replaces lag persistence
  with a flip-RATE over the last 8 steps: a single coherent
  transition scores 1/8, repeated flicker scores high. The variant
  is online-safe (history only, no look-ahead).

OUTRIDE GUARDRAIL (non-negotiable): abstain suppresses ONLY the
type label + confidence. It NEVER suppresses the deterministic
tripwire alert. This module emits scores and abstain flags for
offline evaluation; it contains no alerting logic at all.

State cost: ring buffer of W posteriors (L=4 classes) + W feature
vectors (d=10 scaled features). At W=16, int8-style accounting is
~16*(10+4) = 224 slots -- the monitor is cheap; the backbone is
the constraint (see lane-6 notes).
"""

import math

import numpy as np

LAGS = (1, 2, 4)
LAG_WEIGHTS = np.array([1.0 / l for l in LAGS], dtype=float)
LAG_WEIGHTS = LAG_WEIGHTS / LAG_WEIGHTS.sum()

EPS = 1e-8


def _jsd(p, q):
    """Jensen-Shannon divergence between two posteriors."""
    p = np.asarray(p, dtype=float) + EPS
    q = np.asarray(q, dtype=float) + EPS
    p = p / p.sum()
    q = q / q.sum()
    m = 0.5 * (p + q)
    return float(0.5 * np.sum(p * np.log(p / m))
                 + 0.5 * np.sum(q * np.log(q / m)))


def _cosine(a, b):
    a = np.asarray(a, dtype=float)
    b = np.asarray(b, dtype=float)
    na = np.linalg.norm(a)
    nb = np.linalg.norm(b)
    if na < EPS or nb < EPS:
        return 0.0
    return float(np.dot(a, b) / (na * nb))


class TCUQMonitor:
    """Streaming TCUQ monitor over one posterior stream.

    Feed steps in order with step(posterior, features). Signals are
    None until enough history exists for lag 4 (step index >= 4).
    """

    def __init__(self, window=16, lam=0.7, alpha_m=0.5,
                 transient_aware=False, flip_window=8):
        self.window = window
        self.lam = lam
        self.alpha_m = alpha_m
        self.transient_aware = transient_aware
        self.flip_window = flip_window
        self.posteriors = []   # list of np arrays, len <= window
        self.features = []     # list of np arrays, len <= window
        self.labels = []       # list of ints
        self.weights = None    # logistic (w, b), set by fit()
        self.quantile = None   # streaming (1-alpha) quantile of r
        self.alpha_q = 0.1

    # ------------------------------------------------------------ step
    def step(self, posterior, features):
        """Advance one step; return dict of signals (None if warming
        up) plus U and r once the combiner is fitted."""
        posterior = np.asarray(posterior, dtype=float)
        features = np.asarray(features, dtype=float)
        self.posteriors.append(posterior)
        self.features.append(features)
        self.labels.append(int(np.argmax(posterior)))
        if len(self.posteriors) > self.window:
            self.posteriors.pop(0)
            self.features.pop(0)
            self.labels.pop(0)
        out = {"D": None, "instab": None, "incons": None, "m": None,
               "U": None, "r": None}
        if len(self.posteriors) <= max(LAGS):
            return out  # warm-up: not enough history for lag 4
        t = len(self.posteriors) - 1
        p_t = self.posteriors[t]
        f_t = self.features[t]
        d = 0.0
        s = 0.0
        c = 0.0
        for w, lag in zip(LAG_WEIGHTS, LAGS):
            d += w * _jsd(p_t, self.posteriors[t - lag])
            s += _cosine(f_t, self.features[t - lag]) / len(LAGS)
            c += (1.0 if self.labels[t] == self.labels[t - lag]
                  else 0.0) / len(LAGS)
        if self.transient_aware:
            # Flip-rate over the recent window: one coherent
            # transition costs 1/flip_window; repeated flicker
            # costs far more. History only -- online-safe.
            recent = self.labels[-self.flip_window:]
            flips = sum(1 for a, b in zip(recent, recent[1:])
                        if a != b)
            incons = flips / max(1, len(recent) - 1)
        else:
            incons = 1.0 - c
        top = np.sort(p_t)[::-1]
        maxprob = float(top[0])
        margin = float(top[0] - top[1]) if len(top) > 1 else maxprob
        m = (self.alpha_m * (1.0 - maxprob)
             + (1.0 - self.alpha_m) * (1.0 - margin))
        out.update({"D": d, "instab": 1.0 - s, "incons": incons,
                    "m": m, "maxprob": maxprob})
        if self.weights is not None:
            w, b = self.weights
            sig = np.array([d, 1.0 - s, incons, m])
            u = 1.0 / (1.0 + math.exp(-(float(w @ sig) + b)))
            r = self.lam * u + (1.0 - self.lam) * (1.0 - maxprob)
            out["U"] = u
            out["r"] = r
        return out

    # ------------------------------------------------------------ fit
    def fit_logistic(self, signal_rows, targets):
        """Fit the logistic combiner (w, b) on dev signals.

        Paper-faithful target: misclassification (1 = backbone
        argmax wrong). L2-regularized, class-balanced logistic
        regression (sklearn, same dependency as the training
        script). Returns (w, b)."""
        from sklearn.linear_model import LogisticRegression
        X = np.asarray(signal_rows, dtype=float)
        y = np.asarray(targets, dtype=int)
        clf = LogisticRegression(C=1.0, class_weight="balanced",
                                 max_iter=2000)
        clf.fit(X, y)
        self.weights = (clf.coef_[0].copy(), float(clf.intercept_[0]))
        return self.weights

    # ------------------------------------------------------- quantile
    def update_quantile(self, r, warmup_steps=50):
        """Memory-constant stochastic-approximation quantile tracker.

        q <- q + eta * ((1-alpha_q) - 1[r <= q]) with decaying eta.
        During warm-up (before warmup_steps updates) the caller
        should treat decisions as conservative; this method just
        tracks. Returns the current quantile estimate (None until
        the first update seeds it)."""
        if self.quantile is None:
            self.quantile = float(r)
            self._q_steps = 1
            return self.quantile
        self._q_steps += 1
        eta = 1.0 / (1.0 + 0.05 * self._q_steps)
        target = 1.0 - self.alpha_q
        self.quantile += eta * (target - (1.0 if r <= self.quantile
                                          else 0.0))
        return self.quantile
