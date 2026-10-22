import SwiftUI
import AppKit

@main
struct AutoCueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup("RhythmCore AutoCue") {
            ContentView()
                .environmentObject(store)
                .environmentObject(store.player)
                .frame(minWidth: 1020, minHeight: 660)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Cue Screen…") { store.newScreen() }
                    .keyboardShortcut("n")
                    .disabled(store.busyWriting)
                Button("Add Tracks…") { store.openPanel() }.keyboardShortcut("o")
            }
            CommandMenu("Cues") {
                Button("Start Scan") { store.startScan() }
                    .keyboardShortcut("r")
                    .disabled(store.scanning || store.unscannedCount == 0 || store.busyWriting)
                Button("Stop Scan") { store.stopScan() }
                    .disabled(!store.scanning)
                Divider()
                Button("Write Cues") { store.writeAll() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(store.readyCount == 0 || store.busyWriting || store.scanning)
                Button("Undo Last Write…") { store.undoLastWrite() }
                Toggle("Overwrite Existing Cues", isOn: $store.overwriteExisting)
                Divider()
                Button("Stop Preview") { store.player.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                Divider()
                Button("Show Backups Folder") { store.openBackupsFolder() }
                Button("Clear Analysis Cache") { store.clearAnalysisCache() }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
