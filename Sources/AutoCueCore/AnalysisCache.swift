import Foundation
import CryptoKit

/// On-disk cache of finished analyses, keyed by a SHA-256 of the audio bytes (everything after the
/// ID3 tag) plus the engine version. Writing cues only changes the tag, so the key stays the same.
public enum AnalysisCache {
    static let directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RhythmCore AutoCue/Analysis", isDirectory: true)

    static func key(for url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty else { return nil }
        let start = (try? ID3Tag.parse(data))?.audioStart ?? 0
        guard start < data.count else { return nil }
        var hasher = SHA256()
        hasher.update(data: Data(BeatAnalyzer.engineVersion.utf8))
        hasher.update(data: data[(data.startIndex + start)...])
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func load(_ key: String) -> TrackAnalysis? {
        let file = directory.appendingPathComponent(key + ".plist")
        guard let d = try? Data(contentsOf: file) else { return nil }
        return try? PropertyListDecoder().decode(TrackAnalysis.self, from: d)
    }

    static func save(_ a: TrackAnalysis, key: String) {
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        guard let d = try? enc.encode(a) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? d.write(to: directory.appendingPathComponent(key + ".plist"), options: .atomic)
    }

    /// Deletes every cached analysis. Returns the number of bytes freed.
    @discardableResult
    public static func clear() -> Int64 {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var freed: Int64 = 0
        for f in files {
            freed += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            try? fm.removeItem(at: f)
        }
        return freed
    }
}
