import AppKit
import SwiftUI

@main
struct TranscribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
        } label: {
            MenuBarLabel()
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.shared.bootstrap()
    }
}

private struct MenuBarLabel: View {
    @ObservedObject private var app = AppState.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(systemName: app.phase.isRecording || app.phase == .finishing ? "waveform" : "mic")
            .onAppear {
                // First run: take the user straight to setup.
                if KeychainStore.loadAPIKey() == nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        openSettings()
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            }
    }
}

private struct MenuContent: View {
    @ObservedObject private var app = AppState.shared

    private var statusLine: String {
        switch app.phase {
        case .idle:
            return "Hold \(app.hotkeyName) to dictate · double-tap to lock"
        case .holdRecording, .pendingLock:
            return "Dictating…"
        case .lockedRecording, .pendingUnlock:
            return "Dictating (locked) — double-tap \(app.hotkeyName) to stop"
        case .finishing:
            return "Finishing…"
        }
    }

    var body: some View {
        Text(statusLine)

        Divider()

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit Transcribe") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
