"""Cue selection + labeling (reference for CueSelector.swift)."""
import numpy as np


def pct(x, q):
    return float(np.percentile(x, q))  # linear interpolation, same as Swift helper


def select(A, n_cues=8, debug=False):
    rms, band, chroma = A["rms"], A["band"], A["chroma"]
    nb = len(rms)
    # 1. music region
    thr = max(float(np.median(rms)) - 35, -60.0)
    loud = [i for i in range(nb) if rms[i] > thr]
    # First cue = the absolute earliest real downbeat of the track.
    # Take the first non-clamped bar that is above the silence floor.
    first = loud[0] if loud else 0
    for i in loud:
        if i == 0 and A.get("clamped"): continue
        first = i; break
    body = [i for i in range(nb) if rms[i] > float(np.median(rms)) - 8]
    end_bar = body[-1] + 1
    # trailing fade-out: run of bars each >= 1 dB quieter than the one before
    fade = end_bar
    while fade - 1 > first + 8 and rms[fade - 1] <= rms[fade - 2] - 1.0: fade -= 1
    end_bar = fade
    inten = 0.5 * rms + 0.5 * band[:, 0]
    F = np.hstack([rms[:, None], band])
    # 2. spectral jump + rise (4-bar windows)
    J = np.zeros(nb); R = np.zeros(nb)
    for i in range(first + 1, end_bar):
        a0, b1 = max(first, i - 4), min(end_bar, i + 4)
        bef, aft = F[a0:i].mean(0), F[i:b1].mean(0)
        J[i] = np.abs(aft - bef).mean()
        R[i] = inten[i:b1].mean() - inten[a0:i].mean()
    # 3. structural novelty on a beat-level self-similarity matrix, read at each downbeat
    B = A["beat_feat"]
    Z = (B - B.mean(0)) / (B.std(0) + 1e-9)
    nbt = len(Z)
    Xc = np.hstack([Z[np.clip(np.arange(nbt) + k, 0, nbt - 1)] for k in (-2, -1, 0, 1)])  # centered 4-beat context
    sq = (Xc ** 2).sum(1)
    D = np.maximum(sq[:, None] + sq[None] - 2 * Xc @ Xc.T, 0)
    Sm = np.exp(-D / (float(np.median(D)) + 1e-9))
    nb_beat = np.zeros(nbt)
    for K in (8, 16):
        for t in range(K, nbt - K):
            q = Sm[t - K:t + K, t - K:t + K]
            nb_beat[t] += (q[:K, :K].sum() + q[K:, K:].sum() - q[:K, K:].sum() - q[K:, :K].sum()) / (4 * K * K)
    nb_beat = np.maximum(nb_beat, 0)
    nov = np.zeros(nb)
    for i, d in enumerate(A["db_beat"][:nb]):
        lo, hi_ = max(0, d - 2), min(nbt, d + 2)
        if hi_ > lo: nov[i] = nb_beat[lo:hi_].max()
    score = nov / (nov.max() + 1e-9) + J / max(J.max(), 4.0)
    score[:first + 1] = 0; score[end_bar:] = 0
    mus = slice(first, end_bar)
    edm = pct(band[mus, 0], 90) - pct(band[mus, 0], 10) > 8
    # 4. phrase offset
    offs = [float(sum(score[i] ** 2 for i in range(nb) if (i - o) % 4 == 0)) for o in range(4)]
    poff = int(np.argmax(offs))
    strength = offs[poff] / (sum(offs) + 1e-9)  # 0.25 = no phrase structure, 1.0 = every boundary on the 4-bar grid
    off_w = 0.7 if edm else 1.0  # club tracks are built in 4/8-bar phrases; songs often are not
    sw = np.array([score[i] * (1.0 if (i - poff) % 4 == 0 else off_w) * (1.1 if (i - poff) % 8 == 0 and off_w < 1 else 1.0) for i in range(nb)])
    smax = sw.max() + 1e-9
    # 5. outro: boundary after which energy drops and stays down; else 8 bars before the end
    outro = None; best = 0.0
    for b in range(max(first + 8, end_bar - 32), end_bar - 3):
        if sw[b] < 0.2 * smax: continue
        before = inten[max(first, b - 8):b].mean()
        after = inten[b:end_bar]
        roll = max(after[j:j + 2].mean() for j in range(len(after) - 1)) if len(after) > 1 else after[0]
        if after.mean() < before - 1.0 and roll <= before - 0.25:
            v = sw[b] * (before - after.mean())
            if v > best: best, outro = v, b
    if outro is None:
        outro = max(first + 8, end_bar - 8)
        outro -= (outro - poff) % 4
    # 6. middle cues, greedy
    chosen = [first, outro]
    # Pass 1: strong phrase-aligned candidates (on 4-bar phrase lines) at least 4 bars apart
    for i in np.argsort(-sw, kind="stable"):
        i = int(i)
        if len(chosen) >= n_cues: break
        if i <= first or i >= outro or sw[i] < 0.05 * smax: continue
        if (i - poff) % 4 == 0 and all(abs(i - c) >= 4 for c in chosen):
            chosen.append(i)

    # Pass 2: non-phrase aligned candidates if needed (still at least 4 bars apart)
    if len(chosen) < n_cues:
        for i in np.argsort(-sw, kind="stable"):
            i = int(i)
            if len(chosen) >= n_cues: break
            if i <= first or i >= outro or sw[i] < 0.05 * smax: continue
            if all(abs(i - c) >= 4 for c in chosen):
                chosen.append(i)

    # Pass 3: fallback fill if still under n_cues
    if len(chosen) < n_cues:
        for i in range(first + 4, outro, 4):
            if len(chosen) >= n_cues: break
            if all(abs(i - c) >= 2 for c in chosen):
                chosen.append(i)

    chosen.sort()
    # 7. labels
    spans = [(chosen[j], chosen[j + 1] if j + 1 < len(chosen) else end_bar) for j in range(len(chosen))]
    full = F.mean(1)  # average level across rms + 5 bands (dB)
    lev = np.array([full[a:min(b, a + 4)].mean() for a, b in spans])
    bass = np.array([band[a:min(b, a + 4), 0].mean() for a, b in spans])
    hi = pct(full[mus], 80); bass_hi = pct(band[mus, 0], 80)
    L = ["Intro"] + [""] * (len(spans) - 2) + ["Outro"]
    mid = range(1, len(spans) - 1)
    if edm:
        high = (lev >= hi - 3) & (bass >= bass_hi - 4)
        seen_drop = False
        for j in mid:
            nxt_high = high[j + 1] if j + 1 < len(spans) - 1 else False
            a = spans[j][0]
            dip = full[max(first, a - 4):a].min() < hi - 2 if a > first else True
            if high[j]:
                L[j] = "Drop" if (not high[j - 1] or dip) else "Hook"; seen_drop = True
            elif nxt_high and bass[j] < bass_hi - 6 and spans[j][1] - spans[j][0] <= 8: L[j] = "Build"
            elif high[j - 1] or lev[j] < lev[j - 1] - 3 or seen_drop and L[j - 1] in ("Drop", "Hook"):
                L[j] = "Breakdown" if spans[j][1] - spans[j][0] >= 16 else "Break"
            elif not seen_drop: L[j] = "Intro 2"
            else: L[j] = "Verse"
    else:
        V = np.array([np.r_[(chroma[a:b].mean(0) - chroma[mus].mean(0)) / (chroma[mus].std(0) + 1e-9),
                            (band[a:b].mean(0) - band[mus].mean(0)) / (band[mus].std(0) + 1e-9)] for a, b in spans])
        Vn = V / (np.linalg.norm(V, axis=1, keepdims=True) + 1e-9)
        sim = Vn @ Vn.T
        cl = {}
        for j in mid:
            cl[j] = j
            for k in mid:
                if k < j and sim[j, k] > 0.5: cl[j] = cl[k]; break
        groups = {}
        for j in mid: groups.setdefault(cl[j], []).append(j)
        rep = sorted([g for g in groups.values() if len(g) >= 2], key=lambda g: -lev[g].mean())
        chorus = set(rep[0]) if rep else set()
        verse = set(rep[1]) if len(rep) > 1 else set()
        for j in mid:
            if j in chorus: L[j] = "Chorus"
            elif j in verse: L[j] = "Verse"
            elif j > len(spans) / 2 and "Bridge" not in L: L[j] = "Bridge"
            else: L[j] = "Verse"
        # a short section leading straight into a chorus is the pre-chorus
        for j in mid:
            if L[j] == "Verse" and j + 1 < len(spans) and L[j + 1] == "Chorus" and spans[j][1] - spans[j][0] <= 8 and j > 1:
                L[j] = "Pre-Chorus"
    tot = {l: L.count(l) for l in L}; cnt = {}
    names = []
    for l in L:
        cnt[l] = cnt.get(l, 0) + 1
        names.append(l if tot[l] == 1 or l in ("Intro", "Outro") else f"{l} {cnt[l]}")
    if debug:
        print("   lev", np.round(lev, 1).tolist(), "hi", round(hi, 1))
        top = np.argsort(-sw)[:16]
        print("   strength", round(strength, 2), "poff", poff, "edm", edm, "first", first, "end", end_bar, "top", [(int(i), round(float(sw[i] / smax), 2)) for i in top])
    return dict(chosen=chosen, names=names, edm=bool(edm), phrase_offset=poff)
