import Foundation

/// A user rule: a spoken phrase and what to insert in its place.
///
/// A replacement is the corrective layer for recurring mishearings that the
/// provider's Keywords don't prevent ("beatwarden" → "Bitwarden"). A snippet is
/// the same thing with a long or multi-line output ("mail signature" → the
/// block). Matching is case-insensitive, on whole words, and a phrase may span
/// several words.
struct VocabularyRule: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        /// Insert `replacement` in place of the phrase.
        case replace
        /// Press `key` instead of typing the phrase: a voice command.
        case key

        var id: String { rawValue }
        var label: String {
            switch self {
            case .replace: return "Replace with"
            case .key: return "Press"
            }
        }
    }

    var id = UUID()
    var phrase = ""
    var kind = Kind.replace
    var replacement = ""
    var key = KeyCommand.return

    init(id: UUID = UUID(), phrase: String = "", replacement: String = "") {
        self.id = id
        self.phrase = phrase
        self.replacement = replacement
    }

    init(phrase: String, key: KeyCommand) {
        self.phrase = phrase
        self.kind = .key
        self.key = key
    }

    private enum CodingKeys: String, CodingKey { case id, phrase, kind, replacement, key }

    // Rules saved before voice commands existed have no `kind` or `key`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        phrase = try container.decode(String.self, forKey: .phrase)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .replace
        replacement = try container.decodeIfPresent(String.self, forKey: .replacement) ?? ""
        key = try container.decodeIfPresent(KeyCommand.self, forKey: .key) ?? .return
    }

    /// The it/en voice commands every install starts with.
    static let defaultCommands: [VocabularyRule] = [
        VocabularyRule(phrase: "a capo", key: .return),
        VocabularyRule(phrase: "nuovo paragrafo", key: .doubleReturn),
        VocabularyRule(phrase: "new line", key: .return),
        VocabularyRule(phrase: "new paragraph", key: .doubleReturn),
    ]
}

/// A keystroke a voice command synthesises instead of text.
enum KeyCommand: String, Codable, CaseIterable, Identifiable {
    case `return`
    case doubleReturn
    case tab
    case commandReturn

    var id: String { rawValue }
    var label: String {
        switch self {
        case .return: return "Return"
        case .doubleReturn: return "Return twice"
        case .tab: return "Tab"
        case .commandReturn: return "⌘ Return"
        }
    }
}

/// What the pipeline produces for insertion, in order.
enum VocabularyEvent: Equatable {
    case text(String)
    case key(KeyCommand)
}

/// Local text cleanup between the provider and insertion: filler removal and
/// the user's replacement rules, with the whitespace normalisation both need.
///
/// It is a pure text transform with one piece of state: text pushed live is
/// **held back** by up to the longest rule's word count, because deltas are
/// typed as they arrive and a phrase that straddles two deltas could not be
/// fixed once its first half is already in the target app. `push` returns what
/// is safe to insert now; `flush` returns the rest once the transcript is
/// final. Paste mode simply pushes the whole transcript and flushes.
final class VocabularyPipeline {
    private struct Compiled {
        enum Output {
            case text(String)
            case key(KeyCommand)
        }

        let words: [String]
        let output: Output
    }

    private let rules: [Compiled]
    private let holdback: Int
    private var held = ""
    /// Whether the next word starts a sentence: set after `.`, `!`, `?`, so a
    /// filler removed at the start of one ("Ehm, ciao" → "Ciao") leaves the
    /// following word capitalised.
    private var sentenceStart: Bool
    private var capitalizeNext = false
    /// A filler removed from the very start of the text takes the following
    /// word's leading whitespace with it, or the text would open with a space.
    private var dropNextLead = false

    /// - Parameter sentenceStart: whether the text already in the target ends a
    ///   sentence (or there is none), so a leading filler is treated as
    ///   sentence-initial.
    init(rules: [VocabularyRule], fillers: [String], sentenceStart: Bool = true) {
        var compiled: [Compiled] = []
        for rule in rules {
            let words = Self.words(of: rule.phrase)
            guard !words.isEmpty else { continue }
            switch rule.kind {
            case .replace: compiled.append(Compiled(words: words, output: .text(rule.replacement)))
            case .key: compiled.append(Compiled(words: words, output: .key(rule.key)))
            }
        }
        for filler in fillers {
            let words = Self.words(of: filler)
            guard !words.isEmpty else { continue }
            compiled.append(Compiled(words: words, output: .text("")))
        }
        // Longest phrase first, so "next js runtime" wins over "next js".
        self.rules = compiled.sorted { $0.words.count > $1.words.count }
        self.holdback = max(1, compiled.map(\.words.count).max() ?? 0)
        self.sentenceStart = sentenceStart
    }

    var isEmpty: Bool { rules.isEmpty }

    /// Text received but not yet released, for the preview.
    var pending: String { held }

    /// Append live text and return whatever can be inserted without waiting.
    func push(_ text: String) -> [VocabularyEvent] {
        guard !isEmpty else { return text.isEmpty ? [] : [.text(text)] }
        held += text
        return release(final: false)
    }

    /// Release everything: the transcript is final.
    func flush() -> [VocabularyEvent] {
        guard !isEmpty else { return [] }
        return release(final: true)
    }

    /// One-shot transform for a complete transcript.
    func process(_ text: String) -> [VocabularyEvent] {
        push(text) + flush()
    }

    // MARK: - Matching

    private struct Token {
        let start: String.Index
        let end: String.Index
        let lead: Substring
        let word: Substring
    }

    private func release(final: Bool) -> [VocabularyEvent] {
        let tokens = Self.tokenize(held)
        // The last word may still be growing unless whitespace closed it.
        let lastIsOpen = !final && !(held.last?.isWhitespace ?? true)
        let complete = lastIsOpen ? tokens.count - 1 : tokens.count

        var out = Emitter()
        var i = 0
        while i < tokens.count {
            // A phrase of `holdback` words starting here may not have fully
            // arrived; wait for the next delta rather than commit its head.
            if !final, i + holdback > complete { break }
            if let (count, output) = match(tokens, at: i, limit: complete) {
                emit(output, over: tokens[i..<i + count], into: &out)
                i += count
            } else {
                emit(tokens[i], into: &out)
                i += 1
            }
        }

        let remainderStart = i < tokens.count ? tokens[i].start : (tokens.last?.end ?? held.startIndex)
        if final {
            out.text(String(held[remainderStart...]))
            held = ""
        } else {
            held = String(held[remainderStart...])
        }
        return out.events
    }

    private func match(_ tokens: [Token], at index: Int, limit: Int) -> (Int, Compiled.Output)? {
        for rule in rules {
            let count = rule.words.count
            guard index + count <= limit else { continue }
            var hit = true
            for offset in 0..<count where Self.core(of: tokens[index + offset].word) != rule.words[offset] {
                hit = false
                break
            }
            if hit { return (count, rule.output) }
        }
        return nil
    }

    // MARK: - Emission

    private struct Emitter {
        private(set) var events: [VocabularyEvent] = []

        mutating func text(_ text: String) {
            guard !text.isEmpty else { return }
            if case .text(let previous)? = events.last {
                events[events.count - 1] = .text(previous + text)
            } else {
                events.append(.text(text))
            }
        }

        mutating func key(_ key: KeyCommand) {
            events.append(.key(key))
        }
    }

    private func emit(_ token: Token, into out: inout Emitter) {
        var word = String(token.word)
        if capitalizeNext {
            word = Self.capitalized(word)
            capitalizeNext = false
        }
        out.text(lead(of: token) + word)
        sentenceStart = Self.endsSentence(token.word)
    }

    private func emit(_ output: Compiled.Output, over tokens: ArraySlice<Token>, into out: inout Emitter) {
        guard let first = tokens.first, let last = tokens.last else { return }
        let replacement: String
        switch output {
        case .key(let key):
            // The keystroke replaces the phrase and the whitespace around it:
            // nothing should sit between the previous word and the Return.
            _ = lead(of: first)
            out.key(key)
            capitalizeNext = false
            dropNextLead = true
            return
        case .text(let text):
            replacement = text
        }
        if replacement.isEmpty {
            // A removed filler leaves the sentence where it was; if it opened
            // one, the next word takes over that role.
            if sentenceStart { capitalizeNext = true }
            if lead(of: first).isEmpty { dropNextLead = true }
            return
        }
        let prefix = Self.leadingPunctuation(of: first.word)
        var suffix = Self.trailingPunctuation(of: last.word)
        var text = replacement
        // Carry the model's capitalisation: a rule written in lowercase still
        // opens a sentence with a capital when the misheard word did.
        if (capitalizeNext || sentenceStart), first.word.first?.isUppercase == true {
            text = Self.capitalized(text)
        }
        capitalizeNext = false
        if replacement.last.map(Self.isTerminal) == true, suffix.first.map(Self.isTerminal) == true {
            suffix = ""
        }
        out.text(lead(of: first) + prefix + text + suffix)
        sentenceStart = Self.endsSentence(Substring(text + suffix))
    }

    private func lead(of token: Token) -> String {
        defer { dropNextLead = false }
        return dropNextLead ? "" : String(token.lead)
    }

    // MARK: - Text helpers

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            let start = index
            while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
            let wordStart = index
            while index < text.endIndex, !text[index].isWhitespace { index = text.index(after: index) }
            guard wordStart < index else { break }
            tokens.append(Token(start: start, end: index, lead: text[start..<wordStart], word: text[wordStart..<index]))
        }
        return tokens
    }

    private static func words(of phrase: String) -> [String] {
        phrase.split(whereSeparator: \.isWhitespace).map { core(of: $0) }.filter { !$0.isEmpty }
    }

    private static func isPunctuation(_ character: Character) -> Bool {
        character.isPunctuation || character.isSymbol
    }

    private static func isTerminal(_ character: Character) -> Bool {
        character == "." || character == "!" || character == "?"
    }

    /// The word without surrounding punctuation, lowercased for matching.
    private static func core(of word: Substring) -> String {
        word.drop(while: isPunctuation).reversed().drop(while: isPunctuation).reversed()
            .map(String.init).joined().lowercased()
    }

    private static func leadingPunctuation(of word: Substring) -> String {
        String(word.prefix(while: isPunctuation))
    }

    private static func trailingPunctuation(of word: Substring) -> String {
        String(word.reversed().prefix(while: isPunctuation).reversed())
    }

    private static func endsSentence(_ word: Substring) -> Bool {
        word.reversed().drop(while: { isPunctuation($0) && !isTerminal($0) }).first.map(isTerminal) ?? false
    }

    private static func capitalized(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
