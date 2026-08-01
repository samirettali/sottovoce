import AppKit
import AVFoundation
import Combine

/// Central state machine. Everything here runs on the main thread: the hotkey
/// tap lives on the main run loop, and audio/WebSocket callbacks hop to main.
struct DictationRecord: Identifiable {
    let id = UUID()
    let text: String
    let date: Date
}

final class AppState: ObservableObject {
    static let shared = AppState()

    enum Phase: Equatable {
        case idle
        case holdRecording   // key held down (push-to-talk)
        case pendingLock     // one short tap; waiting for the second to lock
        case lockedRecording // hands-free until double-tap
        case pendingUnlock   // one short tap while locked; waiting for the second
        case finishing       // draining final transcripts

        var isRecording: Bool {
            switch self {
            case .holdRecording, .pendingLock, .lockedRecording, .pendingUnlock: return true
            default: return false
            }
        }

        var isLocked: Bool {
            self == .lockedRecording || self == .pendingUnlock
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var level: Float = 0
    @Published private(set) var previewText = ""
    @Published private(set) var sessionReady = false
    @Published private(set) var flashDone = false
    @Published private(set) var overlayPreview = false
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var recordingEndedAt: Date?
    @Published private(set) var capturingHotkey = false
    @Published private(set) var hotkeyName = ""
    /// Last dictations, newest first. Kept in memory only — dictated text can
    /// be sensitive, so it is never written to disk and vanishes on quit.
    @Published private(set) var history: [DictationRecord] = []
    @Published var errorMessage: String?

    let hotkey = HotkeyManager()
    private let audio = AudioCapture()
    private let mediaPauser = MediaPauser()
    private var client: TranscriptionSession?
    private var overlay: OverlayController?

    private var keyDownTime: CFTimeInterval = 0
    private var ignoreNextKeyUp = false
    private var pendingTapWork: DispatchWorkItem?
    private var errorDismissWork: DispatchWorkItem?
    private var flashWork: DispatchWorkItem?
    private var previewWork: DispatchWorkItem?

    /// Transcript state for the current session.
    private var insertedText = ""
    private var deltaText = ""
    /// Text typed live from deltas for the current (uncommitted) item.
    private var itemTyped = ""
    /// Unstable in-progress utterance (Deepgram interims): preview only.
    private var interimText = ""

    private let holdThreshold: CFTimeInterval = 0.30
    private let doubleTapWindow: CFTimeInterval = 0.40

    private init() {
        Prefs.registerDefaults()
        hotkeyName = KeyNames.name(for: Prefs.hotkeyKeyCode)
    }

    // MARK: - Bootstrap

    func bootstrap() {
        overlay = OverlayController()

        hotkey.keyCode = Prefs.hotkeyKeyCode
        hotkey.onDown = { [weak self] in self?.hotkeyDown() }
        hotkey.onUp = { [weak self] in self?.hotkeyUp() }
        hotkey.onEscape = { [weak self] in
            guard let self, self.phase.isRecording else { return false }
            self.cancelSession()
            return true
        }
        hotkey.start()

        promptForPermissions()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.overlay?.reposition()
        }
    }

    private func promptForPermissions() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Hotkey state machine

    private func now() -> CFTimeInterval { CACurrentMediaTime() }

    func hotkeyDown() {
        switch phase {
        case .idle:
            keyDownTime = now()
            startSession()

        case .pendingLock:
            // Second tap: lock hands-free mode.
            pendingTapWork?.cancel()
            pendingTapWork = nil
            ignoreNextKeyUp = true
            setPhase(.lockedRecording)

        case .lockedRecording:
            keyDownTime = now()

        case .pendingUnlock:
            // Second tap while locked: stop and insert.
            pendingTapWork?.cancel()
            pendingTapWork = nil
            ignoreNextKeyUp = true
            finishSession()

        case .holdRecording, .finishing:
            break
        }
    }

    func hotkeyUp() {
        if ignoreNextKeyUp {
            ignoreNextKeyUp = false
            return
        }
        let duration = now() - keyDownTime

        switch phase {
        case .holdRecording:
            if duration >= holdThreshold {
                finishSession()
            } else {
                // Quick tap: give the user a beat to tap again and lock;
                // otherwise it was accidental — discard.
                setPhase(.pendingLock)
                schedulePendingTap { [weak self] in self?.cancelSession() }
            }

        case .lockedRecording:
            if duration < holdThreshold {
                setPhase(.pendingUnlock)
                schedulePendingTap { [weak self] in self?.setPhase(.lockedRecording) }
            }

        default:
            break
        }
    }

    private func schedulePendingTap(_ action: @escaping () -> Void) {
        pendingTapWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingTapWork = nil
            action()
        }
        pendingTapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: work)
    }

    private func setPhase(_ newPhase: Phase) {
        phase = newPhase
    }

    // MARK: - Session lifecycle

    private func startSession() {
        let provider = Prefs.provider
        guard let apiKey = KeychainStore.loadAPIKey(for: provider) else {
            showError("Add your \(provider.displayName) API key in Settings (menu bar icon → Settings…).")
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            promptForPermissions()
            showError("Sottovoce needs microphone access — grant it in System Settings.")
            return
        }

        insertedText = ""
        deltaText = ""
        itemTyped = ""
        interimText = ""
        previewText = ""
        sessionReady = false
        flashWork?.cancel()
        flashDone = false
        errorMessage = nil
        overlay?.reposition()

        let client: TranscriptionSession
        switch provider {
        case .openai:
            var options = TranscriptionClient.Options.fromPrefs()
            options.prompt = composedContextPrompt()
            client = TranscriptionClient(apiKey: apiKey, options: options)
        case .deepgram:
            client = DeepgramClient(
                apiKey: apiKey,
                languages: Prefs.languages,
                keywords: Prefs.transcriptionKeywords
            )
        case .groq:
            // Whisper's prompt biases vocabulary, so keywords ride along here.
            var promptParts = [composedContextPrompt()]
            let keywords = Prefs.transcriptionKeywords
            if !keywords.isEmpty {
                promptParts.append("Vocabulary: " + keywords.joined(separator: ", ") + ".")
            }
            client = GroqClient(
                apiKey: apiKey,
                language: Prefs.languages.first,
                prompt: promptParts.filter { !$0.isEmpty }.joined(separator: " ")
            )
        case .fishAudio:
            client = FishAudioClient(apiKey: apiKey, language: Prefs.languages.first)
        }
        self.client = client

        client.onReady = { [weak self] in
            self?.sessionReady = true
        }
        client.onDelta = { [weak self] delta in
            guard let self, self.phase.isRecording || self.phase == .finishing else { return }
            self.handleDelta(delta)
        }
        client.onInterim = { [weak self] text in
            guard let self, self.phase.isRecording || self.phase == .finishing else { return }
            self.interimText = text
            self.updatePreview()
        }
        client.onCompleted = { [weak self] transcript in
            self?.handleCompleted(transcript)
        }
        client.onError = { [weak self] message in
            guard let self else { return }
            self.showError(message)
            if self.phase.isRecording { self.teardownSession() }
        }
        client.onFinished = { [weak self] in
            self?.completeFinish()
        }

        client.connect()

        do {
            try audio.start(
                onChunk: { [weak client] chunk in client?.sendAudio(chunk) },
                onLevel: { [weak self] level in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.level = 0.35 * level + 0.65 * self.level
                    }
                }
            )
        } catch {
            client.cancel()
            self.client = nil
            showError(error.localizedDescription)
            return
        }

        if Prefs.pauseMediaWhileDictating {
            mediaPauser.pauseActivePlayers()
        }

        recordingStartedAt = Date()
        recordingEndedAt = nil
        setPhase(.holdRecording)
        Sounds.play("Pop")
    }

    /// User context prompt plus light per-app context, so the model can adapt
    /// jargon and tone to where the text is going (e.g. code vs prose).
    private func composedContextPrompt() -> String {
        var parts: [String] = []
        let userPrompt = Prefs.transcriptionPrompt
        if !userPrompt.isEmpty {
            parts.append(userPrompt)
        }
        if let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName {
            parts.append("The user is dictating into the macOS app \"\(frontApp)\".")
        }
        return parts.joined(separator: " ")
    }

    private func finishSession() {
        guard phase.isRecording else { return }
        audio.stop()
        level = 0
        recordingEndedAt = Date()
        setPhase(.finishing)
        Sounds.play("Tink")
        client?.finish()
    }

    private func completeFinish() {
        let finalText = insertedText
        let didInsert = !finalText.isEmpty
        teardownSession()
        if didInsert {
            history.insert(DictationRecord(text: finalText, date: Date()), at: 0)
            if history.count > 20 {
                history.removeLast(history.count - 20)
            }
            flashDone = true
            let work = DispatchWorkItem { [weak self] in self?.flashDone = false }
            flashWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
        }
    }

    private func cancelSession() {
        pendingTapWork?.cancel()
        pendingTapWork = nil
        client?.cancel()
        teardownSession()
    }

    private func teardownSession() {
        mediaPauser.resumePausedPlayers()
        audio.stop()
        client = nil
        level = 0
        previewText = ""
        deltaText = ""
        itemTyped = ""
        interimText = ""
        sessionReady = false
        recordingStartedAt = nil
        recordingEndedAt = nil
        setPhase(.idle)
    }

    // MARK: - Transcript handling

    private func handleDelta(_ delta: String) {
        switch Prefs.insertionMethod {
        case .type:
            // Live dictation: deltas are typed into the frontmost app as they
            // arrive (gpt-live-transcribe deltas are append-only).
            var text = delta
            if itemTyped.isEmpty, needsJoiningSpace(before: text) {
                text = " " + text
            }
            TextInserter.insert(text)
            itemTyped += text
            insertedText += text
        case .paste:
            deltaText += delta
        }
        updatePreview()
    }

    private func handleCompleted(_ transcript: String) {
        guard phase.isRecording || phase == .finishing else { return }
        interimText = ""

        switch Prefs.insertionMethod {
        case .type:
            // Deltas were already typed; the final transcript should extend
            // them — type only the missing tail. If the model revised earlier
            // text instead, the typed text stands (we can't retro-edit).
            let typed = itemTyped.hasPrefix(" ") ? String(itemTyped.dropFirst()) : itemTyped
            itemTyped = ""
            if typed.isEmpty {
                insertSegment(transcript)
            } else if transcript.hasPrefix(typed) {
                let tail = String(transcript.dropFirst(typed.count))
                if !tail.isEmpty {
                    TextInserter.insert(tail)
                    insertedText += tail
                }
            }
        case .paste:
            deltaText = ""
            insertSegment(transcript)
        }
        updatePreview()
    }

    private func insertSegment(_ transcript: String) {
        let segment = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !segment.isEmpty else { return }
        var toInsert = segment
        if needsJoiningSpace(before: segment) {
            toInsert = " " + segment
        }
        TextInserter.insert(toInsert)
        insertedText += toInsert
    }

    private func needsJoiningSpace(before text: String) -> Bool {
        guard let last = insertedText.last, let first = text.first else { return false }
        return !last.isWhitespace && !first.isWhitespace && !first.isPunctuation
    }

    private func updatePreview() {
        var combined = insertedText + deltaText
        if !interimText.isEmpty {
            combined += (combined.isEmpty ? "" : " ") + interimText
        }
        previewText = String(combined.suffix(120))
    }

    func clearHistory() {
        history.removeAll()
    }

    // MARK: - Errors

    func showError(_ message: String) {
        Sounds.play("Basso", volume: 0.3)
        errorMessage = message
        errorDismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.errorMessage = nil }
        errorDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: work)
    }

    // MARK: - Settings actions

    func beginHotkeyCapture() {
        guard !capturingHotkey else { return }
        capturingHotkey = true
        hotkey.beginCapture { [weak self] code in
            DispatchQueue.main.async {
                guard let self else { return }
                self.capturingHotkey = false
                guard let code else { return }
                Prefs.hotkeyKeyCode = code
                self.hotkey.keyCode = code
                self.hotkeyName = KeyNames.name(for: code)
            }
        }
    }

    func cancelHotkeyCapture() {
        guard capturingHotkey else { return }
        hotkey.cancelCapture()
    }

    func overlayPositionChanged() {
        overlay?.reposition()
        overlayPreview = true
        previewWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.overlayPreview = false }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }
}
