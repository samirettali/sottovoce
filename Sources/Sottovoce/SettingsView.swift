import AVFoundation
import ServiceManagement
import SwiftUI

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject private var app = AppState.shared

    @AppStorage(PrefKey.provider) private var providerRaw = TranscriptionProvider.openai.rawValue
    @State private var apiKey = ""
    @State private var apiKeySaved = false
    /// What is currently stored in the Keychain for the active provider;
    /// lets us tell programmatic field reloads apart from actual typing.
    @State private var loadedKey = ""
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
            providersTab
                .tabItem { Label("Providers", systemImage: "tablecells") }
            Form { generalSection; permissionsSection }
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
        .frame(width: 560, height: 480)
        .onAppear {
            loadedKey = KeychainStore.loadAPIKey(for: provider) ?? ""
            apiKey = loadedKey
            apiKeySaved = !loadedKey.isEmpty
            refreshPermissions()
        }
        .onReceive(permissionsTimer) { _ in
            refreshPermissions()
        }
    }

    // MARK: Sections (shared by every variant)

    private var provider: TranscriptionProvider {
        TranscriptionProvider(rawValue: providerRaw) ?? .openai
    }

    private var keyPrompt: String {
        switch provider {
        case .openai: return "sk-…"
        case .groq: return "gsk_…"
        case .deepgram, .fishAudio: return "key…"
        }
    }

    private var providersTab: some View {
        Form {
            Section {
                comparisonGrid
            } header: {
                Text("Provider")
            } footer: {
                Text("Click a provider name to make it active.")
            }

            Section {
                SecureField("\(provider.displayName) API key", text: $apiKey, prompt: Text(keyPrompt))
                    .onChange(of: apiKey) { _, newValue in
                        // A programmatic reload (provider switch) is already saved.
                        guard newValue != loadedKey else { return }
                        apiKeySaved = false
                        let target = provider
                        saveDebouncer.call {
                            KeychainStore.saveAPIKey(newValue, for: target)
                            if target == self.provider {
                                loadedKey = newValue
                                apiKeySaved = !newValue.trimmingCharacters(in: .whitespaces).isEmpty
                            }
                        }
                    }
                if apiKeySaved {
                    Label("Saved to the macOS Keychain", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                }
            } footer: {
                Text("Each provider's key is stored separately in the Keychain.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: providerRaw) { _, newValue in
            let newProvider = TranscriptionProvider(rawValue: newValue) ?? .openai
            loadedKey = KeychainStore.loadAPIKey(for: newProvider) ?? ""
            apiKey = loadedKey
            apiKeySaved = !loadedKey.isEmpty
        }
    }

    private enum ComparisonValue {
        case bool(KeyPath<TranscriptionProvider.Capabilities, Bool>)
        case text(KeyPath<TranscriptionProvider.Capabilities, String>)
    }

    private static let comparisonRows: [(label: String, value: ComparisonValue)] = [
        ("Text insertion", .text(\.insertion)),
        ("Live preview", .bool(\.livePreview)),
        ("Mixed languages", .bool(\.codeSwitching)),
        ("Language hints", .text(\.languageHints)),
        ("Custom keywords", .bool(\.keywords)),
        ("Context prompt", .bool(\.contextPrompt)),
        ("Latency tuning", .bool(\.delayTuning)),
        ("Pricing", .text(\.pricing)),
    ]

    private let comparisonRowHeight: CGFloat = 24
    private let comparisonHeaderHeight: CGFloat = 26

    private var comparisonGrid: some View {
        HStack(alignment: .top, spacing: 4) {
            // Feature labels; vertical metrics mirror the provider columns.
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: comparisonHeaderHeight)
                ForEach(Self.comparisonRows, id: \.label) { row in
                    Text(row.label)
                        .font(.callout)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(height: comparisonRowHeight, alignment: .leading)
                }
            }
            .padding(.vertical, 6)

            ForEach(TranscriptionProvider.allCases) { p in
                providerColumn(p)
            }
        }
        .padding(.vertical, 2)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: providerRaw)
    }

    /// One provider = one column-wide button: clicking anywhere in the column
    /// selects it, and the active column is tinted.
    private func providerColumn(_ p: TranscriptionProvider) -> some View {
        let active = p == provider
        return Button {
            providerRaw = p.rawValue
        } label: {
            VStack(spacing: 0) {
                Text(p.displayName)
                    .font(.system(size: 11, weight: active ? .bold : .medium))
                    .foregroundStyle(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .frame(height: comparisonHeaderHeight)
                ForEach(Self.comparisonRows, id: \.label) { row in
                    comparisonCell(row.value, for: p)
                        .frame(height: comparisonRowHeight)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? Color.accentColor.opacity(0.10) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(active ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(p.menuLabel)
    }

    @ViewBuilder
    private func comparisonCell(_ value: ComparisonValue, for p: TranscriptionProvider) -> some View {
        switch value {
        case .bool(let key):
            let supported = p.capabilities[keyPath: key]
            Image(systemName: supported ? "checkmark" : "minus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(supported ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
        case .text(let key):
            Text(p.capabilities[keyPath: key])
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 3)
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
            Text("Delay trades latency for accuracy (OpenAI only). Keywords (comma-separated) help with product names and acronyms — used by OpenAI, Deepgram and Groq. The context prompt goes to OpenAI and Groq. Languages: Deepgram and OpenAI handle several; Groq and Fish Audio take only the first, so leave the field empty with those for auto-detection. Changes apply from the next dictation.")
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
