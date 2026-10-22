import Foundation
import AVFoundation

/// Plays a track from a cue point so the user can hear where each cue lands.
@MainActor
final class PreviewPlayer: ObservableObject {
    @Published private(set) var playingURL: URL?
    @Published private(set) var activeCue: Int?
    @Published private(set) var position: Double = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    var isPlaying: Bool { playingURL != nil }

    func isPlaying(_ url: URL, cue: Int? = nil) -> Bool {
        playingURL == url && (cue == nil || activeCue == cue)
    }

    func play(_ url: URL, from seconds: Double, cue: Int? = nil) {
        if player?.url != url {
            player?.stop()
            player = try? AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
        }
        guard let p = player else { return }
        p.currentTime = max(0, min(seconds, p.duration - 0.05))
        p.play()
        playingURL = url
        activeCue = cue
        position = p.currentTime
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Starts playback, or stops it when that same cue is already playing.
    func toggle(_ url: URL, from seconds: Double, cue: Int? = nil) {
        if isPlaying(url, cue: cue) && (cue != nil || activeCue == nil) { stop() } else { play(url, from: seconds, cue: cue) }
    }

    func stop() {
        player?.stop()
        timer?.invalidate()
        timer = nil
        playingURL = nil
        activeCue = nil
    }

    /// Releases the file (call before rewriting it).
    func release() {
        stop()
        player = nil
    }

    private func tick() {
        guard let p = player else { return }
        position = p.currentTime
        if !p.isPlaying { stop() }
    }
}
