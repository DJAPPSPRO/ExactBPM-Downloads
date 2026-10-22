import Foundation

/// Full-file backups taken before any file is modified, with a manifest for one-click restore.
public final class BackupManager: @unchecked Sendable {
    public struct Entry: Codable, Hashable {
        public let original: String
        public let backup: String
    }

    public let root: URL
    private let lock = NSLock()

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RhythmCore AutoCue Backups", isDirectory: true)
    }

    /// Creates a new timestamped session folder.
    public func newSession() throws -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let dir = root.appendingPathComponent(f.string(from: Date()), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copies `file` into the session and records it. Call before touching the file.
    public func backup(_ file: URL, session: URL) throws {
        var name = file.lastPathComponent
        var dest = session.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            name = "\(file.deletingPathExtension().lastPathComponent) (\(n)).\(file.pathExtension)"
            dest = session.appendingPathComponent(name)
            n += 1
        }
        try FileManager.default.copyItem(at: file, to: dest) // a free clone on APFS when on the same disk
        // One line per file, appended: constant time per file even for 9,000-track batches,
        // and nothing is lost if the app is interrupted mid-batch.
        var line = try JSONEncoder().encode(Entry(original: file.path, backup: dest.path))
        line.append(0x0A)
        let log = session.appendingPathComponent("manifest.jsonl")
        lock.lock(); defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        let h = try FileHandle(forWritingTo: log)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: line)
    }

    public func manifest(_ session: URL) -> [Entry] {
        var entries: [Entry] = []
        // older versions wrote a single JSON array
        if let d = try? Data(contentsOf: session.appendingPathComponent("manifest.json")),
           let old = try? JSONDecoder().decode([Entry].self, from: d) { entries += old }
        if let d = try? Data(contentsOf: session.appendingPathComponent("manifest.jsonl")) {
            let dec = JSONDecoder()
            for line in d.split(separator: 0x0A) where !line.isEmpty {
                if let e = try? dec.decode(Entry.self, from: Data(line)) { entries.append(e) }
            }
        }
        return entries
    }

    /// Bytes that backing up `files` will need on the backup disk. Files on the same volume as the
    /// backups folder are cloned by APFS and cost almost nothing, so they count as 0.
    public func bytesNeeded(for files: [URL]) -> (needed: Int64, available: Int64?) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootVol = (try? root.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        var needed: Int64 = 0
        for f in files {
            let v = try? f.resourceValues(forKeys: [.volumeIdentifierKey, .fileSizeKey])
            if let rootVol, let fv = v?.volumeIdentifier as? NSObject, fv.isEqual(rootVol) { continue }
            needed += Int64(v?.fileSize ?? 0)
        }
        let avail = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        return (needed, avail)
    }

    /// Most recent session that has a manifest.
    public func latestSession() -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return items.filter { !manifest($0).isEmpty }.sorted { $0.lastPathComponent > $1.lastPathComponent }.first
    }

    /// Copies every backed-up file back over its original. Returns how many were restored.
    @discardableResult
    public func restore(session: URL) throws -> Int {
        var count = 0
        for e in manifest(session) {
            let orig = URL(fileURLWithPath: e.original), bak = URL(fileURLWithPath: e.backup)
            guard FileManager.default.fileExists(atPath: bak.path) else { continue }
            let tmp = orig.deletingLastPathComponent().appendingPathComponent(".\(orig.lastPathComponent).autocue-restore")
            try? FileManager.default.removeItem(at: tmp)
            try FileManager.default.copyItem(at: bak, to: tmp)
            if FileManager.default.fileExists(atPath: orig.path) {
                _ = try FileManager.default.replaceItemAt(orig, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: orig)
            }
            count += 1
        }
        return count
    }
}
