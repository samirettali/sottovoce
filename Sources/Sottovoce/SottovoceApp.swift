import AppKit
import SwiftUI

@main
struct SottovoceApp: App {
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
                if KeychainStore.loadAPIKey(for: Prefs.provider) == nil {
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

        if !app.history.isEmpty {
            Menu("Recent Dictations") {
                ForEach(app.history.prefix(10)) { record in
                    Button(preview(of: record.text)) {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(record.text, forType: .string)
                    }
                }
                Divider()
                Button("Clear History") {
                    app.clearHistory()
                }
            }

            Divider()
        }

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit Sottovoce") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// Single-line menu label; click copies the full text to the clipboard.
    private func preview(of text: String) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        return flattened.count > 45 ? String(flattened.prefix(45)) + "…" : flattened
    }
}
