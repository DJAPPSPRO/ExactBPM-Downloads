"""Reference implementation of the RhythmCore AutoCue engine.
Every step here is mirrored 1:1 in the Swift app (CueEngine.swift), so this file is the test oracle.
Usage: python3 engine_ref.py file.mp3 [...]
"""
import sys, json, subprocess
import numpy as np

SR, NFFT, HOP = 22050, 2048, 128
FPS = SR / HOP
BANDS = [(20, 150), (150, 500), (500, 2000), (2000, 6000), (6000, 11000)]
TIMBRE_EDGES = np.geomspace(40, 10000, 17)  # 16 log-spaced bands for beat-level timbre


# ---------------- A/B: decode + per-frame features (no full spectrogram kept) ----------------
def decode(path):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-map", "0:a:0", "-ac", "1", "-ar", str(SR),
                          "-f", "f32le", "-"], capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.float32).astype(np.float64)


def frame_features(y):
    freqs = np.arange(NFFT // 2 + 1) * SR / NFFT
    win = 0.5 - 0.5 * np.cos(2 * np.pi * np.arange(NFFT) / NFFT)  # periodic Hann
    pad = np.concatenate([np.zeros(NFFT // 2), y, np.zeros(NFFT // 2)])
    n = 1 + (len(pad) - NFFT) // HOP
    band_masks = [(freqs >= lo) & (freqs < hi) for lo, hi in BANDS]
    tim_masks = [(freqs >= lo) & (freqs < hi) for lo, hi in zip(TIMBRE_EDGES[:-1], TIMBRE_EDGES[1:])]
    low_m = freqs < 150
    mid_m = (freqs >= 150) & (freqs < 4000)
    cm = (freqs > 60) & (freqs < 4000)
    pc = np.zeros(len(freqs), int)
    pc[cm] = (np.round(12 * np.log2(freqs[cm] / 440.0)) % 12).astype(int)
    F = {k: np.zeros(n) for k in ["fall", "flow", "fmid", "pow"]}
    F["band"] = np.zeros((n, 5)); F["chroma"] = np.zeros((n, 12)); F["tim"] = np.zeros((n, 16))
    prevL = None
    for s in range(0, n, 2048):  # chunked, same math as per-frame
        e = min(n, s + 2048)
        idx = np.arange(NFFT)[None, :] + HOP * np.arange(s, e)[:, None]
        M = np.abs(np.fft.rfft(pad[idx] * win, axis=1))
        L = np.log1p(100 * M)
        P = np.concatenate([L[:1] if prevL is None else prevL[None], L])
        D = np.maximum(np.diff(P, axis=0), 0)
        prevL = L[-1]
        F["fall"][s:e] = D.sum(1); F["flow"][s:e] = D[:, low_m].sum(1); F["fmid"][s:e] = D[:, mid_m].sum(1)
        M2 = M ** 2
        F["pow"][s:e] = M2.mean(1)
        for b, m in enumerate(band_masks): F["band"][s:e, b] = M2[:, m].mean(1)
        for b, m in enumerate(tim_masks): F["tim"][s:e, b] = L[:, m].mean(1)
        for c in range(12): F["chroma"][s:e, c] = M[:, cm & (pc == c)].sum(1)
    return F


def moving_avg(x, w):
    # centered moving average, window w, edges use available samples
    c = np.concatenate([[0], np.cumsum(x)])
    n = len(x); h = w // 2
    lo = np.clip(np.arange(n) - h, 0, n); hi = np.clip(np.arange(n) - h + w, 0, n)
    return (c[hi] - c[lo]) / (hi - lo)


def norm_flux(x):
    x = np.maximum(x - moving_avg(x, 64), 0)
    return x / (x.max() + 1e-9)


# ---------------- D/E: tempo + grid ----------------
def interp(arr, pos):
    return np.interp(pos, np.arange(len(arr)), arr)


def estimate_tempo(o):
    oc = o - o.mean()
    maxlag = int(4 * 60 * FPS / 60) + 4
    ac = np.array([np.dot(oc[:len(oc) - l], oc[l:]) for l in range(maxlag)])
    bpms = np.arange(60.0, 200.0, 0.05)
    lag = 60 * FPS / bpms
    sc = interp(ac, lag) + 0.5 * interp(ac, 2 * lag) + 0.25 * interp(ac, 4 * lag)
    prior = np.exp(-0.5 * (np.log2(bpms / 115.0) / 0.9) ** 2)
    return bpms[np.argmax(sc * prior)]


def fold(o, p, bins=64):
    h = np.zeros(bins)
    b = np.minimum(((np.arange(len(o)) % p) / p * bins).astype(int), bins - 1)
    np.add.at(h, b, o)
    return h


def refine_grid(o, bpm):
    per = 60 * FPS / bpm
    best = None
    for p in np.linspace(per * 0.995, per * 1.005, 201):
        h = fold(o, p)
        c = h.max() / (h.mean() + 1e-12)
        if best is None or c > best[0]: best = (c, p, (np.argmax(h) + 0.5) * p / 64)
    contrast, p, ph = best
    best2 = None
    k_all = np.arange(int(len(o) / p) + 2)
    for p2 in np.linspace(p * 0.9995, p * 1.0005, 21):
        for ph2 in np.arange(ph - p / 64, ph + p / 64 + 1e-9, 0.1):
            pos = ph2 + k_all * p2
            pos = pos[pos < len(o) - 1]
            s = interp(o, pos).sum()
            if best2 is None or s > best2[0]: best2 = (s, p2, ph2)
    _, p, ph = best2
    # steadiness: fold each quarter at p and compare peak phase
    q = len(o) // 4; peaks = []
    for i in range(4):
        h = fold(o[i * q:(i + 1) * q], p)
        off = (i * q) % p
        peaks.append(((np.argmax(h) + 0.5) * p / 64 + off) % p)
    peaks = np.array(peaks); d = (peaks - peaks[0] + p / 2) % p - p / 2
    drift_ms = (d.max() - d.min()) / FPS * 1000
    return p, ph % p, contrast, drift_ms


# ---------------- G/H: downbeat + bars ----------------
def max_filter(x, w=5):
    h = w // 2
    out = x.copy()
    for s in range(1, h + 1):
        out[:-s] = np.maximum(out[:-s], x[s:]); out[s:] = np.maximum(out[s:], x[:-s])
    return out


def seg_mean(arr, starts, ends):
    return np.array([arr[a:b].mean(0) if b > a else arr[min(a, len(arr) - 1)] for a, b in zip(starts, ends)])


def attack_shift(y, db_times):
    """Seconds to add to the grid so cues sit right on the beat.
    The 2048-point analysis window reacts ~20 ms before the attack; measure the real attack
    on every downbeat with an 11.6 ms window and move the whole grid by the median.
    Lands exactly on the measured attack (no early bias)."""
    N, H = 256, 22
    win = 0.5 - 0.5 * np.cos(2 * np.pi * np.arange(N) / N)
    d = []
    for t in db_times[1:]:
        c = int(t * SR); a = c - int(0.06 * SR); b = c + int(0.06 * SR)
        if a < 0 or b + N > len(y): continue
        idx = np.arange(a, b, H)
        L = np.log1p(1000 * np.abs(np.fft.rfft(np.stack([y[i:i + N] * win for i in idx]), axis=1)))
        fl = np.r_[0, np.maximum(np.diff(L, axis=0), 0).sum(1)]
        k = int(np.argmax(fl))
        d.append((idx[k] + N / 2) / SR - t)
    if len(d) < 8: return 0.0
    bias = float(np.clip(np.median(d), -0.010, 0.060))
    return bias  # land exactly on the attack so cues are perfect on-beat


def analyze_bars(path):
    y = decode(path)
    dur = len(y) / SR
    F = frame_features(y)
    n = len(F["pow"])
    o_all, o_low, o_mid = norm_flux(F["fall"]), norm_flux(F["flow"]), norm_flux(F["fmid"])
    o = 0.5 * o_all + 0.3 * o_low + 0.2 * o_mid
    bpm0 = estimate_tempo(o)
    p, ph, contrast, drift = refine_grid(o, bpm0)
    beats_f = ph + np.arange(int((n - ph) / p) + 1) * p
    beats_f = beats_f[beats_f < n]
    bi = beats_f.astype(int)
    be = np.r_[bi[1:], n]
    # downbeat phase
    low_at = interp(max_filter(o_low), beats_f)
    ch = seg_mean(F["chroma"], bi, be); ch /= ch.sum(1, keepdims=True) + 1e-9
    hc = np.r_[0, np.abs(np.diff(ch, axis=0)).sum(1)]
    bdb = 10 * np.log10(seg_mean(F["pow"], bi, be) + 1e-12)
    ed = np.abs(np.r_[0, np.diff(bdb)])
    scores = []
    for k in range(4):
        m = (np.arange(len(bi)) - k) % 4 == 0
        z = lambda v: (v[m].mean() - v[~m].mean()) / (v.std() + 1e-9)
        scores.append(2.5 * z(low_at) + z(hc) + 0.5 * z(ed))
    dph = int(np.argmax(scores))
    # Safety: if top two are close, prefer the phase with the strongest absolute early kicks.
    order = np.argsort(scores)[::-1]
    if len(order) >= 2 and scores[order[0]] - scores[order[1]] < 0.15:
        early = min(32, len(low_at))
        best_kick, best_k = -np.inf, dph
        for k in range(4):
            s = sum(low_at[i] for i in range(k, early, 4))
            if s > best_kick:
                best_kick, best_k = s, k
        dph = best_k
    db_f = list(beats_f[dph::4])
    bar_f = 4 * p
    pickup = db_f[0] - bar_f >= -0.06 * FPS
    clamped = pickup and db_f[0] - bar_f < 0   # extrapolated bar that starts before the file does
    if pickup: db_f = [max(0.0, db_f[0] - bar_f)] + db_f
    db_f = np.array(db_f)
    # onset strength right at each downbeat (is there an actual hit on beat 1?)
    o_peak = max_filter(o_all, 7)
    db_onset = interp(o_peak, db_f)
    shift = attack_shift(y, db_f / FPS)
    db_f = np.maximum(db_f + shift * FPS, 0)
    beats_f = beats_f + shift * FPS
    bs = db_f.astype(int); bend = np.r_[bs[1:], n]
    rms = 10 * np.log10(seg_mean(F["pow"], bs, bend) + 1e-12)
    band = 10 * np.log10(seg_mean(F["band"], bs, bend) + 1e-12)
    chroma = seg_mean(F["chroma"], bs, bend); chroma /= chroma.sum(1, keepdims=True) + 1e-9
    nb = len(bs)
    # beat-level features for structural novelty
    tim = seg_mean(F["tim"], bi, be)
    onset = np.stack([seg_mean(o_all, bi, be), seg_mean(o_low, bi, be), seg_mean(o_mid, bi, be)], 1)
    beat_feat = np.hstack([tim, ch, onset])
    db_beat = np.arange(dph, len(bi), 4)
    if pickup: db_beat = np.r_[dph - 4, db_beat]  # may be negative: no beat features before track start
    return dict(bpm=60 * FPS / p, contrast=float(contrast), drift_ms=float(drift), downbeat_phase=dph, pickup=bool(pickup),
                beat_feat=beat_feat, db_beat=db_beat, db_f=db_f, db_onset=db_onset, clamped=bool(clamped), rms=rms, band=band, chroma=chroma)


def analyze(path, n_cues=8):
    from select_ref import select
    A = analyze_bars(path)
    S = select(A, n_cues)
    S["cues"] = [(nm, round(float(A["db_f"][c] / FPS), 3)) for nm, c in zip(S["names"], S["chosen"])]
    A.update(S)
    return A


if __name__ == "__main__":
    for f in sys.argv[1:]:
        r = analyze(f)
        print(f.split('/')[-1][:40], {k: r[k] for k in ("bpm", "contrast", "drift_ms", "downbeat_phase", "pickup", "edm")})
        for lab, t in r["cues"]: print(f"   {lab:10s} {int(t // 60)}:{t % 60:06.3f}")
