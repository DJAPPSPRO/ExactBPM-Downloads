import Foundation
import Accelerate

/// Everything the cue selector needs, measured from the audio.
public struct TrackAnalysis: Sendable, Codable {
    public let duration: Double
    public let bpm: Double
    /// Peak-to-mean ratio of the beat-folded onset curve. Below ~3 the grid is unreliable.
    public let gridContrast: Double
    /// How far the beat phase wanders across the track (ms). Large values = tempo drift / live drums.
    public let driftMs: Double
    public let downbeatPhase: Int
    public let pickupBar: Bool
    let fps: Double
    /// Bar start positions in analysis frames (bar 0 may be an extrapolated pickup bar).
    let downbeatFrames: [Double]
    /// Per-bar features.
    let rms: [Double]
    let band: [[Double]]   // 5 bands, dB
    let chroma: [[Double]] // 12 pitch classes, normalized
    /// Per-beat features for structural novelty, and the beat index of each bar's downbeat.
    let beatFeatures: [[Double]]
    let downbeatBeatIndex: [Int]
    /// Onset strength right at each downbeat — is there an actual hit on beat 1?
    let downbeatOnset: [Double]
    /// True when bar 0 is an extrapolated pickup bar that starts before the file does.
    let firstBarClamped: Bool

    public var barCount: Int { rms.count }
    public var barLevels: [Double] { rms }
    public func barStartTime(_ bar: Int) -> Double { downbeatFrames[bar] / fps }

    public var isReliable: Bool { gridContrast >= 3 && driftMs <= 40 }

    /// A lightweight copy for keeping in the track list: only what the screen needs (bar levels,
    /// grid, BPM). The heavy per-beat features are dropped; they live in the analysis cache.
    public func slim() -> TrackAnalysis {
        TrackAnalysis(duration: duration, bpm: bpm, gridContrast: gridContrast, driftMs: driftMs,
                      downbeatPhase: downbeatPhase, pickupBar: pickupBar, fps: fps, downbeatFrames: downbeatFrames,
                      rms: rms, band: [], chroma: [], beatFeatures: [], downbeatBeatIndex: [],
                      downbeatOnset: [], firstBarClamped: firstBarClamped)
    }

    public var isSlim: Bool { beatFeatures.isEmpty }

    /// Seconds per beat / per bar on the detected grid.
    public var beatSeconds: Double { 60 / bpm }
    public var barSeconds: Double { 240 / bpm }

    /// A real (non-extrapolated) downbeat used as the grid anchor.
    private var anchorIndex: Int { pickupBar && downbeatFrames.count > 1 ? 1 : 0 }
    private var anchorSeconds: Double { downbeatFrames[anchorIndex] / fps }

    /// Nearest beat on the grid to `ms`, clamped inside the track.
    public func snapToBeat(ms: Double) -> Int {
        let t = ms / 1000
        var n = ((t - anchorSeconds) / beatSeconds).rounded()
        var s = anchorSeconds + n * beatSeconds
        while s < 0 { n += 1; s = anchorSeconds + n * beatSeconds }
        while s > duration - 0.05 && s > 0 { n -= 1; s = anchorSeconds + n * beatSeconds }
        return max(0, Int((s * 1000).rounded()))
    }

    /// "9" on a downbeat, "9.3" on the 3rd beat of bar 9 (bars counted like the cue list).
    public func barBeat(ms: Int) -> String {
        let beats = Int(((Double(ms) / 1000 - anchorSeconds) / beatSeconds).rounded())
        let barIdx = Int(floor(Double(beats) / 4)) + anchorIndex
        let beat = ((beats % 4) + 4) % 4
        let bar = barIdx + 1
        return beat == 0 ? "\(bar)" : "\(bar).\(beat + 1)"
    }
}

public enum BeatAnalyzer {
    static let sampleRate = 22050.0
    static let nfft = 2048
    static let hop = 128
    static var fps: Double { sampleRate / Double(hop) }

    static let bands: [(Double, Double)] = [(20, 150), (150, 500), (500, 2000), (2000, 6000), (6000, 11000)]

    /// Bump whenever analysis results would change, so cached analyses are recomputed.
    public static let engineVersion = "1.9"

    /// Analyzes a file. Results are cached by the audio content (not the tags), so re-adding a track,
    /// even after its cues were written, is instant and returns exactly the same analysis.
    public static func analyze(url: URL, useCache: Bool = true) throws -> TrackAnalysis {
        try analyzeKeyed(url: url, useCache: useCache).analysis
    }

    /// Same as `analyze`, also returning the cache key so the full analysis can be reloaded later.
    public static func analyzeKeyed(url: URL, useCache: Bool = true) throws -> (analysis: TrackAnalysis, key: String?) {
        let key = AnalysisCache.key(for: url)
        if useCache, let key, let cached = AnalysisCache.load(key) { return (cached, key) }
        let y = try AudioDecoder.decodeMono(url: url, sampleRate: sampleRate)
        let a = try analyze(samples: y)
        if let key { AnalysisCache.save(a, key: key) }
        return (a, key)
    }

    // MARK: - frame features

    struct FrameFeatures {
        var n = 0
        var fall: [Double] = [], flow: [Double] = [], fmid: [Double] = [], pow: [Double] = []
        var band: [Double] = []   // n * 5
        var chroma: [Double] = [] // n * 12
        var tim: [Double] = []    // n * 16
    }

    static func binRange(_ lo: Double, _ hi: Double, strictLower: Bool = false) -> Range<Int> {
        let bw = sampleRate / Double(nfft)
        let nb = nfft / 2 + 1
        let a = strictLower ? Int(floor(lo / bw)) + 1 : Int(ceil(lo / bw))
        let b = Int(ceil(hi / bw))
        return min(max(a, 0), nb)..<min(max(b, 0), nb)
    }

    static func frameFeatures(_ y: [Float]) -> FrameFeatures {
        let nb = nfft / 2 + 1
        let bw = sampleRate / Double(nfft)
        var pad = [Float](repeating: 0, count: nfft / 2)
        pad.append(contentsOf: y)
        pad.append(contentsOf: [Float](repeating: 0, count: nfft / 2))
        let n = 1 + (pad.count - nfft) / hop

        let bandRanges = bands.map { binRange($0.0, $0.1) }
        let lowRange = binRange(0, 150)
        let midRange = binRange(150, 4000)
        let chromaRange = binRange(60, 4000, strictLower: true)
        var pitchClass = [Int](repeating: -1, count: nb)
        for k in chromaRange {
            let f = Double(k) * bw
            let p = (12 * log2(f / 440.0)).rounded(.toNearestOrEven)
            pitchClass[k] = ((Int(p) % 12) + 12) % 12
        }
        var timRanges: [Range<Int>] = []
        for i in 0..<16 {
            let lo = 40 * pow(10000.0 / 40, Double(i) / 16), hi = 40 * pow(10000.0 / 40, Double(i + 1) / 16)
            timRanges.append(binRange(lo, hi))
        }

        // Frames are independent apart from the previous frame's log spectrum, so the track is cut into
        // chunks that run on all CPU cores. Each chunk recomputes the one frame before it, so every value
        // is computed exactly as in the single-threaded loop (same operations, same order).
        var fall = [Double](repeating: 0, count: n), flow = fall, fmid = fall, powA = fall
        var bandA = [Double](repeating: 0, count: n * 5)
        var chromaA = [Double](repeating: 0, count: n * 12)
        var timA = [Double](repeating: 0, count: n * 16)
        let chunk = 1024
        let chunks = (n + chunk - 1) / chunk

        pad.withUnsafeBufferPointer { padPtr in
        fall.withUnsafeMutableBufferPointer { fallP in
        flow.withUnsafeMutableBufferPointer { flowP in
        fmid.withUnsafeMutableBufferPointer { fmidP in
        powA.withUnsafeMutableBufferPointer { powP in
        bandA.withUnsafeMutableBufferPointer { bandP in
        chromaA.withUnsafeMutableBufferPointer { chromaP in
        timA.withUnsafeMutableBufferPointer { timP in
            let fallB = fallP.baseAddress!, flowB = flowP.baseAddress!, fmidB = fmidP.baseAddress!, powB = powP.baseAddress!
            let bandB = bandP.baseAddress!, chromaB = chromaP.baseAddress!, timB = timP.baseAddress!
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                let spec = SpectrumAnalyzer(size: nfft)
                var mags = [Float](repeating: 0, count: nb)
                var L = [Double](repeating: 0, count: nb)
                var prevL = [Double](repeating: 0, count: nb)
                var m2 = [Double](repeating: 0, count: nb)
                let s = c * chunk, e = min(n, s + chunk)

                func spectrum(_ t: Int) {
                    mags.withUnsafeMutableBufferPointer { mp in
                        spec.magnitudes(frame: padPtr.baseAddress! + t * hop, into: mp.baseAddress!)
                    }
                }
                if s > 0 { // log spectrum of the frame just before this chunk
                    spectrum(s - 1)
                    for k in 0..<nb { prevL[k] = log1p(100 * Double(mags[k])) }
                }
                for t in s..<e {
                    spectrum(t)
                    var powSum = 0.0
                    for k in 0..<nb {
                        let m = Double(mags[k])
                        L[k] = log1p(100 * m)
                        m2[k] = m * m
                        powSum += m2[k]
                    }
                    if t == 0 { prevL = L }
                    var fa = 0.0, fl = 0.0, fm = 0.0
                    for k in 0..<nb {
                        let d = L[k] - prevL[k]
                        if d > 0 {
                            fa += d
                            if lowRange.contains(k) { fl += d }
                            if midRange.contains(k) { fm += d }
                        }
                    }
                    fallB[t] = fa; flowB[t] = fl; fmidB[t] = fm
                    powB[t] = powSum / Double(nb)
                    for (b, r) in bandRanges.enumerated() where !r.isEmpty {
                        var sum = 0.0
                        for k in r { sum += m2[k] }
                        bandB[t * 5 + b] = sum / Double(r.count)
                    }
                    for k in chromaRange { chromaB[t * 12 + pitchClass[k]] += Double(mags[k]) }
                    for (b, r) in timRanges.enumerated() where !r.isEmpty {
                        var sum = 0.0
                        for k in r { sum += L[k] }
                        timB[t * 16 + b] = sum / Double(r.count)
                    }
                    swap(&prevL, &L)
                }
            }
        }}}}}}}}

        var F = FrameFeatures()
        F.n = n
        F.fall = fall; F.flow = flow; F.fmid = fmid; F.pow = powA
        F.band = bandA; F.chroma = chromaA; F.tim = timA
        return F
    }

    static func normFlux(_ x: [Double]) -> [Double] {
        let ma = Stats.movingAverage(x, window: 64)
        var out = zip(x, ma).map { max($0 - $1, 0) }
        let mx = (out.max() ?? 0) + 1e-9
        for i in out.indices { out[i] /= mx }
        return out
    }

    /// Mean of rows [a, b) of a flat (n x dim) matrix; a single row when the range is empty.
    static func segMean(_ flat: [Double], dim: Int, n: Int, _ a: Int, _ b: Int) -> [Double] {
        var out = [Double](repeating: 0, count: dim)
        if b > a {
            for r in a..<b { for d in 0..<dim { out[d] += flat[r * dim + d] } }
            for d in 0..<dim { out[d] /= Double(b - a) }
        } else {
            let r = min(a, n - 1)
            for d in 0..<dim { out[d] = flat[r * dim + d] }
        }
        return out
    }

    // MARK: - tempo and grid

    static func estimateTempo(_ o: [Double]) -> Double {
        let m = Stats.mean(o)
        let oc = o.map { $0 - m }
        let maxLag = Int(4 * 60 * fps / 60) + 4
        var ac = [Double](repeating: 0, count: maxLag)
        oc.withUnsafeBufferPointer { p in
            for l in 0..<maxLag where l < oc.count {
                var r = 0.0
                vDSP_dotprD(p.baseAddress!, 1, p.baseAddress! + l, 1, &r, vDSP_Length(oc.count - l))
                ac[l] = r
            }
        }
        var bestBpm = 120.0, best = -Double.infinity
        for i in 0..<2800 {
            let bpm = 60 + 0.05 * Double(i)
            let lag = 60 * fps / bpm
            let sc = Stats.interp(ac, lag) + 0.5 * Stats.interp(ac, 2 * lag) + 0.25 * Stats.interp(ac, 4 * lag)
            let prior = exp(-0.5 * pow(log2(bpm / 115.0) / 0.9, 2))
            if sc * prior > best { best = sc * prior; bestBpm = bpm }
        }
        return bestBpm
    }

    static func fold(_ o: ArraySlice<Double>, period p: Double, bins: Int = 64) -> [Double] {
        var h = [Double](repeating: 0, count: bins)
        var t = 0.0
        for v in o {
            let b = min(Int(fmod(t, p) / p * Double(bins)), bins - 1)
            h[b] += v
            t += 1
        }
        return h
    }

    static func refineGrid(_ o: [Double], bpm: Double) -> (period: Double, phase: Double, contrast: Double, driftMs: Double) {
        let n = o.count
        let per = 60 * fps / bpm
        var bestC = -1.0, p = per, ph = 0.0
        for i in 0...200 {
            let pp = per * 0.995 + (per * 1.005 - per * 0.995) * Double(i) / 200
            let h = fold(o[...], period: pp)
            let c = (h.max() ?? 0) / (Stats.mean(h) + 1e-12)
            if c > bestC { bestC = c; p = pp; ph = (Double(Stats.argmax(h)) + 0.5) * pp / 64 }
        }
        // fine search on the raw onset curve
        let kCount = Int(Double(n) / p) + 2
        var bestS = -Double.infinity, bp = p, bph = ph
        for i in 0...20 {
            let p2 = p * 0.9995 + (p * 1.0005 - p * 0.9995) * Double(i) / 20
            var ph2 = ph - p / 64
            let end = ph + p / 64 + 1e-9
            while ph2 < end {
                var s = 0.0
                for k in 0..<kCount {
                    let pos = ph2 + Double(k) * p2
                    if pos >= Double(n - 1) { break }
                    s += Stats.interp(o, pos)
                }
                if s > bestS { bestS = s; bp = p2; bph = ph2 }
                ph2 += 0.1
            }
        }
        p = bp; ph = bph
        // steadiness: fold each quarter and compare the peak phase
        let q = n / 4
        var peaks: [Double] = []
        for i in 0..<4 {
            let h = fold(o[(i * q)..<((i + 1) * q)], period: p)
            let off = fmod(Double(i * q), p)
            peaks.append(pyMod((Double(Stats.argmax(h)) + 0.5) * p / 64 + off, p))
        }
        let d = peaks.map { pyMod($0 - peaks[0] + p / 2, p) - p / 2 }
        let drift = ((d.max() ?? 0) - (d.min() ?? 0)) / fps * 1000
        return (p, pyMod(ph, p), bestC, drift)
    }

    /// Python-style modulo (result has the sign of the divisor).
    static func pyMod(_ a: Double, _ b: Double) -> Double {
        let r = fmod(a, b)
        return r < 0 ? r + b : r
    }

    // MARK: - full analysis

    public static func analyze(samples y: [Float]) throws -> TrackAnalysis {
        let duration = Double(y.count) / sampleRate
        guard duration > 20 else { throw AutoCueError.tooShort }
        guard duration < 20 * 60 else {
            throw AutoCueError.unsupportedFile("Longer than 20 minutes — AutoCue is made for single tracks, not full mixes")
        }
        let F = frameFeatures(y)
        let n = F.n
        let oAll = normFlux(F.fall), oLow = normFlux(F.flow), oMid = normFlux(F.fmid)
        var o = [Double](repeating: 0, count: n)
        for i in 0..<n { o[i] = 0.5 * oAll[i] + 0.3 * oLow[i] + 0.2 * oMid[i] }

        let bpm0 = estimateTempo(o)
        let (p, ph, contrast, drift) = refineGrid(o, bpm: bpm0)

        var beatsF: [Double] = []
        let count = Int((Double(n) - ph) / p) + 1
        for k in 0..<count {
            let b = ph + Double(k) * p
            if b < Double(n) { beatsF.append(b) }
        }
        guard beatsF.count >= 32 else { throw AutoCueError.tooShort }
        let bi = beatsF.map { Int($0) }
        let be = Array(bi.dropFirst()) + [n]
        let nbt = bi.count

        // downbeat phase
        let lowMax = Stats.maxFilter(oLow, width: 5)
        let lowAt = beatsF.map { Stats.interp(lowMax, $0) }
        var ch: [[Double]] = []
        var bdb: [Double] = []
        for j in 0..<nbt {
            var c = segMean(F.chroma, dim: 12, n: n, bi[j], be[j])
            let s = c.reduce(0, +) + 1e-9
            c = c.map { $0 / s }
            ch.append(c)
            bdb.append(10 * log10(segMean(F.pow, dim: 1, n: n, bi[j], be[j])[0] + 1e-12))
        }
        var hc = [Double](repeating: 0, count: nbt), ed = hc
        for j in 1..<nbt {
            var s = 0.0
            for c in 0..<12 { s += abs(ch[j][c] - ch[j - 1][c]) }
            hc[j] = s
            ed[j] = abs(bdb[j] - bdb[j - 1])
        }
        func z(_ v: [Double], _ k: Int) -> Double {
            var on: [Double] = [], off: [Double] = []
            for (i, x) in v.enumerated() { if pyModInt(i - k, 4) == 0 { on.append(x) } else { off.append(x) } }
            return (Stats.mean(on) - Stats.mean(off)) / (Stats.std(v) + 1e-9)
        }
        // Heavily weight the low-frequency (kick) onset so the phase locks to the true downbeat.
        var phaseScores: [Double] = []
        for k in 0..<4 { phaseScores.append(2.5 * z(lowAt, k) + z(hc, k) + 0.5 * z(ed, k)) }
        var dph = Stats.argmax(phaseScores)

        // Safety: if the top two phases are close, prefer the one with the strongest absolute early kicks.
        let sortedPhases = phaseScores.enumerated().sorted { $0.element > $1.element }
        if sortedPhases.count >= 2 && sortedPhases[0].element - sortedPhases[1].element < 0.15 {
            let early = min(32, lowAt.count)
            var bestKick = -Double.infinity, bestK = dph
            for k in 0..<4 {
                var s = 0.0
                for i in stride(from: k, to: early, by: 4) { s += lowAt[i] }
                if s > bestKick { bestKick = s; bestK = k }
            }
            dph = bestK
        }

        var dbF = stride(from: dph, to: nbt, by: 4).map { beatsF[$0] }
        var dbBeat = Array(stride(from: dph, to: nbt, by: 4))
        let barF = 4 * p
        let pickup = dbF[0] - barF >= -0.06 * fps
        let clamped = pickup && dbF[0] - barF < 0
        if pickup {
            dbF.insert(max(0, dbF[0] - barF), at: 0)
            dbBeat.insert(dph - 4, at: 0)
        }
        let onsetPeak = Stats.maxFilter(oAll, width: 7)
        let dbOnset = dbF.map { Stats.interp(onsetPeak, $0) }
        // Move the grid onto the actual attack of each hit (the wide window above reacts ~20 ms early).
        let shift = attackShift(y, downbeatSeconds: dbF.map { $0 / fps })
        dbF = dbF.map { max(0, $0 + shift * fps) }
        let bs = dbF.map { Int($0) }
        let bend = Array(bs.dropFirst()) + [n]
        var rms: [Double] = [], band: [[Double]] = [], chroma: [[Double]] = []
        for j in 0..<bs.count {
            rms.append(10 * log10(segMean(F.pow, dim: 1, n: n, bs[j], bend[j])[0] + 1e-12))
            band.append(segMean(F.band, dim: 5, n: n, bs[j], bend[j]).map { 10 * log10($0 + 1e-12) })
            var c = segMean(F.chroma, dim: 12, n: n, bs[j], bend[j])
            let s = c.reduce(0, +) + 1e-9
            c = c.map { $0 / s }
            chroma.append(c)
        }
        var beatFeat: [[Double]] = []
        for j in 0..<nbt {
            var row = segMean(F.tim, dim: 16, n: n, bi[j], be[j])
            row += ch[j]
            row.append(segMean(oAll, dim: 1, n: n, bi[j], be[j])[0])
            row.append(segMean(oLow, dim: 1, n: n, bi[j], be[j])[0])
            row.append(segMean(oMid, dim: 1, n: n, bi[j], be[j])[0])
            beatFeat.append(row)
        }
        return TrackAnalysis(duration: duration, bpm: 60 * fps / p, gridContrast: contrast, driftMs: drift,
                             downbeatPhase: dph, pickupBar: pickup, fps: fps, downbeatFrames: dbF,
                             rms: rms, band: band, chroma: chroma, beatFeatures: beatFeat, downbeatBeatIndex: dbBeat,
                             downbeatOnset: dbOnset, firstBarClamped: clamped)
    }

    static func pyModInt(_ a: Int, _ b: Int) -> Int { ((a % b) + b) % b }

    /// Seconds to add to the grid so cues sit right on the beat (exactly on the measured attack).
    /// Measures the real attack on every downbeat with an 11.6 ms window and returns the median
    /// offset. Lands exactly on the attack center so every cue is on-beat. Mirrors attack_shift() in engine_ref.py.
    static func attackShift(_ y: [Float], downbeatSeconds: [Double]) -> Double {
        let N = 256, H = 22
        let nb = N / 2 + 1
        let spec = SpectrumAnalyzer(size: N)
        var mags = [Float](repeating: 0, count: nb)
        var prev = [Double](repeating: 0, count: nb)
        var cur = prev
        var offsets: [Double] = []
        let half = Int(0.06 * sampleRate)
        y.withUnsafeBufferPointer { yp in
            for t in downbeatSeconds.dropFirst() {
                let c = Int(t * sampleRate), a = c - half, b = c + half
                if a < 0 || b + N > yp.count { continue }
                var best = -1.0, bestStart = a
                var first = true
                var i = a
                while i < b {
                    mags.withUnsafeMutableBufferPointer { mp in
                        spec.magnitudes(frame: yp.baseAddress! + i, into: mp.baseAddress!)
                    }
                    var flux = 0.0
                    for j in 0..<nb {
                        cur[j] = log1p(1000 * Double(mags[j]))
                        if !first { let d = cur[j] - prev[j]; if d > 0 { flux += d } }
                    }
                    if flux > best { best = flux; bestStart = i }
                    first = false
                    swap(&prev, &cur)
                    i += H
                }
                // Use the center of the peak-flux window as the attack time (high-resolution onset).
                offsets.append((Double(bestStart) + Double(N) / 2) / sampleRate - t)
            }
        }
        guard offsets.count >= 8 else { return 0 }
        // Land exactly on the measured attack (no early bias) so cues are perfect on-beat.
        return min(max(Stats.median(offsets), -0.010), 0.060)
    }
}
