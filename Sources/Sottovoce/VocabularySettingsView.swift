import SwiftUI

/// Settings → Vocabulary: the filler list and the replacement rules that
/// `VocabularyPipeline` applies to every provider's output.
struct VocabularySettingsView: View {
    @AppStorage(PrefKey.removeFillers) private var removeFillers = true
    @AppStorage(PrefKey.fillerWords) private var fillerWordsRaw = ""
    @State private var rules = Prefs.vocabularyRules

    var body: some View {
        Form {
            fillersSection
            rulesSection
        }
        .formStyle(.grouped)
        .onChange(of: rules) { _, rules in
            Prefs.vocabularyRules = rules
        }
    }

    private var fillersSection: some View {
        Section {
            Toggle("Remove filler words", isOn: $removeFillers)
            TextField("Filler words", text: $fillerWordsRaw, prompt: Text("e.g. ehm, uhm, um, uh"))
                .disabled(!removeFillers)
        } header: {
            Text("Fillers")
        } footer: {
            Text("Whole words dropped from the transcript, comma-separated. A filler that opened a sentence hands its capital to the next word. Off, the transcript is inserted as the provider sent it.")
        }
    }

    private var rulesSection: some View {
        Section {
            ForEach($rules) { $rule in
                HStack(alignment: .firstTextBaseline) {
                    TextField("Phrase", text: $rule.phrase, prompt: Text("what was heard"))
                    Picker("Action", selection: $rule.kind) {
                        ForEach(VocabularyRule.Kind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .fixedSize()
                    switch rule.kind {
                    case .replace:
                        TextField("Replacement", text: $rule.replacement, prompt: Text("what to insert"), axis: .vertical)
                            .lineLimit(1...4)
                    case .key:
                        Picker("Key", selection: $rule.key) {
                            ForEach(KeyCommand.allCases) { key in
                                Text(key.label).tag(key)
                            }
                        }
                    }
                    Button {
                        rules.removeAll { $0.id == rule.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this rule")
                }
                .labelsHidden()
            }
            Button("Add rule") {
                rules.append(VocabularyRule())
            }
        } header: {
            Text("Rules")
        } footer: {
            Text("Fix what the provider keeps mishearing (\"beatwarden\" → \"Bitwarden\"), whatever the provider. Phrases match whole words, ignoring case, and may span several words (\"next js\" → \"Next.js\"). A replacement may be long or multi-line, so a short phrase can expand to a whole block. A rule that presses a key is a voice command: say \"a capo\" and Return is pressed instead. Live typing waits for as many words as the longest phrase before inserting, so a phrase split across two deltas is still caught.")
        }
    }
}
