import Foundation
import AutoCueCore

// autocue-worker <file> --out <plist> [--fresh]
//
// Decodes and analyzes ONE file in its own process. If a damaged file makes the system audio
// decoder crash, only this helper dies; the app marks that track as skipped and keeps going.
// Output: the full TrackAnalysis as a binary plist at --out, and the cache key on stdout.

var args = Array(CommandLine.arguments.dropFirst())
var fresh = false
if let i = args.firstIndex(of: "--fresh") { fresh = true; args.remove(at: i) }
guard let o = args.firstIndex(of: "--out"), o + 1 < args.count else {
    FileHandle.standardError.write(Data("usage: autocue-worker <file> --out <plist> [--fresh]\n".utf8))
    exit(64)
}
let out = URL(fileURLWithPath: args[o + 1])
args.removeSubrange(o...(o + 1))
guard let path = args.first else { exit(64) }

do {
    let (analysis, key) = try BeatAnalyzer.analyzeKeyed(url: URL(fileURLWithPath: path), useCache: !fresh)
    let enc = PropertyListEncoder()
    enc.outputFormat = .binary
    try enc.encode(analysis).write(to: out, options: .atomic)
    print("OK \(key ?? "-")")
    exit(0)
} catch {
    print("ERR \(error.localizedDescription)")
    exit(1)
}
