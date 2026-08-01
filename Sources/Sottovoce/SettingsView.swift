import AVFoundation
import ServiceManagement
import SwiftUI

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject private var app = AppState.shared

    @State private var apiKey = ""
    @State private var apiKeySaved = false
    @AppStorage(PrefKey.overlayPosition) private var positionRaw = OverlayPosition.bottomCenter.rawValue
    @AppStorage(PrefKey.showIdleOverlay) private var showIdleOverlay = false
    @AppStorage(PrefKey.insertionMethod) private var insertionRaw = InsertionMethod.type.rawValue
    @AppStorage(PrefKey.playSounds) private var playSounds = true
    @AppStorage(PrefKey.pauseMediaWhileDictating) private var pauseMedia = false
    @AppStorage(PrefKey.languages) private var languagesRaw = ""
    @AppStorage(PrefKey.transcriptionPrompt) private var promptRaw = ""
    @AppStorage(PrefKey.transcriptionKeywords) private var keywordsRaw = ""
    @AppStorage(PrefKey.transcriptionDelay) private var delayRaw = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var micAuthorized = false
    @State private var axTrusted = false

    private let saveDebouncer = Debouncer(delay: 0.8)
    private let permissionsTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView {
            Form { apiKeySection; generalSection; permissionsSection }
                .formStyle(.grouped)
                .tabItem { Label("General", systemImage: "gearshape") }
            Form { shortcutSection; outputSection }
                .formStyle(.grouped)
                .tabItem { Label("Dictation", systemImage: "keyboard") }
            Form { transcriptionSection }
                .formStyle(.grouped)
                .tabItem { Label("Transcription", systemImage: "waveform") }
            Form { overlaySection }
                .formStyle(.grouped)
                .tabItem { Label("Overlay", systemImage: "macwindow") }
        }
        .frame(width: 440, height: 480)
        .onAppear {
            apiKey = KeychainStore.loadAPIKey() ?? ""
            apiKeySaved = !apiKey.isEmpty
            refreshPermissions()
        }
        .onReceive(permissionsTimer) { _ in
            refreshPermissions()
        }
    }

    // MARK: Sections (shared by every variant)

    private var apiKeySection: some View {
        Section {
            SecureField("API key", text: $apiKey, prompt: Text("sk-…"))
                .onChange(of: apiKey) { _, newValue in
                    apiKeySaved = false
                    saveDebouncer.call {
                        KeychainStore.saveAPIKey(newValue)
                        apiKeySaved = !newValue.trimmingCharacters(in: .whitespaces).isEmpty
                    }
                }
            if apiKeySaved {
                Label("Saved to the macOS Keychain", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
        } header: {
            Text("OpenAI")
        } footer: {
            Text("Uses the gpt-live-transcribe realtime model ($0.017 / min). The key never leaves the Keychain.")
        }
    }

    private var shortcutSection: some View {
        Section {
            LabeledContent("Dictation key") {
                HStack(spacing: 8) {
                    Text(app.capturingHotkey ? "Press a key…" : app.hotkeyName)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .quaternarySystemFill))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(
                                    app.capturingHotkey ? Color.accentColor : Color(nsColor: .separatorColor),
                                    lineWidth: 1
                                )
                        )
                    Button(app.capturingHotkey ? "Cancel" : "Change") {
                        if app.capturingHotkey {
                            app.cancelHotkeyCapture()
                        } else {
                            app.beginHotkeyCapture()
                        }
                    }
                }
            }
        } header: {
            Text("Shortcut")
        } footer: {
            Text("Hold to dictate, release to insert. Double-tap to dictate hands-free, double-tap again to stop. Esc cancels. Modifier keys (⌥, ⌘, fn…) and F-keys work best.")
        }
    }

    private var overlaySection: some View {
        Section {
            PositionPicker(selection: positionBinding)
            Toggle("Show while idle", isOn: $showIdleOverlay)
        } header: {
            Text("Overlay")
        } footer: {
            Text("When enabled, a small microphone chip stays visible so you can tell Sottovoce is running.")
        }
    }

    private var transcriptionSection: some View {
        Section {
            Picker("Delay", selection: $delayRaw) {
                ForEach(TranscriptionDelay.allCases) { delay in
                    Text(delay.label).tag(delay.rawValue)
                }
            }
            TextField("Languages", text: $languagesRaw, prompt: Text("e.g. en, it"))
            TextField("Keywords", text: $keywordsRaw, prompt: Text("e.g. NixOS, Neovim, NUR"))
            TextField("Context prompt", text: $promptRaw, prompt: Text("Describe the recording or its setting"), axis: .vertical)
                .lineLimit(2...4)
        } header: {
            Text("Transcription")
        } footer: {
            Text("Delay trades latency for accuracy. Keywords (comma-separated) help with product names and acronyms. Changes apply from the next dictation.")
        }
    }

    private var outputSection: some View {
        Section {
            Picker("Insert text by", selection: $insertionRaw) {
                ForEach(InsertionMethod.allCases) { method in
                    Text(method.label).tag(method.rawValue)
                }
            }
            Toggle("Play sounds", isOn: $playSounds)
            Toggle("Pause media while dictating", isOn: $pauseMedia)
        } header: {
            Text("Output")
        } footer: {
            Text("Pauses Spotify, Music and VLC if they are playing, and resumes them when you stop. macOS will ask once to allow controlling each player.")
        }
    }

    private var generalSection: some View {
        Section("General") {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
        }
    }

    private var permissionsSection: some View {
        Section("Permissions") {
            permissionRow(
                name: "Microphone",
                granted: micAuthorized,
                pane: "Privacy_Microphone"
            )
            permissionRow(
                name: "Accessibility",
                granted: axTrusted,
                pane: "Privacy_Accessibility"
            )
        }
    }

    // MARK: Helpers

    private var positionBinding: Binding<OverlayPosition> {
        Binding(
            get: { OverlayPosition(rawValue: positionRaw) ?? .bottomCenter },
            set: { newValue in
                positionRaw = newValue.rawValue
                app.overlayPositionChanged()
            }
        )
    }

    private func refreshPermissions() {
        micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        axTrusted = AXIsProcessTrusted()
    }

    private func permissionRow(name: String, granted: Bool, pane: String) -> some View {
        LabeledContent {
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
            } else {
                Button("Open System Settings") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
                    NSWorkspace.shared.open(url)
                }
            }
        } label: {
            Text(name)
        }
    }
}

// MARK: - Position picker

/// A miniature screen with one dot per overlay position.
private struct PositionPicker: View {
    @Binding var selection: OverlayPosition

    var body: some View {
        HStack {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .quaternarySystemFill))
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                // Menu bar hint.
                VStack {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(nsColor: .separatorColor).opacity(0.6))
                        .frame(height: 4)
                        .padding(.horizontal, 5)
                        .padding(.top, 5)
                    Spacer()
                }

                ForEach(OverlayPosition.allCases) { position in
                    dot(for: position)
                        .frame(
                            maxWidth: .infinity, maxHeight: .infinity,
                            alignment: position.alignment
                        )
                        .padding(.horizontal, 14)
                        .padding(.top, 18)
                        .padding(.bottom, 12)
                }
            }
            .frame(width: 190, height: 118)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func dot(for position: OverlayPosition) -> some View {
        Button {
            selection = position
        } label: {
            ZStack {
                Circle()
                    .fill(selection == position ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
                    .frame(width: 11, height: 11)
                if selection == position {
                    Circle()
                        .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 3)
                        .frame(width: 19, height: 19)
                }
            }
            .frame(width: 22, height: 22)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: selection)
    }
}

// MARK: - Debouncer

private final class Debouncer {
    private let delay: TimeInterval
    private var work: DispatchWorkItem?

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func call(_ action: @escaping () -> Void) {
        work?.cancel()
        let item = DispatchWorkItem(block: action)
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
