import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AutoCueCore

// MARK: - Theme

enum Theme {
    static let accent = Color(red: 1.0, green: 0.46, blue: 0.16)
    static let bg = Color(red: 0.065, green: 0.07, blue: 0.085)
    static let panel = Color(red: 0.10, green: 0.105, blue: 0.125)
    static let raised = Color(red: 0.145, green: 0.15, blue: 0.175)
    static let line = Color.white.opacity(0.08)
    static let dim = Color.white.opacity(0.55)
}

extension Color {
    init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}

let cuePalette: [(String, UInt32)] = [
    ("Red", 0xCC0000), ("Orange", 0xCC8800), ("Yellow", 0xCCCC00), ("Lime", 0x88CC00),
    ("Green", 0x00CC00), ("Cyan", 0x00CCCC), ("Blue", 0x0000CC), ("Purple", 0x8800CC),
]

/// Brighter version of a Serato cue color for on-screen use (Serato's 0xCC values look dull on dark UI).
func displayColor(_ rgb: UInt32) -> Color {
    let r = Double((rgb >> 16) & 0xFF), g = Double((rgb >> 8) & 0xFF), b = Double(rgb & 0xFF)
    let m = max(r, g, b, 1)
    let k = 255 / m
    return Color(red: min(255, r * k) / 255, green: min(255, g * k) / 255, blue: min(255, b * k) / 255)
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            Rectangle().fill(Theme.line).frame(height: 1)
            Group {
                if store.tracks.isEmpty {
                    WelcomeView(targeted: dropTargeted)
                } else {
                    HSplitView {
                        Sidebar()
                            .frame(minWidth: 290, idealWidth: 330, maxWidth: 440)
                        DetailPane()
                            .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .overlay {
                if dropTargeted && !store.tracks.isEmpty {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                        .background(Theme.accent.opacity(0.06))
                        .overlay(Text("Drop to add").font(.title2.weight(.semibold)).foregroundStyle(Theme.accent))
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            FooterBar()
        }
        .background(Theme.bg)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .overlay(alignment: .top) { BannerView() }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            // Collect every dropped item first, then add them in one go (fast even for thousands of files).
            let group = DispatchGroup()
            let collector = URLCollector()
            for p in providers {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { collector.append(url) }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                let urls = collector.all
                Task { @MainActor in store.add(urls) }
            }
            return true
        }
        .sheet(item: $store.lastSummary) { s in SummarySheet(summary: s) }
    }
}

// MARK: - Header

struct HeaderBar: View {
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(LinearGradient(colors: [Theme.accent, Color(red: 0.85, green: 0.15, blue: 0.25)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "waveform").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("RhythmCore AutoCue").font(.system(size: 15, weight: .bold))
                Text("Automatic hot cues for djay Pro & Serato").font(.caption).foregroundStyle(Theme.dim)
            }
            Spacer(minLength: 20)
            StepGuide(step: store.step)
            Spacer(minLength: 20)
            if store.busyWriting {
                if store.writeTotal == 0 {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Restoring originals…").font(.callout) }
                } else {
                    WriteProgress()
                }
            } else if store.scanning {
                HStack(spacing: 8) {
                    ProgressView(value: Double(store.analyzedCount), total: Double(max(store.tracks.count, 1)))
                        .frame(width: 90)
                    Text("Scanning \(min(store.analyzedCount + 1, store.tracks.count)) of \(store.tracks.count)")
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.dim)
                }
                Button(role: .destructive) { store.stopScan() } label: { Label("Stop Scan", systemImage: "stop.fill") }
                    .controlSize(.large)
                    .help("Finish the tracks in progress, then stop")
            }
            if !store.scanning && store.unscannedCount > 0 {
                Button { store.startScan() } label: {
                    Label("Start Scan (\(store.unscannedCount))", systemImage: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(store.busyWriting)
                .help("Find the beat, downbeats and sections of every track not scanned yet (⌘R)")
            }
            Button { store.newScreen() } label: { Label("New Cue Screen", systemImage: "rectangle.stack.badge.plus") }
                .controlSize(.large)
                .disabled(store.busyWriting)
                .help("Clear this screen and load a new folder (⌘N)")
            Button { store.openPanel() } label: { Label("Add Tracks", systemImage: "plus") }
                .controlSize(.large)
                .help("Add more MP3 files or folders to this screen (⌘O). You can also drag them onto the window.")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(Theme.panel)
    }
}

struct StepGuide: View {
    let step: Int
    private let steps = ["Add tracks", "Scan", "Check cues", "Write to files"]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { i in
                let n = i + 1
                let done = n < step || (step == 4 && n == 4)
                let active = n == step
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(done ? Color.green.opacity(0.85) : (active ? Theme.accent : Color.white.opacity(0.12)))
                        if done {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.black)
                        } else {
                            Text("\(n)").font(.system(size: 10, weight: .bold)).foregroundStyle(active ? .black : Theme.dim)
                        }
                    }
                    .frame(width: 18, height: 18)
                    Text(steps[i]).font(.callout.weight(active ? .semibold : .regular))
                        .foregroundStyle(active || done ? .white : Theme.dim)
                }
                if i < 3 {
                    Rectangle().fill(Color.white.opacity(0.15)).frame(width: 22, height: 1)
                }
            }
        }
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @EnvironmentObject var store: Store
    let targeted: Bool

    var body: some View {
        VStack(spacing: 26) {
            VStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(targeted ? Theme.accent : Theme.dim)
                Text("Drop MP3 files or folders here").font(.system(size: 24, weight: .bold))
                Text("AutoCue finds the beat, the downbeats and where each section starts,\nthen puts a named, colored hot cue on each one.")
                    .multilineTextAlignment(.center).foregroundStyle(Theme.dim)
                HStack(spacing: 10) {
                    Button { store.openFolderPanel() } label: { Label("Choose Folder…", systemImage: "folder").padding(.horizontal, 6) }
                        .buttonStyle(.borderedProminent)
                    Button { store.openPanel() } label: { Text("Choose Files…").padding(.horizontal, 6) }
                }
                .controlSize(.large)
                .padding(.top, 4)
            }
            HStack(spacing: 14) {
                tip("1", "Add", "Drop tracks or a whole crate folder. Nothing is analyzed yet.")
                tip("2", "Scan", "Press Start Scan when you're ready. Stop any time.")
                tip("3", "Check", "Click a pad to hear the cue. Nudge or rename anything you want.")
                tip("4", "Write", "One click saves the cues. Originals are backed up first.")
            }
            .frame(maxWidth: 900)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(targeted ? Theme.accent : Color.white.opacity(0.14),
                              style: StrokeStyle(lineWidth: 2, dash: [9, 7]))
                .background(RoundedRectangle(cornerRadius: 22).fill(targeted ? Theme.accent.opacity(0.06) : Color.clear))
                .padding(26)
        )
    }

    func tip(_ n: String, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(n).font(.system(size: 12, weight: .heavy)).foregroundStyle(.black)
                    .frame(width: 22, height: 22).background(Circle().fill(Theme.accent))
                Text(title).font(.headline)
            }
            Text(text).font(.callout).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("TRACKS").font(.caption.weight(.bold)).foregroundStyle(Theme.dim)
                Text("\(store.tracks.count)").font(.caption.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                Spacer()
                Menu {
                    // Overwrite is always on.
                    Text("Always overwrites existing cues")
                    Divider()
                    Button("Select All") { store.setAllIncluded(true) }
                    Button("Select None") { store.setAllIncluded(false) }
                    Divider()
                    Button("Clear List") { store.removeAll() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24)
                .help("Selection and list options")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            List(selection: $store.selection) {
                ForEach(store.tracks) { t in
                    TrackRow(track: t)
                        .tag(t.id)
                        .contextMenu {
                            Button("Show in Finder") { store.reveal(t.id) }
                            Button("Analyze Again") { store.reanalyze(t.id) }
                            Divider()
                            Button("Remove from List") { store.remove(t.id) }
                        }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 6) {
                Image(systemName: "checkmark.square.fill").foregroundStyle(Theme.accent)
                Text(store.overwriteExisting
                     ? "Ticked tracks get written. Existing cues are overwritten (originals backed up)."
                     : "Ticked tracks get written. Tracks that already have cues start unticked.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption).foregroundStyle(Theme.dim)
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .background(Theme.panel)
    }
}

struct TrackRow: View {
    @EnvironmentObject var store: Store
    let track: TrackItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { track.include },
                set: { v in if let i = store.tracks.firstIndex(where: { $0.id == track.id }) { store.tracks[i].include = v } }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(!track.canWrite)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(track.title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 5) {
                    statusIcon
                    Text(subtitle).lineLimit(1)
                }
                .font(.caption).foregroundStyle(Theme.dim)
                if let a = track.analysis, !track.cues.isEmpty {
                    CueStrip(duration: a.duration, cues: track.cues).frame(height: 6)
                }
            }
        }
        .padding(.vertical, 4)
    }

    var subtitle: String {
        switch track.status {
        case .ready, .written:
            var parts: [String] = []
            if let a = track.analysis { parts.append(String(format: "%.1f BPM", a.bpm)) }
            if !track.style.isEmpty { parts.append(track.style) }
            if track.status == .written { parts.insert("Written", at: 0) }
            else if !track.existingCues.isEmpty { parts.append("has \(track.existingCues.count) cues") }
            return parts.joined(separator: " · ")
        default:
            return track.status.label
        }
    }

    @ViewBuilder var statusIcon: some View {
        switch track.status {
        case .queued: Image(systemName: "clock")
        case .analyzing, .writing: ProgressView().controlSize(.mini).frame(width: 12, height: 12)
        case .ready:
            if let a = track.analysis, !a.isReliable {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(Theme.accent)
            }
        case .written: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

/// Tiny timeline showing where the cues sit.
struct CueStrip: View {
    let duration: Double
    let cues: [HotCue]

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                ForEach(cues) { c in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(displayColor(c.color))
                        .frame(width: 3)
                        .offset(x: max(0, min(g.size.width - 3, Double(c.milliseconds) / 1000 / max(duration, 1) * g.size.width)))
                }
            }
        }
    }
}

// MARK: - Detail

struct DetailPane: View {
    @EnvironmentObject var store: Store

    var body: some View {
        if let t = store.tracks.first(where: { $0.id == store.selection }) {
            TrackDetail(track: t)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "sidebar.left").font(.largeTitle).foregroundStyle(Theme.dim)
                Text("Select a track to see its cues").foregroundStyle(Theme.dim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct TrackDetail: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var player: PreviewPlayer
    let track: TrackItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                titleRow
                switch track.status {
                case .queued:
                    VStack(alignment: .leading, spacing: 12) {
                        Label(store.scanning ? "Waiting its turn in the scan…" : "Not scanned yet", systemImage: "clock")
                            .foregroundStyle(Theme.dim)
                        if !store.scanning {
                            Button { store.startScan() } label: {
                                Label("Start Scan (\(store.unscannedCount) track\(store.unscannedCount == 1 ? "" : "s"))", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(store.busyWriting)
                        }
                    }
                    .padding(.top, 30)
                case .analyzing:
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Finding the beat, downbeats and sections…").foregroundStyle(Theme.dim)
                    }
                    .padding(.top, 30)
                case .failed(let msg) where track.analysis == nil:
                    VStack(alignment: .leading, spacing: 10) {
                        Label(msg, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                        Button("Try Again") { store.reanalyze(track.id) }
                    }
                default:
                    if let a = track.analysis { content(a) }
                }
            }
            .padding(22)
        }
        .background(Theme.bg)
    }

    var titleRow: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title).font(.system(size: 22, weight: .bold)).lineLimit(2)
                Button { store.reveal(track.id) } label: {
                    Label(track.url.deletingLastPathComponent().path, systemImage: "folder")
                        .lineLimit(1).truncationMode(.head)
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(Theme.dim)
                .help("Show in Finder")
            }
            Spacer()
            if let a = track.analysis {
                let playing = player.isPlaying(track.url)
                Button {
                    if playing { player.stop() }
                    else { player.play(track.url, from: track.cues.first.map { store.playbackSeconds($0) } ?? 0) }
                } label: {
                    Label(playing ? "Stop" : "Play", systemImage: playing ? "stop.fill" : "play.fill")
                        .frame(minWidth: 64)
                }
                .controlSize(.large)
                .help("Preview the track. Click any pad or the waveform to jump there.")
                .disabled(a.duration <= 0)
            }
        }
    }

    @ViewBuilder func content(_ a: TrackAnalysis) -> some View {
        HStack(spacing: 10) {
            chip("BPM", String(format: "%.2f", a.bpm))
            chip("LENGTH", String(format: "%d:%02d", Int(a.duration) / 60, Int(a.duration) % 60))
            chip("STYLE", track.style)
            chip("GRID", a.isReliable ? "Steady" : "Check", warn: !a.isReliable)
            chip("CUES", "\(track.cues.count)")
        }

        if case .failed(let msg) = track.status {
            notice("xmark.octagon.fill", .red, "Writing failed: \(msg). Fix the problem and press Write again.")
        }
        if !a.isReliable {
            notice("exclamationmark.triangle.fill", .orange,
                   "The tempo in this track isn't perfectly steady (live drums or tempo changes). Listen to the cues before playing it out.")
        }
        if !track.existingCues.isEmpty && track.status != .written {
            HStack(spacing: 10) {
                Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                Text("This file already has \(track.existingCues.count) hot cue\(track.existingCues.count == 1 ? "" : "s"). \(track.include ? "They'll be replaced with the new cues" : "This track will be skipped") — loops are always kept and the original is backed up.")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Toggle("Replace", isOn: Binding(
                    get: { track.include },
                    set: { v in if let i = store.tracks.firstIndex(where: { $0.id == track.id }) { store.tracks[i].include = v } }
                ))
                .toggleStyle(.switch)
            }
            .font(.callout)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.12)))
        }

        WaveOverview(analysis: a, cues: track.cues, url: track.url)
            .frame(height: 118)

        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 130), spacing: 12), count: 4), spacing: 12) {
            ForEach(track.cues) { cue in
                PadTile(trackID: track.id, url: track.url, cue: cue, analysis: a)
            }
        }

        HStack {
            if track.cues != track.autoCues {
                Button { store.resetCues(track.id) } label: { Label("Reset to Automatic Cues", systemImage: "arrow.uturn.backward") }
            }
            Spacer()
            Text("‹‹ ›› move a bar  ·  ‹ › move a beat  ·  ● ▾ change the song part")
                .font(.caption).foregroundStyle(Theme.dim)
        }

        ColorKey()
    }

    func chip(_ title: String, _ value: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.dim)
            Text(value).font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(warn ? Color.orange : Color.white)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(minWidth: 80, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel))
    }

    func notice(_ icon: String, _ color: Color, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.12)))
    }
}

// MARK: - Waveform overview

struct WaveOverview: View {
    @EnvironmentObject var player: PreviewPlayer
    let analysis: TrackAnalysis
    let cues: [HotCue]
    let url: URL

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let dur = max(analysis.duration, 1)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    let levels = analysis.barLevels
                    guard let maxL = levels.max(), levels.count > 1 else { return }
                    let floorDB = maxL - 30
                    let top = 20.0, usable = size.height - top - 4
                    for (i, l) in levels.enumerated() {
                        let t0 = analysis.barStartTime(i) / dur
                        let t1 = (i + 1 < levels.count ? analysis.barStartTime(i + 1) : dur) / dur
                        let v = max(0.04, min(1, (l - floorDB) / 30))
                        let barH = v * usable
                        let rect = CGRect(x: t0 * size.width, y: top + (usable - barH) / 2,
                                          width: max(1, (t1 - t0) * size.width - 1), height: barH)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(Color.white.opacity(0.22)))
                    }
                }
                ForEach(cues) { c in
                    let x = Double(c.milliseconds) / 1000 / dur * w
                    let col = displayColor(c.color)
                    Rectangle().fill(col).frame(width: 2, height: h - 16).offset(x: x - 1, y: 16)
                    Text("\(c.index + 1)")
                        .font(.system(size: 10, weight: .heavy)).foregroundStyle(.black)
                        .frame(width: 16, height: 15)
                        .background(RoundedRectangle(cornerRadius: 3).fill(col))
                        .help("\(c.index + 1): \(c.name) · \(c.timeString)")
                        .offset(x: min(max(0, x - 1), w - 16), y: 0)
                }
                if player.isPlaying(url) {
                    Rectangle().fill(Color.white).frame(width: 2, height: h - 16)
                        .offset(x: player.position / dur * w - 1, y: 16)
                        .shadow(color: .white.opacity(0.6), radius: 3)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { loc in
                player.play(url, from: max(0, min(dur, loc.x / max(w, 1) * dur)))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
        .help("Click anywhere to play from that point")
    }
}

// MARK: - Pad tile

struct PadTile: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var player: PreviewPlayer
    let trackID: UUID
    let url: URL
    let cue: HotCue
    let analysis: TrackAnalysis

    var body: some View {
        let col = displayColor(cue.color)
        let playing = player.isPlaying(url, cue: cue.index)
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Button {
                    player.toggle(url, from: store.playbackSeconds(cue), cue: cue.index)
                } label: {
                    HStack(spacing: 5) {
                        Text("\(cue.index + 1)").font(.system(size: 14, weight: .heavy).monospacedDigit())
                        Image(systemName: playing ? "stop.fill" : "play.fill").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 9).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(col))
                }
                .buttonStyle(.plain)
                .help("Play from this cue")
                Spacer()
                Menu {
                    Section("Song part") {
                        ForEach(CueColors.parts, id: \.name) { part in
                            Button {
                                var c = cue
                                c.name = part.name
                                c.color = part.color
                                store.updateCue(trackID, c)
                            } label: {
                                Label { Text(part.name) } icon: { Image(nsImage: swatch(part.color)) }
                            }
                        }
                    }
                    Menu("Custom Color") {
                        ForEach(cuePalette, id: \.1) { item in
                            Button {
                                var c = cue; c.color = item.1
                                store.updateCue(trackID, c)
                            } label: {
                                Label { Text(item.0) } icon: { Image(nsImage: swatch(item.1)) }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Circle().fill(col).frame(width: 12, height: 12)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.dim)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 34)
                .help("Set the song part (name + color) or pick a custom color")
            }

            TextField("Cue name", text: Binding(
                get: { cue.name },
                set: { v in
                    var c = cue
                    c.name = String(v.prefix(32))
                    // typing a song part ("Chorus", "Drop 2"…) colors the cue to match
                    if let part = CueColors.part(for: c.name) { c.color = part.color }
                    store.updateCue(trackID, c)
                }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25)))

            Text(CueColors.part(for: cue.name)?.meaning ?? "Custom cue")
                .font(.caption2).foregroundStyle(Theme.dim).lineLimit(1)

            HStack {
                Text(cue.timeString).font(.system(size: 12, weight: .medium).monospacedDigit())
                Spacer()
                Text("Bar \(analysis.barBeat(ms: cue.milliseconds))").font(.caption.monospacedDigit()).foregroundStyle(Theme.dim)
            }

            HStack(spacing: 4) {
                nudge("chevron.left.2", -4, "Back one bar")
                nudge("chevron.left", -1, "Back one beat")
                Spacer(minLength: 0)
                nudge("chevron.right", 1, "Forward one beat")
                nudge("chevron.right.2", 4, "Forward one bar")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.raised))
        .overlay(alignment: .top) {
            UnevenTopBar(color: col).frame(height: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(playing ? col : Color.white.opacity(0.06), lineWidth: playing ? 2 : 1))
    }

    func nudge(_ icon: String, _ beats: Int, _ help: String) -> some View {
        Button { store.nudge(trackID, cue: cue.index, beats: beats) } label: {
            Image(systemName: icon).font(.system(size: 10, weight: .bold))
                .frame(width: 26, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Colored strip along the top edge of a pad.
struct UnevenTopBar: View {
    let color: Color
    var body: some View { Rectangle().fill(color) }
}

// MARK: - Footer

struct FooterBar: View {
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("CUES PER TRACK").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.dim)
                Picker("", selection: $store.cueCount) {
                    ForEach([4, 8, 12, 16], id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                .disabled(store.busyWriting)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("SAVE CUES BY").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.dim)
                Picker("", selection: $store.writeMode) {
                    ForEach(WriteMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 195)
                .disabled(store.busyWriting)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("TIMING FINE-TUNE").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.dim)
                HStack(spacing: 6) {
                    Stepper(value: $store.timingOffsetMs, in: -50...50, step: 5) {
                        Text("\(store.timingOffsetMs > 0 ? "+" : "")\(store.timingOffsetMs) ms")
                            .font(.callout.monospacedDigit())
                            .frame(width: 52, alignment: .leading)
                    }
                    if store.timingOffsetMs != 0 {
                        Button("Reset") { store.timingOffsetMs = 0 }.buttonStyle(.link).font(.caption)
                    }
                }
                .disabled(store.busyWriting)
            }
            .help("Cues already land on the start of each hit. If they still feel early in your DJ app, add a few ms (+ = later).")
            Spacer()
            Button { store.undoLastWrite() } label: { Label("Undo Last Write", systemImage: "arrow.uturn.backward") }
                .disabled(store.busyWriting)
                .help("Put back the files exactly as they were before the last write")
            Button {
                store.writeAll()
            } label: {
                HStack(spacing: 8) {
                    if store.busyWriting {
                        ProgressView().controlSize(.small)
                        Text(store.writeTotal == 0 ? "Restoring…" : "Writing \(min(store.writeDone + 1, store.writeTotal)) of \(store.writeTotal)…")
                            .monospacedDigit()
                    } else {
                        Image(systemName: "square.and.arrow.down.fill")
                        Text(store.readyCount == 0 ? "Write Cues" : "Write Cues to \(store.readyCount) Track\(store.readyCount == 1 ? "" : "s")")
                    }
                }
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.readyCount == 0 || store.busyWriting || store.scanning)
            .help(store.scanning ? "Waiting for the scan to finish" : "Save the cues (⌘↩)")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(Theme.panel)
    }
}

// MARK: - Banner + summary

struct BannerView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        if let b = store.banner {
            HStack(spacing: 10) {
                Image(systemName: "info.circle.fill").foregroundStyle(Theme.accent)
                Text(b).font(.callout)
                Button { store.banner = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Capsule().fill(Theme.raised))
            .overlay(Capsule().strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
            .padding(.top, 70)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: b) {
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                if store.banner == b { store.banner = nil }
            }
        }
    }
}

struct SummarySheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let summary: WriteSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: summary.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(summary.failures.isEmpty ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary.written.isEmpty ? "No cues were written" :
                            "Cues written to \(summary.written.count) track\(summary.written.count == 1 ? "" : "s")")
                        .font(.title2.weight(.bold))
                    Text(summary.mode == .inPlace
                         ? "Every original was backed up first. Cues ▸ Undo Last Write puts them back."
                         : "Copies with cues were saved in “\(summary.folder?.lastPathComponent ?? "")”. Your originals weren't touched.")
                        .foregroundStyle(Theme.dim)
                }
            }

            if !summary.failures.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Couldn't write \(summary.failures.count):").font(.headline)
                    ForEach(Array(summary.failures.prefix(12).enumerated()), id: \.offset) { _, f in
                        Text("• \(f.0) — \(f.1)").font(.callout).foregroundStyle(Theme.dim).lineLimit(2)
                    }
                    if summary.failures.count > 12 {
                        Text("…and \(summary.failures.count - 12) more (marked with a red icon in the track list).")
                            .font(.callout).foregroundStyle(Theme.dim)
                    }
                }
            }

            if !summary.written.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Load them in djay Pro").font(.headline)
                    step(1, "If djay already has these tracks in its library, remove them from the library (the files stay on your disk).")
                    step(2, summary.mode == .inPlace
                         ? "Drag the tracks (or their folder) back into djay — it reads the new cues when it imports them."
                         : "Drag the copies from the new folder into djay.")
                    step(3, "Load a track and hit pads 1–\(store.cueCount). Serato DJ reads the same cues.")
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
            }

            HStack {
                if !summary.written.isEmpty {
                    Button("Show in Finder") {
                        // Finder can't select thousands of files at once; show their folders instead.
                        if summary.written.count <= 50 {
                            NSWorkspace.shared.activateFileViewerSelecting(summary.written)
                        } else {
                            var seen = Set<URL>()
                            let folders = summary.written.map { $0.deletingLastPathComponent() }.filter { seen.insert($0).inserted }
                            NSWorkspace.shared.activateFileViewerSelecting(Array(folders.prefix(20)))
                        }
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(26)
        .frame(width: 540)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }

    func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.system(size: 11, weight: .heavy)).foregroundStyle(.black)
                .frame(width: 20, height: 20).background(Circle().fill(Theme.accent))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Color key

/// Colored dot image for menus (non-template so macOS keeps the color).
func swatch(_ rgb: UInt32) -> NSImage {
    let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
        let c = NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                        blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        c.setFill()
        NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
        return true
    }
    img.isTemplate = false
    return img
}

/// Legend: which color means which part of the song.
struct ColorKey: View {
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("COLOR KEY").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.dim)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(CueColors.parts, id: \.name) { p in
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 3).fill(displayColor(p.color)).frame(width: 14, height: 14)
                        Text(p.name).font(.caption.weight(.semibold))
                    }
                    .help(p.meaning)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
    }
}

// MARK: - Write progress

/// "Writing 3 of 12" counter with a progress bar and the track being written.
struct WriteProgress: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let total = max(store.writeTotal, 1)
        let pct = Int((Double(store.writeDone) / Double(total) * 100).rounded())
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Writing \(min(store.writeDone + 1, store.writeTotal)) of \(store.writeTotal)")
                        .font(.callout.weight(.semibold).monospacedDigit())
                    Text("\(pct)%").font(.caption.monospacedDigit()).foregroundStyle(Theme.dim)
                }
                ProgressView(value: Double(store.writeDone), total: Double(total))
                    .frame(width: 180)
                Text(store.writingTitle).font(.caption2).foregroundStyle(Theme.dim)
                    .lineLimit(1).truncationMode(.middle).frame(width: 180, alignment: .leading)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
        .help("Your Mac stays awake until writing finishes. The display can turn off.")
    }
}

/// Thread-safe bag of URLs filled by drag-and-drop callbacks.
final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func append(_ u: URL) { lock.lock(); urls.append(u); lock.unlock() }
    var all: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
}
