import AVFoundation
import ServiceManagement
import SwiftUI

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var localModel = LocalModelStatus.shared

    @AppStorage(PrefKey.provider) private var providerRaw = TranscriptionProvider.openai.rawValue
    @State private var apiKey = ""
    @State private var apiKeySaved = false
    /// What is currently stored in the Keychain for the active provider;
    /// lets us tell programmatic field reloads apart from actual typing.
    @State private var loadedKey = ""
    @AppStorage(PrefKey.overlayPosition) private var positionRaw = OverlayPosition.bottomCenter.rawValue
    @AppStorage(PrefKey.showIdleOverlay) private var showIdleOverlay = false
    @AppStorage(PrefKey.insertionMethod) private var insertionRaw = InsertionMethod.type.rawValue
    @AppStorage(PrefKey.keepInClipboard) private var keepInClipboard = false
    @AppStorage(PrefKey.playSounds) private var playSounds = true
    @AppStorage(PrefKey.pauseMediaWhileDictating) private var pauseMedia = false
    @AppStorage(PrefKey.languages) private var languagesRaw = ""
    @AppStorage(PrefKey.transcriptionPrompt) private var promptRaw = ""
    @AppStorage(PrefKey.transcriptionKeywords) private var keywordsRaw = ""
    @AppStorage(PrefKey.transcriptionDelay) private var delayRaw = ""
    @AppStorage(PrefKey.inputDeviceUID) private var inputDeviceUID = ""
    @StateObject private var inputDevices = AudioInputDeviceList()
    @StateObject private var levelMonitor = InputLevelMonitor()
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
            Form { shortcutSection; inputSection; outputSection }
                .formStyle(.grouped)
                .tabItem { Label("Dictation", systemImage: "keyboard") }
                .onAppear { startLevelMeter() }
                .onDisappear { levelMonitor.stop() }
                .onChange(of: inputDeviceUID) { _, _ in levelMonitor.restart() }
                // One engine on the device at a time: during a dictation the
                // meter follows the capture that is already running.
                .onChange(of: app.phase.isRecording) { _, recording in
                    if recording { levelMonitor.stop() } else { startLevelMeter() }
                }
            Form { transcriptionSection }
                .formStyle(.grouped)
                .tabItem { Label("Transcription", systemImage: "waveform") }
            Form { overlaySection }
                .formStyle(.grouped)
                .tabItem { Label("Overlay", systemImage: "macwindow") }
        }
        // Wide enough for the comparison grid's seven provider columns — the
        // widest cell ("Several or auto") measures 73 pt at 10 pt, so each
        // column needs ~78 pt — tall enough for the Providers tab with the
        // model row at full height.
        .frame(width: 760, height: 528)
        // The app is LSUIElement, so it normally has no Dock icon at all.
        // While Settings is open, promote it to a regular app so the window
        // can be reached from the Dock and ⌘-Tab, then drop back to a menu
        // bar accessory on close.
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
            // Belt and braces: the microphone must never stay live because a
            // tab's onDisappear didn't fire.
            levelMonitor.stop()
        }
        .onAppear {
            loadedKey = KeychainStore.loadAPIKey(for: provider) ?? ""
            apiKey = loadedKey
            apiKeySaved = !loadedKey.isEmpty
            refreshPermissions()
            localModel.refresh()
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
        case .gemini, .geminiLive: return "AIza…"
        case .deepgram, .fishAudio: return "key…"
        case .parakeet: return ""
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

            if provider.requiresAPIKey {
                apiKeySection
            } else {
                localModelSection
            }
        }
        .formStyle(.grouped)
        .onChange(of: providerRaw) { _, newValue in
            let newProvider = TranscriptionProvider(rawValue: newValue) ?? .openai
            loadedKey = KeychainStore.loadAPIKey(for: newProvider) ?? ""
            apiKey = loadedKey
            apiKeySaved = !loadedKey.isEmpty
            localModel.refresh()
            // Switching to the on-device provider should not leave the first
            // dictation waiting for a load that could have started here.
            app.preloadLocalModelIfNeeded()
        }
    }

    private var apiKeySection: some View {
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

    /// The on-device model has to be fetched once before the first dictation;
    /// downloading it lazily on a hotkey press would stall for minutes.
    private var localModelSection: some View {
        Section {
            // Deliberately the same shape as `apiKeySection`: a titled row,
            // the Form's own separator, then a second row carrying the action
            // or the confirmation. A plain HStack rather than LabeledContent —
            // the grouped Form insets a LabeledContent label into its own
            // column, which pulled the title out of line with the provider
            // grid above.
            HStack(spacing: 8) {
                Text(Self.localModelName)
                Spacer(minLength: 8)
                Text(localModel.statusText)
                    .foregroundStyle(localModel.phase == .ready ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    .font(.callout)
            }

            // Height reserved across states so the footer below never shifts
            // when a download starts or ends, and the tab never outgrows the
            // window (which raised a scrollbar).
            Group {
                switch localModel.phase {
                case .missing:
                    Button("Download") { localModel.downloadIfNeeded() }
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .ready:
                    Text(localModel.readyDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .working(let progress):
                    VStack(spacing: 4) {
                        HStack(spacing: 6) {
                            Text(progress.detailSentence)
                            Spacer(minLength: 8)
                            // Last and fixed-width, so the right edge stays put
                            // however the sentence changes.
                            Text(progress.percentText)
                                .monospacedDigit()
                                .frame(width: 32, alignment: .trailing)
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        ProgressView(value: progress.overall)
                            .controlSize(.small)
                    }
                case .failed(let message):
                    HStack(spacing: 8) {
                        Button("Retry") { localModel.downloadIfNeeded() }
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: Self.localModelRowHeight, alignment: .center)
        } footer: {
            Text("Runs entirely on this Mac — no API key, no network, nothing leaves the machine. The model is about 470 MB and is downloaded once to Application Support. Requires Apple Silicon; it transcribes on the Neural Engine when you stop dictating.")
        }
    }

    private static let localModelName = "Parakeet TDT v3"
    /// Second row of the section; tall enough for the busiest state (caption
    /// line above the progress bar), reserved for all the others.
    private static let localModelRowHeight: CGFloat = 30

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
            Text("Delay trades latency for accuracy (OpenAI only). Keywords (comma-separated) help with product names and acronyms — used by OpenAI, Deepgram and Groq. The context prompt goes to OpenAI and Groq. Languages: Deepgram and OpenAI handle several; Groq, Fish Audio and On-device take only the first, so leave the field empty with those for auto-detection. Changes apply from the next dictation.")
        }
    }

    private var inputSection: some View {
        Section {
            Picker("Microphone", selection: $inputDeviceUID) {
                Text(systemDefaultLabel).tag("")
                Divider()
                ForEach(inputDevices.devices) { device in
                    Text(device.name).tag(device.uid)
                }
                // Without a row for it, an unplugged device would leave the
                // picker blank and look like nothing is selected at all.
                if !inputDeviceUID.isEmpty,
                   !inputDevices.devices.contains(where: { $0.uid == inputDeviceUID }) {
                    Divider()
                    Text("Selected device (not connected)").tag(inputDeviceUID)
                }
            }
            LabeledContent("Input level") {
                InputLevelMeter(level: displayedLevel, overloading: levelMonitor.overloading)
            }
        } header: {
            Text("Microphone")
        } footer: {
            Text("Pinning the built-in microphone keeps Bluetooth headphones out of their low-quality headset mode, so music playing through them doesn't degrade while you dictate.")
        }
    }

    private var systemDefaultLabel: String {
        guard let name = inputDevices.systemDefault?.name else { return "System default" }
        return "System default (\(name))"
    }

    /// The running capture already owns the device during a dictation, so the
    /// meter reads from it rather than opening a second engine.
    private var displayedLevel: Float {
        app.phase.isRecording ? app.level : levelMonitor.level
    }

    /// Checked directly rather than through `micAuthorized`, which is only
    /// refreshed on a timer and can still be false on first appearance.
    private func startLevelMeter() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        levelMonitor.start()
    }

    private var outputSection: some View {
        Section {
            Picker("Insert text by", selection: $insertionRaw) {
                ForEach(InsertionMethod.allCases) { method in
                    Text(method.label).tag(method.rawValue)
                }
            }
            Toggle("Keep dictations in the clipboard", isOn: $keepInClipboard)
            Toggle("Play sounds", isOn: $playSounds)
            Toggle("Pause media while dictating", isOn: $pauseMedia)
        } header: {
            Text("Output")
        } footer: {
            Text("Off, pasting only borrows the clipboard and puts back what was there, marking the text so clipboard managers don't record it.\n\nPausing media covers Spotify, Music and VLC if they are playing, and resumes them when you stop. macOS will ask once to allow controlling each player.")
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

// MARK: - Input level meter

/// Segmented meter in the shape of the one in System Settings → Sound → Input,
/// so it reads as the same kind of instrument.
private struct InputLevelMeter: View {
    let level: Float
    let overloading: Bool

    private static let segments = 20

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<Self.segments, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(fill(at: Float(index + 1) / Float(Self.segments)))
                    .frame(width: 6, height: 11)
            }
        }
        .animation(.linear(duration: 0.06), value: level)
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }

    private func fill(at fraction: Float) -> Color {
        guard level >= fraction else { return Color(nsColor: .quaternaryLabelColor) }
        // Red only for the headroom at the top, and only once the signal has
        // actually reached full scale — not merely because it is loud.
        if overloading, fraction > 0.9 { return .red }
        return .accentColor
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
