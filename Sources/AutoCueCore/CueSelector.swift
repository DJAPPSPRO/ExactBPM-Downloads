import Foundation

public struct HotCue: Identifiable, Hashable, Sendable, Codable {
    public var id: Int { index }
    /// 0-based pad slot.
    public var index: Int
    public var name: String
    public var milliseconds: Int
    public var color: UInt32
    /// Bar number counted from the first downbeat of the track (1-based, for display).
    public var bar: Int

    public init(index: Int, name: String, milliseconds: Int, color: UInt32, bar: Int) {
        self.index = index; self.name = name; self.milliseconds = milliseconds; self.color = color; self.bar = bar
    }

    public var timeString: String {
        let s = Double(milliseconds) / 1000
        return String(format: "%d:%06.3f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }
}

/// Song parts and their fixed colors. One color per kind of part, the same on every track.
public enum CueColors {
    public struct Part: Hashable, Sendable {
        public let name: String
        public let color: UInt32
        public let meaning: String
    }

    public static let parts: [Part] = [
        Part(name: "Intro", color: 0x00CC00, meaning: "Start of the track — mix in here"),
        Part(name: "Verse", color: 0x0000CC, meaning: "Vocal / rap section"),
        Part(name: "Pre-Chorus", color: 0x00CCCC, meaning: "Lead-in to the chorus"),
        Part(name: "Chorus", color: 0xCC0000, meaning: "Main hook of a song"),
        Part(name: "Build", color: 0xCCCC00, meaning: "Tension rising into a drop"),
        Part(name: "Drop", color: 0xCC0000, meaning: "Full energy, bass in"),
        Part(name: "Hook", color: 0xCC00CC, meaning: "New phrase while energy stays high"),
        Part(name: "Break", color: 0x8800CC, meaning: "Short dip in energy"),
        Part(name: "Breakdown", color: 0x8800CC, meaning: "Long stripped-back section"),
        Part(name: "Bridge", color: 0x0088CC, meaning: "One-time different section in a song"),
        Part(name: "Outro", color: 0xCC8800, meaning: "Ending — mix out here"),
    ]

    /// The song part a cue name refers to ("Drop 2" → Drop), if any.
    public static func part(for label: String) -> Part? {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        var base = trimmed
        if let last = trimmed.split(separator: " ").last, Int(last) != nil {
            base = trimmed.split(separator: " ").dropLast().joined(separator: " ")
        }
        return parts.first { $0.name.caseInsensitiveCompare(base) == .orderedSame }
    }

    public static func color(for label: String) -> UInt32 {
        part(for: label)?.color ?? 0x888888
    }
}

public struct CueSelection: Sendable {
    public let cues: [HotCue]
    public let style: String // "Club" or "Song"
}

/// Picks phrase/section starts and names them. Mirrors select_ref.py.
public enum CueSelector {
    public static func select(_ A: TrackAnalysis, count nCues: Int = 8) -> CueSelection {
        // Needs the full analysis (a slim copy has no per-beat features).
        guard !A.isSlim, !A.rms.isEmpty, A.downbeatOnset.count == A.rms.count else {
            return CueSelection(cues: [], style: "")
        }
        let rms = A.rms, band = A.band, chroma = A.chroma
        let nb = rms.count
        let med = Stats.median(rms)

        // 1. music region
        let thr = max(med - 35, -60.0)
        let loud = (0..<nb).filter { rms[$0] > thr }
        var first = loud.first ?? 0
        // First cue = the absolute earliest real downbeat of the track.
        // Take the first non-clamped bar that is above the silence floor. No onset threshold.
        if !loud.isEmpty {
            for i in loud {
                if i == 0 && A.firstBarClamped { continue }
                first = i
                break
            }
        }
        var endBar = ((0..<nb).last { rms[$0] > med - 8 } ?? (nb - 1)) + 1
        var fade = endBar
        while fade - 1 > first + 8 && rms[fade - 1] <= rms[fade - 2] - 1.0 { fade -= 1 }
        endBar = fade

        // Very short or odd material: fall back to evenly spaced 8-bar phrases.
        if endBar - first < 24 {
            return fallback(A, first: first, endBar: max(endBar, first + 1), count: nCues)
        }

        let inten = (0..<nb).map { 0.5 * rms[$0] + 0.5 * band[$0][0] }
        let F: [[Double]] = (0..<nb).map { [rms[$0]] + band[$0] }
        let full = F.map { Stats.mean($0) }

        // 2. spectral jump over 4-bar windows
        var J = [Double](repeating: 0, count: nb)
        for i in (first + 1)..<endBar {
            let a0 = max(first, i - 4), b1 = min(endBar, i + 4)
            var s = 0.0
            for d in 0..<6 {
                let bef = Stats.mean((a0..<i).map { F[$0][d] })
                let aft = Stats.mean((i..<b1).map { F[$0][d] })
                s += abs(aft - bef)
            }
            J[i] = s / 6
        }

        // 3. structural novelty on a beat-level self-similarity matrix
        let nov = beatNovelty(A, barCount: nb)

        // Boost spectral jumps and add a strong energy-rise term so drops, builds and
        // other important section starts rank higher.
        var rise = [Double](repeating: 0, count: nb)
        for i in (first + 1)..<endBar {
            let a0 = max(first, i - 4), b1 = min(endBar, i + 4)
            let bef = Stats.mean(inten[a0..<i])
            let aft = Stats.mean(inten[i..<b1])
            rise[i] = max(0, aft - bef)
        }
        let novMax = (nov.max() ?? 0) + 1e-9
        let jDen = max(J.max() ?? 0, 4.0)
        let rMax = (rise.max() ?? 0) + 1e-9
        var score = [Double](repeating: 0, count: nb)
        for i in 0..<nb { score[i] = nov[i] / novMax + 1.4 * J[i] / jDen + 1.2 * rise[i] / rMax }
        for i in 0...min(first, nb - 1) { score[i] = 0 }
        for i in endBar..<nb { score[i] = 0 }

        let bassMusic = Array(band[first..<endBar].map { $0[0] })
        let club = Stats.percentile(bassMusic, 90) - Stats.percentile(bassMusic, 10) > 8

        // 4. phrase offset
        var offs = [Double](repeating: 0, count: 4)
        for i in 0..<nb { offs[i % 4] += score[i] * score[i] }
        let poff = Stats.argmax(offs)
        let offW = club ? 0.7 : 1.0
        var sw = [Double](repeating: 0, count: nb)
        for i in 0..<nb {
            let onPhrase = BeatAnalyzer.pyModInt(i - poff, 4) == 0
            let on8 = BeatAnalyzer.pyModInt(i - poff, 8) == 0
            sw[i] = score[i] * (onPhrase ? 1.0 : offW) * ((on8 && offW < 1) ? 1.1 : 1.0)
        }
        let smax = (sw.max() ?? 0) + 1e-9

        // 5. outro
        var outro: Int? = nil
        var bestV = 0.0
        let oLo = max(first + 8, endBar - 32)
        if oLo < endBar - 3 {
            for b in oLo..<(endBar - 3) {
                if sw[b] < 0.2 * smax { continue }
                let before = Stats.mean(inten[max(first, b - 8)..<b])
                let after = Array(inten[b..<endBar])
                var roll = after[0]
                if after.count > 1 {
                    roll = -Double.infinity
                    for j in 0..<(after.count - 1) { roll = max(roll, 0.5 * (after[j] + after[j + 1])) }
                }
                let am = Stats.mean(after)
                if am < before - 1.0 && roll <= before - 0.25 {
                    let v = sw[b] * (before - am)
                    if v > bestV { bestV = v; outro = b }
                }
            }
        }
        let outroBar: Int = {
            if let o = outro { return o }
            var o = max(first + 8, endBar - 8)
            o -= BeatAnalyzer.pyModInt(o - poff, 4)
            return o
        }()

        // 6. middle cues, strongest first
        var chosen = [first, outroBar]
        let order = (0..<nb).sorted { sw[$0] != sw[$1] ? sw[$0] > sw[$1] : $0 < $1 }
        // Pass 1: strong phrase-aligned candidates (on 4-bar phrase lines) at least 4 bars apart
        for i in order {
            if chosen.count >= nCues { break }
            if i <= first || i >= outroBar || sw[i] < 0.05 * smax { continue }
            if BeatAnalyzer.pyModInt(i - poff, 4) == 0 && chosen.allSatisfy({ abs(i - $0) >= 4 }) {
                chosen.append(i)
            }
        }
        // Pass 2: non-phrase aligned candidates if needed
        if chosen.count < nCues {
            for i in order {
                if chosen.count >= nCues { break }
                if i <= first || i >= outroBar || sw[i] < 0.05 * smax { continue }
                if chosen.allSatisfy({ abs(i - $0) >= 4 }) {
                    chosen.append(i)
                }
            }
        }
        // Pass 3: fallback fill if still under nCues
        if chosen.count < nCues {
            for i in stride(from: first + 4, to: outroBar, by: 4) {
                if chosen.count >= nCues { break }
                if chosen.allSatisfy({ abs(i - $0) >= 2 }) {
                    chosen.append(i)
                }
            }
        }
        chosen.sort()
        chosen = Array(Set(chosen)).sorted()

        // 7. labels
        let spans: [(Int, Int)] = chosen.indices.map { j in (chosen[j], j + 1 < chosen.count ? chosen[j + 1] : endBar) }
        let lev = spans.map { (a, b) in Stats.mean(full[a..<max(a + 1, min(b, a + 4))]) }
        let bass = spans.map { (a, b) in Stats.mean((a..<max(a + 1, min(b, a + 4))).map { band[$0][0] }) }
        let hi = Stats.percentile(Array(full[first..<endBar]), 80)
        let bassHi = Stats.percentile(bassMusic, 80)
        var L = [String](repeating: "", count: spans.count)
        L[0] = "Intro"
        if spans.count > 1 { L[spans.count - 1] = "Outro" }
        let mid = spans.count > 2 ? Array(1..<(spans.count - 1)) : []

        if club {
            let high = spans.indices.map { lev[$0] >= hi - 3 && bass[$0] >= bassHi - 4 }
            var seenDrop = false
            for j in mid {
                let nxtHigh = j + 1 < spans.count - 1 ? high[j + 1] : false
                let a = spans[j].0
                let dip = a > first ? (full[max(first, a - 4)..<a].min() ?? 0) < hi - 2 : true
                if high[j] {
                    L[j] = (!high[j - 1] || dip) ? "Drop" : "Hook"
                    seenDrop = true
                } else if nxtHigh && bass[j] < bassHi - 6 && spans[j].1 - spans[j].0 <= 8 {
                    L[j] = "Build"
                } else if high[j - 1] || lev[j] < lev[j - 1] - 3 || (seenDrop && (L[j - 1] == "Drop" || L[j - 1] == "Hook")) {
                    L[j] = spans[j].1 - spans[j].0 >= 16 ? "Breakdown" : "Break"
                } else if !seenDrop {
                    L[j] = "Intro 2"
                } else {
                    L[j] = "Verse"
                }
            }
        } else {
            // songs: group sections that sound alike; the loudest repeating group is the chorus
            let mus = first..<endBar
            let cMean = (0..<12).map { c in Stats.mean(mus.map { chroma[$0][c] }) }
            let cStd = (0..<12).map { c in Stats.std(mus.map { chroma[$0][c] }) }
            let bMean = (0..<5).map { d in Stats.mean(mus.map { band[$0][d] }) }
            let bStd = (0..<5).map { d in Stats.std(mus.map { band[$0][d] }) }
            let V: [[Double]] = spans.map { (a, b) in
                var v: [Double] = []
                for c in 0..<12 { v.append((Stats.mean((a..<b).map { chroma[$0][c] }) - cMean[c]) / (cStd[c] + 1e-9)) }
                for d in 0..<5 { v.append((Stats.mean((a..<b).map { band[$0][d] }) - bMean[d]) / (bStd[d] + 1e-9)) }
                let nrm = sqrt(v.reduce(0) { $0 + $1 * $1 }) + 1e-9
                return v.map { $0 / nrm }
            }
            func sim(_ x: Int, _ y: Int) -> Double { zip(V[x], V[y]).reduce(0) { $0 + $1.0 * $1.1 } }
            var cl: [Int: Int] = [:]
            for j in mid {
                cl[j] = j
                for k in mid where k < j && sim(j, k) > 0.5 { cl[j] = cl[k]; break }
            }
            var groupOrder: [Int] = []
            var groups: [Int: [Int]] = [:]
            for j in mid {
                let g = cl[j]!
                if groups[g] == nil { groupOrder.append(g) }
                groups[g, default: []].append(j)
            }
            let rep = groupOrder.compactMap { groups[$0]!.count >= 2 ? groups[$0]! : nil }
                .enumerated()
                .sorted { a, b in
                    let ma = Stats.mean(a.element.map { lev[$0] }), mb = Stats.mean(b.element.map { lev[$0] })
                    return ma != mb ? ma > mb : a.offset < b.offset
                }
                .map { $0.element }
            let chorus = Set(rep.first ?? [])
            let verse = Set(rep.count > 1 ? rep[1] : [])
            for j in mid {
                if chorus.contains(j) { L[j] = "Chorus" }
                else if verse.contains(j) { L[j] = "Verse" }
                else if Double(j) > Double(spans.count) / 2 && !L.contains("Bridge") { L[j] = "Bridge" }
                else { L[j] = "Verse" }
            }
            // a short section leading straight into a chorus is the pre-chorus
            for j in mid where L[j] == "Verse" && j > 1 && j + 1 < spans.count && L[j + 1] == "Chorus"
                && spans[j].1 - spans[j].0 <= 8 {
                L[j] = "Pre-Chorus"
            }
        }

        // number repeated labels: Drop 1, Drop 2 ...
        var totals: [String: Int] = [:]
        for l in L { totals[l, default: 0] += 1 }
        var seen: [String: Int] = [:]
        var cues: [HotCue] = []
        for (j, c) in chosen.enumerated() {
            let l = L[j]
            seen[l, default: 0] += 1
            let name = (totals[l]! == 1 || l == "Intro" || l == "Outro") ? l : "\(l) \(seen[l]!)"
            let ms = max(0, Int((A.barStartTime(c) * 1000).rounded()))
            cues.append(HotCue(index: j, name: name, milliseconds: ms, color: CueColors.color(for: l), bar: c + 1))
        }
        return CueSelection(cues: cues, style: club ? "Club" : "Song")
    }

    static func beatNovelty(_ A: TrackAnalysis, barCount nb: Int) -> [Double] {
        let B = A.beatFeatures
        let nbt = B.count
        let dim = B[0].count
        // z-score each feature
        var Z = B
        for d in 0..<dim {
            let col = B.map { $0[d] }
            let m = Stats.mean(col), s = Stats.std(col) + 1e-9
            for t in 0..<nbt { Z[t][d] = (B[t][d] - m) / s }
        }
        // centered 4-beat context
        let ctx = [-2, -1, 0, 1]
        let X: [[Double]] = (0..<nbt).map { t in
            var row: [Double] = []
            row.reserveCapacity(dim * 4)
            for k in ctx { row += Z[min(max(t + k, 0), nbt - 1)] }
            return row
        }
        // Pairwise distances. Only the upper triangle is stored (half the memory of the full matrix),
        // plus a 32-beat band around the diagonal, which is all the novelty kernel ever reads.
        // Every value is computed exactly as before, so results are identical.
        let w = dim * 4
        var flat = [Double](repeating: 0, count: nbt * w)
        for t in 0..<nbt { for k in 0..<w { flat[t * w + k] = X[t][k] } }
        let bandW = 32
        var bandD = [Double](repeating: 0, count: nbt * bandW) // bandD[i*bandW + o] = dist(i, i+o)
        var upper = [Double]()
        upper.reserveCapacity(nbt * (nbt - 1) / 2)
        flat.withUnsafeBufferPointer { fp in
            for i in 0..<nbt {
                for j in (i + 1)..<max(i + 1, nbt) {
                    var s = 0.0
                    let xi = fp.baseAddress! + i * w, xj = fp.baseAddress! + j * w
                    for k in 0..<w { let d = xi[k] - xj[k]; s += d * d }
                    upper.append(s)
                    if j - i < bandW { bandD[i * bandW + (j - i)] = s }
                }
            }
        }
        // Median of the full n×n matrix = n zeros (diagonal) + every off-diagonal value twice.
        upper.sort()
        let total = nbt * nbt
        func fullSorted(_ p: Int) -> Double { p < nbt ? 0 : upper[(p - nbt) / 2] }
        let medFull = total % 2 == 1 ? fullSorted(total / 2) : 0.5 * (fullSorted(total / 2 - 1) + fullSorted(total / 2))
        upper = [] // free
        let medD = medFull + 1e-9
        var bandS = [Double](repeating: 0, count: nbt * bandW)
        for i in 0..<bandS.count { bandS[i] = exp(-bandD[i] / medD) }
        func S(_ i: Int, _ j: Int) -> Double { i <= j ? bandS[i * bandW + (j - i)] : bandS[j * bandW + (i - j)] }
        var nbBeat = [Double](repeating: 0, count: nbt)
        for K in [8, 16] where nbt > 2 * K {
            for t in K..<(nbt - K) {
                var same = 0.0, cross = 0.0
                for i in (t - K)..<(t + K) {
                    for j in (t - K)..<(t + K) {
                        let v = S(i, j)
                        if (i < t) == (j < t) { same += v } else { cross += v }
                    }
                }
                nbBeat[t] += (same - cross) / Double(4 * K * K)
            }
        }
        nbBeat = nbBeat.map { max($0, 0) }
        var nov = [Double](repeating: 0, count: nb)
        for (i, d) in A.downbeatBeatIndex.prefix(nb).enumerated() {
            let lo = max(0, d - 2), hi = min(nbt, d + 2)
            if hi > lo { nov[i] = nbBeat[lo..<hi].max() ?? 0 }
        }
        return nov
    }

    static func fallback(_ A: TrackAnalysis, first: Int, endBar: Int, count: Int) -> CueSelection {
        var cues: [HotCue] = []
        var b = first
        while cues.count < count && b < A.barCount {
            let name = cues.isEmpty ? "Intro" : "Phrase \(cues.count + 1)"
            cues.append(HotCue(index: cues.count, name: name, milliseconds: max(0, Int((A.barStartTime(b) * 1000).rounded())),
                               color: cues.isEmpty ? 0x00CC00 : 0x888888, bar: b + 1))
            b += 8
        }
        return CueSelection(cues: cues, style: "Phrases")
    }
}
