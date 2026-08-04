import AppKit
import SwiftUI
import Carbon.HIToolbox
import Security

// MARK: - Preferences

enum TranscriptionProvider: String, CaseIterable, Identifiable {
    case openai
    case deepgram
    case groq
    case fishAudio
    case parakeet

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .deepgram: return "Deepgram"
        case .groq: return "Groq"
        case .fishAudio: return "Fish Audio"
        case .parakeet: return "On-device"
        }
    }

    var menuLabel: String {
        switch self {
        case .openai: return "OpenAI — gpt-live-transcribe (live)"
        case .deepgram: return "Deepgram — nova-3 (streaming)"
        case .groq: return "Groq — Whisper large-v3 turbo (batch)"
        case .fishAudio: return "Fish Audio — ASR (batch)"
        case .parakeet: return "On-device — Parakeet TDT v3 (offline)"
        }
    }

    /// Local providers have nothing to authenticate against.
    var requiresAPIKey: Bool { self != .parakeet }

    var keychainAccount: String {
        switch self {
        case .openai: return "openai-api-key"
        case .deepgram: return "deepgram-api-key"
        case .groq: return "groq-api-key"
        case .fishAudio: return "fishaudio-api-key"
        case .parakeet: return "parakeet-unused"
        }
    }

    struct Capabilities {
        /// When and how text lands in the target app.
        let insertion: String
        /// Live transcript preview in the overlay while speaking.
        let livePreview: Bool
        /// Multiple languages mixed within one dictation (code-switching).
        let codeSwitching: Bool
        /// How the Languages hint field is interpreted.
        let languageHints: String
        let keywords: Bool
        let contextPrompt: Bool
        let delayTuning: Bool
        let pricing: String
    }

    var capabilities: Capabilities {
        switch self {
        case .openai:
            return Capabilities(
                insertion: "Word by word",
                livePreview: true,
                codeSwitching: true,
                languageHints: "Several",
                keywords: true,
                contextPrompt: true,
                delayTuning: true,
                pricing: "$0.017/min"
            )
        case .deepgram:
            return Capabilities(
                insertion: "By phrase",
                livePreview: true,
                codeSwitching: true,
                languageHints: "Multi or one",
                keywords: true,
                contextPrompt: false,
                delayTuning: false,
                pricing: "~$0.007/min"
            )
        case .groq:
            return Capabilities(
                insertion: "On stop, fast",
                livePreview: false,
                codeSwitching: false,
                languageHints: "One or auto",
                keywords: true,
                contextPrompt: true,
                delayTuning: false,
                pricing: "~Free"
            )
        case .fishAudio:
            return Capabilities(
                insertion: "On stop",
                livePreview: false,
                codeSwitching: false,
                languageHints: "One or auto",
                keywords: false,
                contextPrompt: false,
                delayTuning: false,
                pricing: "Credits"
            )
        case .parakeet:
            // Multilingual within its 25 European languages, but a language
            // hint only biases token filtering — it doesn't gate detection.
            return Capabilities(
                insertion: "On stop, local",
                livePreview: false,
                codeSwitching: true,
                languageHints: "One or auto",
                keywords: false,
                contextPrompt: false,
                delayTuning: false,
                pricing: "Free"
            )
        }
    }
}

enum PrefKey {
    static let provider = "provider"
    static let hotkeyKeyCode = "hotkeyKeyCode"
    static let overlayPosition = "overlayPosition"
    static let showIdleOverlay = "showIdleOverlay"
    static let insertionMethod = "insertionMethod"
    static let playSounds = "playSounds"
    static let pauseMediaWhileDictating = "pauseMediaWhileDictating"
    static let languages = "languages"
    static let transcriptionPrompt = "transcriptionPrompt"
    static let transcriptionKeywords = "transcriptionKeywords"
    static let transcriptionDelay = "transcriptionDelay"
}

enum TranscriptionDelay: String, CaseIterable, Identifiable {
    case apiDefault = ""
    case minimal, low, medium, high, xhigh

    var id: String { rawValue }
    var label: String {
        switch self {
        case .apiDefault: return "Default"
        case .minimal: return "Minimal — fastest"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra high — most accurate"
        }
    }
}

enum InsertionMethod: String, CaseIterable, Identifiable {
    case type
    case paste
    var id: String { rawValue }
    var label: String {
        switch self {
        case .type: return "Type live as you speak"
        case .paste: return "Paste when you stop"
        }
    }
}

enum OverlayPosition: String, CaseIterable, Identifiable {
    case topLeft, topCenter, topRight
    case bottomLeft, bottomCenter, bottomRight

    var id: String { rawValue }

    var alignment: Alignment {
        switch self {
        case .topLeft: return .topLeading
        case .topCenter: return .top
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomCenter: return .bottom
        case .bottomRight: return .bottomTrailing
        }
    }

    var isTop: Bool {
        switch self {
        case .topLeft, .topCenter, .topRight: return true
        default: return false
        }
    }

    func origin(panelSize: CGSize, in visibleFrame: CGRect) -> CGPoint {
        let x: CGFloat
        switch self {
        case .topLeft, .bottomLeft:
            x = visibleFrame.minX
        case .topCenter, .bottomCenter:
            x = visibleFrame.midX - panelSize.width / 2
        case .topRight, .bottomRight:
            x = visibleFrame.maxX - panelSize.width
        }
        let y = isTop ? visibleFrame.maxY - panelSize.height : visibleFrame.minY
        return CGPoint(x: x, y: y)
    }
}

enum Prefs {
    static let defaults = UserDefaults.standard

    static func registerDefaults() {
        defaults.register(defaults: [
            PrefKey.provider: TranscriptionProvider.openai.rawValue,
            PrefKey.hotkeyKeyCode: 61, // Right Option
            PrefKey.overlayPosition: OverlayPosition.bottomCenter.rawValue,
            PrefKey.showIdleOverlay: false,
            PrefKey.insertionMethod: InsertionMethod.type.rawValue,
            PrefKey.playSounds: true,
            PrefKey.pauseMediaWhileDictating: false,
            PrefKey.languages: "",
            PrefKey.transcriptionPrompt: "",
            PrefKey.transcriptionKeywords: "",
            PrefKey.transcriptionDelay: "",
        ])
    }

    static var provider: TranscriptionProvider {
        get { TranscriptionProvider(rawValue: defaults.string(forKey: PrefKey.provider) ?? "") ?? .openai }
        set { defaults.set(newValue.rawValue, forKey: PrefKey.provider) }
    }

    static var hotkeyKeyCode: CGKeyCode {
        get { CGKeyCode(defaults.integer(forKey: PrefKey.hotkeyKeyCode)) }
        set { defaults.set(Int(newValue), forKey: PrefKey.hotkeyKeyCode) }
    }

    static var overlayPosition: OverlayPosition {
        get { OverlayPosition(rawValue: defaults.string(forKey: PrefKey.overlayPosition) ?? "") ?? .bottomCenter }
        set { defaults.set(newValue.rawValue, forKey: PrefKey.overlayPosition) }
    }

    static var insertionMethod: InsertionMethod {
        get { InsertionMethod(rawValue: defaults.string(forKey: PrefKey.insertionMethod) ?? "") ?? .paste }
        set { defaults.set(newValue.rawValue, forKey: PrefKey.insertionMethod) }
    }

    static var playSounds: Bool {
        get { defaults.bool(forKey: PrefKey.playSounds) }
        set { defaults.set(newValue, forKey: PrefKey.playSounds) }
    }

    static var pauseMediaWhileDictating: Bool {
        get { defaults.bool(forKey: PrefKey.pauseMediaWhileDictating) }
        set { defaults.set(newValue, forKey: PrefKey.pauseMediaWhileDictating) }
    }

    /// Optional comma-separated ISO language hints, e.g. "en, it".
    static var languages: [String] {
        get {
            (defaults.string(forKey: PrefKey.languages) ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        }
        set { defaults.set(newValue.joined(separator: ", "), forKey: PrefKey.languages) }
    }

    /// Optional free-text context for the transcription (recording setting, topic…).
    static var transcriptionPrompt: String {
        get { (defaults.string(forKey: PrefKey.transcriptionPrompt) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        set { defaults.set(newValue, forKey: PrefKey.transcriptionPrompt) }
    }

    /// Optional comma-separated literal terms (product names, acronyms…).
    /// The API forbids `<`, `>` and newlines inside keywords.
    static var transcriptionKeywords: [String] {
        get {
            (defaults.string(forKey: PrefKey.transcriptionKeywords) ?? "")
                .split(separator: ",")
                .map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "<", with: "")
                        .replacingOccurrences(of: ">", with: "")
                }
                .filter { !$0.isEmpty }
        }
        set { defaults.set(newValue.joined(separator: ", "), forKey: PrefKey.transcriptionKeywords) }
    }

    /// Latency/quality trade-off; empty string means the API default.
    static var transcriptionDelay: TranscriptionDelay {
        get { TranscriptionDelay(rawValue: defaults.string(forKey: PrefKey.transcriptionDelay) ?? "") ?? .apiDefault }
        set { defaults.set(newValue.rawValue, forKey: PrefKey.transcriptionDelay) }
    }
}

// MARK: - Keychain

enum KeychainStore {
    private static let service = "dev.samir.sottovoce"

    private static func baseQuery(for provider: TranscriptionProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.keychainAccount,
        ]
    }

    static func loadAPIKey(for provider: TranscriptionProvider) -> String? {
        var query = baseQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func saveAPIKey(_ key: String, for provider: TranscriptionProvider) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            deleteAPIKey(for: provider)
            return
        }
        // Delete + add instead of update-in-place: recreating the item makes
        // the current app its owner, so reads never prompt. An update would
        // keep the ACL of whichever (possibly older-signed) build created it.
        deleteAPIKey(for: provider)
        var query = baseQuery(for: provider)
        query[kSecValueData as String] = Data(trimmed.utf8)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func deleteAPIKey(for provider: TranscriptionProvider) {
        SecItemDelete(baseQuery(for: provider) as CFDictionary)
    }
}

// MARK: - Sounds

enum Sounds {
    static func play(_ name: String, volume: Float = 0.4) {
        guard Prefs.playSounds else { return }
        guard let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = volume
        sound.play()
    }
}

// MARK: - Key names

enum KeyNames {
    static let modifierMasks: [CGKeyCode: CGEventFlags] = [
        54: .maskCommand, 55: .maskCommand,
        56: .maskShift, 60: .maskShift,
        58: .maskAlternate, 61: .maskAlternate,
        59: .maskControl, 62: .maskControl,
        63: .maskSecondaryFn,
    ]

    static func isModifier(_ code: CGKeyCode) -> Bool {
        modifierMasks[code] != nil
    }

    private static let special: [CGKeyCode: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
        54: "Right ⌘", 55: "Left ⌘",
        56: "Left ⇧", 60: "Right ⇧",
        58: "Left ⌥", 61: "Right ⌥",
        59: "Left ⌃", 62: "Right ⌃",
        63: "fn",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        116: "Page Up", 121: "Page Down", 115: "Home", 119: "End",
        117: "Fwd Delete", 71: "Clear", 76: "Enter",
    ]

    static func name(for code: CGKeyCode) -> String {
        if let name = special[code] { return name }
        if let char = layoutCharacter(for: code) { return char }
        return "Key \(code)"
    }

    private static func layoutCharacter(for code: CGKeyCode) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState, chars.count, &length, &chars
            )
        }
        guard status == noErr, length > 0 else { return nil }
        let result = String(utf16CodeUnits: chars, count: length)
        return result.isEmpty ? nil : result.uppercased()
    }
}
