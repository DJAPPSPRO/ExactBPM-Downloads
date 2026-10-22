import Foundation
import AutoCueCore

// autocue-cli <file.mp3>... [--cues N] [--write]
// Prints the detected grid and cues. With --write, backs up each file and writes the cues into it.

var args = Array(CommandLine.arguments.dropFirst())
var write = false
var count = 8
if let i = args.firstIndex(of: "--write") { write = true; args.remove(at: i) }
if let i = args.firstIndex(of: "--cues"), i + 1 < args.count, let n = Int(args[i + 1]) {
    count = n; args.removeSubrange(i...(i + 1))
}
guard !args.isEmpty else {
    print("usage: autocue-cli <file.mp3>... [--cues N] [--write]")
    exit(1)
}

let backups = BackupManager()
var session: URL? = nil
for path in args {
    let url = URL(fileURLWithPath: path)
    do {
        let t0 = Date()
        let a = try BeatAnalyzer.analyze(url: url)
        let sel = CueSelector.select(a, count: count)
        print("\(url.lastPathComponent)")
        print(String(format: "  %.2f BPM  grid contrast %.1f  drift %.0f ms  style %@  %@  (%.1fs)",
                     a.bpm, a.gridContrast, a.driftMs, sel.style as NSString, (a.isReliable ? "ok" : "CHECK") as NSString,
                     Date().timeIntervalSince(t0)))
        for c in sel.cues {
            let name = c.name.padding(toLength: 10, withPad: " ", startingAt: 0)
            print("  \(String(format: "%2d", c.index + 1))  \(name) \(c.timeString)  bar \(c.bar)  #\(String(format: "%06X", c.color))")
        }
        if write {
            if session == nil { session = try backups.newSession() }
            try backups.backup(url, session: session!)
            try SeratoCueFile.write(cues: sel.cues, to: url)
            print("  written + verified (backup in \(session!.path))")
        }
    } catch {
        print("\(url.lastPathComponent): \(error.localizedDescription)")
    }
}
