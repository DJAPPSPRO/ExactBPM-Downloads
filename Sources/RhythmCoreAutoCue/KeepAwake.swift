import Foundation
import AppKit

/// Keeps the Mac from idle-sleeping (and stops App Nap from throttling us) while work is running.
/// The display is still allowed to turn off — only the computer stays awake.
enum KeepAwake {
    static func begin(_ reason: String) -> NSObjectProtocol {
        ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "RhythmCore AutoCue: \(reason)")
    }

    static func end(_ token: NSObjectProtocol) {
        ProcessInfo.processInfo.endActivity(token)
    }

    /// Bounces the Dock icon once when a job finishes while the user is in another app.
    @MainActor static func notifyIfInBackground() {
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }
}
