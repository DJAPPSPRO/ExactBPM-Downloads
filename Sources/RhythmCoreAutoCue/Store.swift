import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AutoCueCore

enum TrackStatus: Equatable {
    case queued, analyzing, ready, writing, written
    case failed(String)

    var label: String {
        switch self {
        case .queued: return "Not scanned yet"
        case .analyzing: return "Analyzing…"
        case .ready: return "Ready"
        case .writing: return "Writing…"
        case .written: return "Cues written"
        case .failed(let s): return s
        }
    }
}

struct TrackItem: Identifiable {
    let id = UUID()
    var url: URL
    var status: TrackStatus = .queued
    var analysis: TrackAnalysis?
    var cues: [HotCue] = []
    var autoCues: [HotCue] = []
    var style = ""
    var existingCues: [HotCue] = []
    var include = true
    /// "Analyze Again" skips the analysis cache.
    var forceFresh = false
    /// Where the full analysis is cached (the list only keeps a slim copy to save memory).
    var cacheKey: String?

    var title: String { url.deletingPathExtension().lastPathComponent }
    /// Analyzed and not busy (a failed write can be retried).
    var canWrite: Bool {
        guard analysis != nil, !cues.isEmpty else { return false }
        switch status {
        case .ready, .written, .failed: return true
        default: return false
        }
    }
    var edited: Bool { cues != autoCues }
}

struct WriteSummary: Identifiable {
    let id = UUID()
    let mode: WriteMode
    let written: [URL]
    let failures: [(String, String)]
    let folder: URL?
}

enum WriteMode: String, CaseIterable, Identifiable {
    case inPlace = "Update original files"
    case copies = "Save copies to a folder"
    var id: String { rawValue }
}

@MainActor
final class Store: ObservableObject {
    @Published var tracks: [TrackItem] = []
    @Published var selection: TrackItem.ID?
    @Published var cueCount = 8 { didSet { if cueCount != oldValue { reselectAll() } } }
    @Published var writeMode: WriteMode = .inPlace
    @Published var busyWriting = false
    /// Live write progress for the counter.
    @Published var writeDone = 0
    @Published var writeTotal = 0
    @Published var writingTitle = ""
    @Published var banner: String?
    @Published var lastSummary: WriteSummary?
    /// Always overwrite existing cues. The setting is locked on.
    @Published var overwriteExisting: Bool = true {
        didSet {
            UserDefaults.standard.set(true, forKey: "overwriteExisting")
            for i in tracks.indices where tracks[i].analysis != nil && !tracks[i].existingCues.isEmpty
                && tracks[i].status != .written {
                tracks[i].include = true
            }
        }
    }

    /// Extra timing applied to every cue when writing and previewing (ms, + = later). Remembered between launches.
    @Published var timingOffsetMs: Int = UserDefaults.standard.integer(forKey: "timingOffsetMs") {
        didSet { UserDefaults.standard.set(timingOffsetMs, forKey: "timingOffsetMs") }
    }

    /// Cue position in seconds as it will be written (with the timing fine-tune).
    func playbackSeconds(_ cue: HotCue) -> Double { Double(max(0, cue.milliseconds + timingOffsetMs)) / 1000 }

    let backups = BackupManager()
    let player = PreviewPlayer()
    private var analyzing = false
    /// True while a scan is running (Start Scan pressed, not finished or stopped).
    @Published private(set) var scanning = false
    private var stopRequested = false

    var readyCount: Int { tracks.filter { $0.include && $0.canWrite }.count }
    var pendingCount: Int { tracks.filter { $0.status == .queued || $0.status == .analyzing }.count }
    var unscannedCount: Int { tracks.filter { $0.status == .queued }.count }
    var analyzedCount: Int { tracks.filter { $0.analysis != nil || isFailed($0.status) }.count }
    var writtenCount: Int { tracks.filter { $0.status == .written }.count }

    /// 1 = add tracks, 2 = scan, 3 = check cues, 4 = written
    var step: Int {
        if tracks.isEmpty { return 1 }
        if scanning || analyzedCount == 0 { return 2 }
        if writtenCount > 0 && tracks.filter({ $0.include && $0.canWrite && $0.status != .written }).isEmpty { return 4 }
        return 3
    }

    private func isFailed(_ s: TrackStatus) -> Bool { if case .failed = s { return true } else { return false } }

    // MARK: adding files

    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            // Scanning big folders happens off the main thread so the window never freezes.
            let scan = await Task.detached(priority: .userInitiated) { Store.collectMP3s(urls) }.value
            if let skipped = scan.skipped { banner = skipped }
            var existing = Set(tracks.map { $0.url.standardizedFileURL })
            var newItems: [TrackItem] = []
            newItems.reserveCapacity(scan.mp3s.count)
            for f in scan.mp3s where !existing.contains(f.standardizedFileURL) {
                existing.insert(f.standardizedFileURL)
                newItems.append(TrackItem(url: f))
            }
            if newItems.isEmpty {
                if scan.skipped == nil {
                    banner = scan.mp3s.isEmpty ? "No MP3 files found there." : "Those tracks are already in the list."
                }
                return
            }
            tracks.append(contentsOf: newItems) // one update for the whole batch
            banner = scanning
                ? "Added \(newItems.count) track\(newItems.count == 1 ? "" : "s") — they'll be scanned in this run."
                : "Added \(newItems.count) track\(newItems.count == 1 ? "" : "s"). Press Start Scan when you're ready."
            if selection == nil { selection = tracks.first?.id }
        }
    }

    nonisolated static func collectMP3s(_ urls: [URL]) -> (mp3s: [URL], skipped: String?) {
        var found: [URL] = []
        var skipped: String? = nil
        for u in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let en = FileManager.default.enumerator(at: u, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let f = en?.nextObject() as? URL {
                    if f.pathExtension.lowercased() == "mp3" { found.append(f) }
                }
            } else if u.pathExtension.lowercased() == "mp3" {
                found.append(u)
            } else {
                skipped = "\(u.lastPathComponent): only MP3 files are supported right now"
            }
        }
        found.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return (found, skipped)
    }

    func openPanel() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.allowedContentTypes = [.mp3, .folder]
        p.message = "Choose MP3 files or folders"
        if p.runModal() == .OK { add(p.urls) }
    }

    /// Tracks with cues that were analyzed but not written yet.
    var unwrittenCount: Int { tracks.filter { $0.include && $0.canWrite && $0.status != .written }.count }

    /// Clears the screen and asks for a folder to start a fresh batch.
    func newScreen() {
        guard !busyWriting else { return }
        if unwrittenCount > 0 || pendingCount > 0 {
            let alert = NSAlert()
            alert.messageText = "Start a new cue screen?"
            alert.informativeText = unwrittenCount > 0
                ? "\(unwrittenCount) track\(unwrittenCount == 1 ? " has" : "s have") cues that haven't been written yet. They'll be cleared from the screen. Your music files aren't touched."
                : "Tracks still being analyzed will be cleared from the screen. Your music files aren't touched."
            alert.addButton(withTitle: "New Screen")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        player.stop()
        if scanning { stopRequested = true }
        tracks.removeAll()   // results from analyses still running are ignored when they finish
        selection = nil
        banner = nil
        lastSummary = nil
        openFolderPanel()
    }

    func openFolderPanel() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [.mp3, .folder]
        p.prompt = "Load Folder"
        p.message = "Choose a folder of MP3s (sub-folders are included)"
        if p.runModal() == .OK { add(p.urls) }
    }

    func removeAll() {
        player.stop()
        tracks.removeAll { $0.status != .analyzing && $0.status != .writing }
        selection = tracks.first?.id
    }

    // MARK: analysis

    private func index(_ id: UUID) -> Int? { tracks.firstIndex { $0.id == id } }

    /// Next queued track (the one on screen first), marked as analyzing.
    private func takeNextQueued() -> (UUID, URL, Bool)? {
        if stopRequested { return nil }
        guard let i = tracks.firstIndex(where: { $0.id == selection && $0.status == .queued })
                ?? tracks.firstIndex(where: { $0.status == .queued }) else { return nil }
        let fresh = tracks[i].forceFresh
        tracks[i].status = .analyzing
        tracks[i].forceFresh = false
        return (tracks[i].id, tracks[i].url, fresh)
    }

    /// Start Scan button: analyze every track that hasn't been scanned yet.
    func startScan() {
        guard unscannedCount > 0 else { return }
        stopRequested = false
        analyzePending()
    }

    /// Stop Scan button: tracks already being analyzed finish; the rest stay "Not scanned yet".
    func stopScan() {
        guard scanning else { return }
        stopRequested = true
        banner = "Stopping after the tracks in progress…"
    }

    typealias JobResult = Result<(TrackAnalysis, CueSelection, [HotCue], String?), Error>

    /// Analyze one file (in the crash-isolated helper) and pick its cues. Runs off the main thread.
    nonisolated static func analysisJob(url: URL, fresh: Bool, count: Int) -> JobResult {
        do {
            let (a, key) = try IsolatedAnalyzer.analyzeKeyed(url: url, useCache: !fresh)
            let sel = CueSelector.select(a, count: count)
            let existing = (try? SeratoCueFile.readCues(url: url)) ?? []
            // keep only the slim copy in memory — 9,000 full analyses would not fit
            return .success((a.slim(), sel, existing, key))
        } catch {
            return .failure(error)
        }
    }

    private func apply(_ result: JobResult, to id: UUID) {
        guard let i = index(id) else { return }
        switch result {
        case .success(let (a, sel, existing, key)):
            tracks[i].analysis = a
            tracks[i].cacheKey = key
            tracks[i].cues = sel.cues
            tracks[i].autoCues = sel.cues
            tracks[i].style = sel.style
            tracks[i].existingCues = existing
            // Always overwrite existing cues.
            tracks[i].include = true
            tracks[i].status = .ready
        case .failure(let e):
            tracks[i].status = .failed(e.localizedDescription)
        }
    }

    func analyzePending() {
        guard !analyzing else { return }
        analyzing = true
        scanning = true
        let activity = KeepAwake.begin("Analyzing tracks")
        Task {
            defer {
                KeepAwake.end(activity)
                updateDockBadge()
            }
            // Several tracks at once, and a new one starts the moment any finishes
            // (each track also splits its own work across all cores).
            // Bounded by cores and by memory (~1.5 GB per worker worst case for a 20-minute file).
            let memWorkers = Int(ProcessInfo.processInfo.physicalMemory / 1_500_000_000)
            let workers = max(1, min(6, ProcessInfo.processInfo.activeProcessorCount - 1, memWorkers))
            await withTaskGroup(of: (UUID, JobResult).self) { group in
                var running = 0
                while true {
                    while running < workers, let next = takeNextQueued() {
                        let (id, url, fresh) = next
                        let count = cueCount
                        running += 1
                        group.addTask(priority: .userInitiated) {
                            (id, Store.analysisJob(url: url, fresh: fresh, count: count))
                        }
                    }
                    guard let finished = await group.next() else { break }
                    running -= 1
                    let (id, result) = finished
                    apply(result, to: id)
                    updateDockBadge()
                }
            }
            analyzing = false
            // Tracks added during the last moments of the run are included, unless Stop was pressed.
            if !stopRequested && tracks.contains(where: { $0.status == .queued }) {
                analyzePending()
            } else {
                scanning = false
                if stopRequested {
                    banner = "Scan stopped. \(unscannedCount) track\(unscannedCount == 1 ? "" : "s") not scanned — press Start Scan to continue."
                } else {
                    banner = "Scan finished: \(analyzedCount) track\(analyzedCount == 1 ? "" : "s") ready to check."
                }
                stopRequested = false
                KeepAwake.notifyIfInBackground()
            }
        }
    }

    /// Shows progress on the Dock icon so it's visible from anywhere (e.g. "3/12").
    func updateDockBadge() {
        if busyWriting {
            NSApp.dockTile.badgeLabel = writeTotal == 0 ? "…" : "\(writeDone)/\(writeTotal)"
        } else if scanning && pendingCount > 0 {
            NSApp.dockTile.badgeLabel = "\(analyzedCount)/\(tracks.count)"
        } else {
            NSApp.dockTile.badgeLabel = nil
        }
    }

    /// Re-runs cue selection (not audio analysis) after the cue count changes.
    func reselectAll() {
        let count = cueCount
        let jobs = tracks.filter { $0.analysis != nil && $0.status != .writing }.map { ($0.id, $0.url, $0.cacheKey) }
        guard !jobs.isEmpty else { return }
        Task {
            let workers = max(2, ProcessInfo.processInfo.activeProcessorCount)
            await withTaskGroup(of: (UUID, CueSelection?).self) { group in
                var next = 0, running = 0
                while true {
                    while running < workers && next < jobs.count {
                        let (id, url, key) = jobs[next]
                        next += 1; running += 1
                        group.addTask(priority: .userInitiated) {
                            // The full analysis lives in the cache; re-analyze only if it was cleared.
                            let full = key.flatMap { AnalysisCache.load($0) }
                                ?? (try? IsolatedAnalyzer.analyzeKeyed(url: url).analysis)
                            return (id, full.map { CueSelector.select($0, count: count) })
                        }
                    }
                    guard let done = await group.next() else { break }
                    running -= 1
                    let (id, sel) = done
                    guard let sel, let i = index(id), cueCount == count else { continue }
                    tracks[i].cues = sel.cues
                    tracks[i].autoCues = sel.cues
                    tracks[i].style = sel.style
                    if tracks[i].status == .written { tracks[i].status = .ready }
                }
            }
        }
    }

    func resetCues(_ id: UUID) {
        guard let i = index(id) else { return }
        tracks[i].cues = tracks[i].autoCues
        markEdited(i)
    }

    /// Replaces one cue (name / color edits from the pad tiles).
    func updateCue(_ id: UUID, _ cue: HotCue) {
        guard let i = index(id), let k = tracks[i].cues.firstIndex(where: { $0.index == cue.index }) else { return }
        guard tracks[i].cues[k] != cue else { return }
        tracks[i].cues[k] = cue
        markEdited(i)
    }

    /// An edit after writing means the file is out of date again.
    private func markEdited(_ i: Int) {
        if tracks[i].status == .written { tracks[i].status = .ready }
    }

    /// Moves one cue by whole beats, staying exactly on the beat grid.
    func nudge(_ id: UUID, cue: Int, beats: Int) {
        guard let i = index(id), let a = tracks[i].analysis,
              let k = tracks[i].cues.firstIndex(where: { $0.index == cue }) else { return }
        let ms = Double(tracks[i].cues[k].milliseconds) + Double(beats) * a.beatSeconds * 1000
        tracks[i].cues[k].milliseconds = a.snapToBeat(ms: ms)
        markEdited(i)
        if player.isPlaying(tracks[i].url, cue: cue) {
            player.play(tracks[i].url, from: playbackSeconds(tracks[i].cues[k]), cue: cue)
        }
    }

    func setAllIncluded(_ on: Bool) {
        for i in tracks.indices where tracks[i].analysis != nil { tracks[i].include = on }
    }

    func remove(_ id: UUID) {
        guard let i = index(id), tracks[i].status != .analyzing, tracks[i].status != .writing else { return }
        if player.playingURL == tracks[i].url { player.stop() }
        tracks.remove(at: i)
        if selection == id { selection = tracks.indices.contains(i) ? tracks[i].id : tracks.last?.id }
    }

    func reanalyze(_ id: UUID) {
        guard let i = index(id), tracks[i].status != .analyzing, tracks[i].status != .writing else { return }
        if scanning {
            // join the running scan
            tracks[i].status = .queued
            tracks[i].analysis = nil
            tracks[i].forceFresh = true
            return
        }
        // Only this one track — never starts a full scan.
        tracks[i].status = .analyzing
        tracks[i].analysis = nil
        let url = tracks[i].url, count = cueCount
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Store.analysisJob(url: url, fresh: true, count: count)
            }.value
            apply(result, to: id)
        }
    }

    func reveal(_ id: UUID) {
        if let i = index(id) { NSWorkspace.shared.activateFileViewerSelecting([tracks[i].url]) }
    }

    // MARK: writing

    func writeAll() {
        let targets = tracks.filter { $0.include && $0.canWrite }
        guard !targets.isEmpty else { return }
        var outFolder: URL? = nil
        if writeMode == .copies {
            let p = NSOpenPanel()
            p.canChooseDirectories = true
            p.canChooseFiles = false
            p.canCreateDirectories = true
            p.prompt = "Save Copies Here"
            p.message = "Choose where to save the copies with cues"
            guard p.runModal() == .OK, let u = p.url else { return }
            outFolder = u
        }
        let mode = writeMode
        let backups = self.backups
        let folder = outFolder
        var sessionDir: URL? = nil
        if mode == .inPlace {
            // Make sure the backups fit before touching anything.
            let (needed, avail) = backups.bytesNeeded(for: targets.map { $0.url })
            if let avail, needed > 0, needed > avail - 2_000_000_000 {
                let f = ByteCountFormatter()
                let alert = NSAlert()
                alert.messageText = "Not enough free space for the backups"
                alert.informativeText = "Backing up these \(targets.count) files needs \(f.string(fromByteCount: needed)), but only \(f.string(fromByteCount: max(0, avail))) is free on the disk with your Music folder. Nothing was changed.\n\nChoose “Save copies to a folder” and pick a folder on the drive with your music, or free up some space."
                alert.runModal()
                return
            }
        }
        if mode == .inPlace {
            do { sessionDir = try backups.newSession() } catch {
                banner = "Couldn't create the backup folder: \(error.localizedDescription). Nothing was changed."
                return
            }
        }
        let session = sessionDir
        player.release()
        writeTotal = targets.count
        writeDone = 0
        writingTitle = ""
        busyWriting = true
        updateDockBadge()
        let activity = KeepAwake.begin("Writing cues")
        Task {
            defer { KeepAwake.end(activity) }
            var written: [URL] = []
            var failures: [(String, String)] = []
            for t in targets {
                writingTitle = t.title
                guard let i = index(t.id) else { writeDone += 1; continue }
                tracks[i].status = .writing
                let off = timingOffsetMs
                let cues = t.cues.map { c -> HotCue in var c = c; c.milliseconds = max(0, c.milliseconds + off); return c }
                let src = t.url
                let result: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
                    do {
                        if mode == .inPlace, let session {
                            try backups.backup(src, session: session)
                            try SeratoCueFile.write(cues: cues, to: src)
                            return .success(src)
                        } else {
                            let dest = Store.uniqueURL(in: folder!, name: src.lastPathComponent)
                            try FileManager.default.copyItem(at: src, to: dest)
                            try SeratoCueFile.write(cues: cues, to: dest)
                            return .success(dest)
                        }
                    } catch {
                        return .failure(error)
                    }
                }.value
                writeDone += 1
                updateDockBadge()
                guard let j = index(t.id) else { continue }
                switch result {
                case .success(let url):
                    tracks[j].status = .written
                    if mode == .inPlace { tracks[j].existingCues = cues }
                    written.append(url)
                case .failure(let e):
                    tracks[j].status = .failed(e.localizedDescription)
                    failures.append((t.title, e.localizedDescription))
                }
            }
            busyWriting = false
            writingTitle = ""
            updateDockBadge()
            KeepAwake.notifyIfInBackground()
            lastSummary = WriteSummary(mode: mode, written: written, failures: failures, folder: folder)
        }
    }

    nonisolated static func uniqueURL(in folder: URL, name: String) -> URL {
        var dest = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = folder.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return dest
    }

    func undoLastWrite() {
        guard let s = backups.latestSession() else { banner = "No backups to restore."; return }
        let alert = NSAlert()
        alert.messageText = "Restore the files from \(s.lastPathComponent)?"
        alert.informativeText = "The \(backups.manifest(s).count) file(s) changed in that write will be put back exactly as they were before AutoCue touched them."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        player.release()
        writeTotal = 0 // 0 = restoring (the progress views show "Restoring…")
        busyWriting = true
        banner = "Restoring…"
        let backups = self.backups
        let paths = Dictionary(tracks.map { ($0.url.path, $0.id) }, uniquingKeysWith: { a, _ in a })
        Task {
            // Restoring thousands of files runs in the background; the window stays responsive.
            let result: Result<(Int, [(UUID, [HotCue])]), Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let n = try backups.restore(session: s)
                    var cues: [(UUID, [HotCue])] = []
                    for e in backups.manifest(s) {
                        if let id = paths[e.original] {
                            cues.append((id, (try? SeratoCueFile.readCues(url: URL(fileURLWithPath: e.original))) ?? []))
                        }
                    }
                    // mark the session as used so a second undo goes further back
                    let used = s.deletingLastPathComponent().appendingPathComponent(s.lastPathComponent + " (restored)")
                    try? FileManager.default.moveItem(at: s, to: used)
                    for m in ["manifest.json", "manifest.jsonl"] {
                        try? FileManager.default.removeItem(at: used.appendingPathComponent(m))
                    }
                    return .success((n, cues))
                } catch {
                    return .failure(error)
                }
            }.value
            busyWriting = false
            switch result {
            case .success(let (n, cues)):
                for (id, c) in cues {
                    guard let i = index(id) else { continue }
                    tracks[i].existingCues = c
                    if tracks[i].status == .written { tracks[i].status = .ready }
                }
                banner = "Restored \(n) file(s). Backup copies are still in the backups folder."
            case .failure(let e):
                banner = "Restore failed: \(e.localizedDescription)"
            }
        }
    }

    func clearAnalysisCache() {
        let bytes = AnalysisCache.clear()
        banner = "Cleared the analysis cache (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))."
    }

    func openBackupsFolder() {
        try? FileManager.default.createDirectory(at: backups.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(backups.root)
    }
}
