import Foundation
import AVFoundation

public enum AutoCueError: LocalizedError {
    case cannotOpen(String)
    case decodeFailed(String)
    case tooShort
    case unsupportedFile(String)
    case tagWriteFailed(String)
    case verifyFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let s): return "Can't open audio: \(s)"
        case .decodeFailed(let s): return "Decoding failed: \(s)"
        case .tooShort: return "Track is too short to analyze"
        case .unsupportedFile(let s): return s
        case .tagWriteFailed(let s): return "Couldn't write cues: \(s)"
        case .verifyFailed(let s): return "Cues didn't verify after writing: \(s)"
        }
    }
}

enum AudioDecoder {
    /// Decodes any file AVFoundation can read to mono Float32 at `sampleRate`.
    /// AVAudioFile trims MP3 encoder delay, so time 0 is the first real audio sample.
    /// Longest file accepted. Checked from the file header *before* decoding, so a 2-hour mix
    /// can never fill memory.
    static let maxSeconds = 20.0 * 60

    static func decodeMono(url: URL, sampleRate: Double) throws -> [Float] {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw AutoCueError.cannotOpen(error.localizedDescription) }
        let inFmt = file.processingFormat
        guard file.length > 0, inFmt.sampleRate > 0 else { throw AutoCueError.decodeFailed("empty file") }
        if Double(file.length) / inFmt.sampleRate > maxSeconds * 1.02 {
            throw AutoCueError.unsupportedFile("Longer than 20 minutes — AutoCue is made for single tracks, not full mixes")
        }
        let channels = Int(inFmt.channelCount)
        guard channels > 0 else { throw AutoCueError.decodeFailed("no audio channels") }

        // Decode in 1M-frame chunks and downmix as we go: only the mono signal is ever held in memory.
        // (Same per-sample math as downmixing one big buffer.)
        let chunkFrames: AVAudioFrameCount = 1 << 20
        guard let chunk = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: chunkFrames) else {
            throw AutoCueError.decodeFailed("buffer")
        }
        var mono: [Float] = []
        mono.reserveCapacity(Int(file.length) + 4096)
        let scale = 1 / Float(channels)
        while true {
            do { try file.read(into: chunk, frameCount: chunkFrames) } catch {
                if mono.isEmpty { throw AutoCueError.decodeFailed(error.localizedDescription) }
                break // damaged tail: keep what decoded cleanly
            }
            let frames = Int(chunk.frameLength)
            if frames == 0 { break }
            guard let chData = chunk.floatChannelData else { throw AutoCueError.decodeFailed("no PCM data") }
            let start = mono.count
            mono.append(contentsOf: repeatElement(0, count: frames))
            mono.withUnsafeMutableBufferPointer { m in
                for c in 0..<channels {
                    let src = chData[c]
                    for i in 0..<frames { m[start + i] += src[i] * scale }
                }
            }
            if Double(mono.count) / inFmt.sampleRate > maxSeconds * 1.02 {
                throw AutoCueError.unsupportedFile("Longer than 20 minutes — AutoCue is made for single tracks, not full mixes")
            }
        }
        let frames = mono.count
        guard frames > 0 else { throw AutoCueError.decodeFailed("empty file") }
        if abs(inFmt.sampleRate - sampleRate) < 0.5 { return mono }

        // Resample with AVAudioConverter.
        guard let monoFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inFmt.sampleRate, channels: 1, interleaved: false),
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let monoBuf = AVAudioPCMBuffer(pcmFormat: monoFmt, frameCapacity: AVAudioFrameCount(frames)),
              let conv = AVAudioConverter(from: monoFmt, to: outFmt) else {
            throw AutoCueError.decodeFailed("resampler setup")
        }
        monoBuf.frameLength = AVAudioFrameCount(frames)
        mono.withUnsafeBufferPointer { src in
            monoBuf.floatChannelData![0].update(from: src.baseAddress!, count: frames)
        }
        mono = [] // release the native-rate copy before resampling
        conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let outCap = AVAudioFrameCount(Double(frames) * sampleRate / inFmt.sampleRate) + 8192
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap) else {
            throw AutoCueError.decodeFailed("output buffer")
        }
        var fed = false
        var convError: NSError?
        let status = conv.convert(to: outBuf, error: &convError) { _, inputStatus in
            if fed {
                inputStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return monoBuf
        }
        if status == .error {
            throw AutoCueError.decodeFailed(convError?.localizedDescription ?? "sample-rate conversion")
        }
        return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
    }
}
