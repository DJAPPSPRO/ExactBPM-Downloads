import Foundation

/// Runs the analysis of one file in the `autocue-worker` helper process, so a file that crashes
/// Apple's audio decoder (it happens with damaged MP3s in big libraries) can never take the app down.
public enum IsolatedAnalyzer {
    /// The helper sits next to the app's executable (Contents/MacOS). Nil when running unbundled.
    static var workerURL: URL? = {
        let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let url = exe.deletingLastPathComponent().appendingPathComponent("autocue-worker")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }()

    /// Seconds before a stuck decode is stopped.
    static let timeout: TimeInterval = 180

    public static func analyzeKeyed(url: URL, useCache: Bool = true) throws -> (analysis: TrackAnalysis, key: String?) {
        // Cached results are just a file read — no need for a helper process.
        if useCache, let key = AnalysisCache.key(for: url), let cached = AnalysisCache.load(key) { return (cached, key) }
        guard let worker = workerURL else {
            return try BeatAnalyzer.analyzeKeyed(url: url, useCache: useCache) // e.g. `swift run` during development
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("autocue-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let p = Process()
        p.executableURL = worker
        p.arguments = [url.path, "--out", tmp.path] + (useCache ? [] : ["--fresh"])
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch {
            return try BeatAnalyzer.analyzeKeyed(url: url, useCache: useCache)
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 5)
            throw AutoCueError.decodeFailed("took too long to decode — skipped")
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if p.terminationReason == .uncaughtSignal {
            throw AutoCueError.decodeFailed("this file crashed the audio decoder (it's probably damaged) — skipped")
        }
        if output.hasPrefix("ERR ") {
            throw AutoCueError.unsupportedFile(String(output.dropFirst(4)))
        }
        guard p.terminationStatus == 0, output.hasPrefix("OK "),
              let data = try? Data(contentsOf: tmp),
              let a = try? PropertyListDecoder().decode(TrackAnalysis.self, from: data) else {
            throw AutoCueError.decodeFailed("couldn't be analyzed — skipped")
        }
        let key = String(output.dropFirst(3))
        return (a, key == "-" ? nil : key)
    }
}
