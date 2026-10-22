import Foundation
import Accelerate

// Small numeric helpers. Each mirrors the numpy call used in the Python reference engine.

enum Stats {
    static func mean(_ x: ArraySlice<Double>) -> Double {
        x.isEmpty ? 0 : x.reduce(0, +) / Double(x.count)
    }

    static func mean(_ x: [Double]) -> Double { mean(x[...]) }

    /// Population standard deviation (numpy default, ddof = 0).
    static func std(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return 0 }
        let m = mean(x)
        return sqrt(x.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(x.count))
    }

    /// numpy.median
    static func median(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return 0 }
        let s = x.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : 0.5 * (s[n / 2 - 1] + s[n / 2])
    }

    /// numpy.percentile with linear interpolation.
    static func percentile(_ x: [Double], _ q: Double) -> Double {
        guard !x.isEmpty else { return 0 }
        let s = x.sorted()
        let rank = q / 100 * Double(s.count - 1)
        let lo = Int(floor(rank)), hi = Int(ceil(rank))
        return s[lo] + (s[hi] - s[lo]) * (rank - Double(lo))
    }

    /// numpy.interp on an evenly spaced grid 0..<count (clamped at both ends).
    static func interp(_ arr: [Double], _ pos: Double) -> Double {
        guard !arr.isEmpty else { return 0 }
        if pos <= 0 { return arr[0] }
        let last = arr.count - 1
        if pos >= Double(last) { return arr[last] }
        let i = Int(pos)
        let f = pos - Double(i)
        return arr[i] * (1 - f) + arr[i + 1] * f
    }

    /// Index of the first maximum (numpy.argmax).
    static func argmax(_ x: [Double]) -> Int {
        var best = 0
        for i in 1..<max(x.count, 1) where x[i] > x[best] { best = i }
        return best
    }

    /// Centered moving average with window w; edges average whatever samples exist.
    static func movingAverage(_ x: [Double], window w: Int) -> [Double] {
        let n = x.count
        var c = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { c[i + 1] = c[i] + x[i] }
        let h = w / 2
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let lo = min(max(i - h, 0), n), hi = min(max(i - h + w, 0), n)
            out[i] = hi > lo ? (c[hi] - c[lo]) / Double(hi - lo) : 0
        }
        return out
    }

    /// Running maximum over a window of w samples centered on each index.
    static func maxFilter(_ x: [Double], width w: Int = 5) -> [Double] {
        let h = w / 2, n = x.count
        var out = x
        for i in 0..<n {
            var m = x[i]
            for j in max(0, i - h)...min(n - 1, i + h) where x[j] > m { m = x[j] }
            out[i] = m
        }
        return out
    }
}

/// Real FFT magnitude spectrum identical in scale to numpy `abs(np.fft.rfft(frame * hann))`.
final class SpectrumAnalyzer {
    let n: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]

    init(size: Int) {
        n = size
        log2n = vDSP_Length(log2(Double(size)).rounded())
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        // periodic Hann window, same as the reference implementation
        window = (0..<size).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(size)) }
        windowed = [Float](repeating: 0, count: size)
        real = [Float](repeating: 0, count: size / 2)
        imag = [Float](repeating: 0, count: size / 2)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// `frame` must hold `n` samples. Writes n/2+1 magnitudes into `mags`.
    func magnitudes(frame: UnsafePointer<Float>, into mags: UnsafeMutablePointer<Float>) {
        let half = n / 2
        window.withUnsafeBufferPointer { w in
            windowed.withUnsafeMutableBufferPointer { out in
                vDSP_vmul(frame, 1, w.baseAddress!, 1, out.baseAddress!, 1, vDSP_Length(n))
            }
        }
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // vDSP's packed real FFT is scaled by 2 relative to the mathematical DFT.
                mags[0] = abs(rp[0]) * 0.5
                mags[half] = abs(ip[0]) * 0.5
                for k in 1..<half {
                    mags[k] = sqrt(rp[k] * rp[k] + ip[k] * ip[k]) * 0.5
                }
            }
        }
    }
}
