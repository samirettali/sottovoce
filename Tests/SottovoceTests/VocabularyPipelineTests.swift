import XCTest
@testable import Sottovoce

final class VocabularyPipelineTests: XCTestCase {
    private func rule(_ phrase: String, _ replacement: String) -> VocabularyRule {
        VocabularyRule(phrase: phrase, replacement: replacement)
    }

    private func text(_ events: [VocabularyEvent]) -> String {
        events.map { event -> String in
            switch event {
            case .text(let text): return text
            }
        }.joined()
    }

    // MARK: Whole transcript

    func testReplacesWholeWordsCaseInsensitively() {
        let pipeline = VocabularyPipeline(rules: [rule("beatwarden", "Bitwarden")], fillers: [])
        XCTAssertEqual(text(pipeline.process("apro Beatwarden, poi beatwardenx")), "apro Bitwarden, poi beatwardenx")
    }

    func testMultiWordPhraseKeepsSurroundingPunctuation() {
        let pipeline = VocabularyPipeline(rules: [rule("next js", "Next.js")], fillers: [])
        XCTAssertEqual(text(pipeline.process("uso (next js), ok")), "uso (Next.js), ok")
    }

    func testLongestPhraseWins() {
        let pipeline = VocabularyPipeline(
            rules: [rule("next js", "Next.js"), rule("next js runtime", "the Next.js runtime")], fillers: [])
        XCTAssertEqual(text(pipeline.process("next js runtime")), "the Next.js runtime")
    }

    func testSentenceInitialReplacementFollowsTheModelsCapital() {
        let pipeline = VocabularyPipeline(rules: [rule("linkedin", "linkding")], fillers: [])
        XCTAssertEqual(text(pipeline.process("Linkedin è ok. linkedin pure. Linkedin.")), "Linkding è ok. linkding pure. Linkding.")
    }

    func testMultilineSnippet() {
        let pipeline = VocabularyPipeline(rules: [rule("mail signature", "Ciao,\nSamir")], fillers: [])
        XCTAssertEqual(text(pipeline.process("fine. mail signature")), "fine. Ciao,\nSamir")
    }

    // MARK: Fillers

    func testRemovesFillersAndCollapsesWhitespace() {
        let pipeline = VocabularyPipeline(rules: [], fillers: ["ehm", "uhm"])
        XCTAssertEqual(text(pipeline.process("ciao ehm come uhm va")), "ciao come va")
    }

    func testSentenceInitialFillerCapitalisesTheNextWord() {
        let pipeline = VocabularyPipeline(rules: [], fillers: ["ehm"])
        XCTAssertEqual(text(pipeline.process("Ehm, ciao. Ehm allora")), "Ciao. Allora")
    }

    func testFillerAfterExistingTextIsNotSentenceInitial() {
        let pipeline = VocabularyPipeline(rules: [], fillers: ["ehm"], sentenceStart: false)
        XCTAssertEqual(text(pipeline.process("ehm ciao")), "ciao")
    }

    func testDisabledPipelinePassesTextThrough() {
        let pipeline = VocabularyPipeline(rules: [], fillers: [])
        XCTAssertTrue(pipeline.isEmpty)
        XCTAssertEqual(pipeline.push("par"), [.text("par")])
        XCTAssertEqual(pipeline.flush(), [])
    }

    // MARK: Live holdback

    func testHoldsBackTheLastWordsUntilTheyAreSafe() {
        let pipeline = VocabularyPipeline(rules: [rule("gpt trascribe", "gpt-transcribe")], fillers: [])
        // "uso" cannot start a two-word phrase ending in "gpt": released.
        XCTAssertEqual(text(pipeline.push("uso gpt ")), "uso")
        XCTAssertEqual(pipeline.pending, " gpt ")
        // "trasc" is still open, and "gpt" may be the head of a phrase.
        XCTAssertEqual(text(pipeline.push("trasc")), "")
        XCTAssertEqual(text(pipeline.push("ribe sempre")), " gpt-transcribe")
        XCTAssertEqual(pipeline.pending, " sempre")
        XCTAssertEqual(text(pipeline.flush()), " sempre")
        XCTAssertEqual(pipeline.pending, "")
    }

    func testMatchAcrossDeltaBoundaryEqualsWholeTranscript() {
        let rules = [rule("gpt trascribe", "gpt-transcribe")]
        let whole = VocabularyPipeline(rules: rules, fillers: []).process("uso gpt trascribe, sempre")
        let live = VocabularyPipeline(rules: rules, fillers: [])
        var events: [VocabularyEvent] = []
        for delta in ["u", "so g", "pt tr", "ascribe", ", sem", "pre"] { events += live.push(delta) }
        events += live.flush()
        XCTAssertEqual(text(events), text(whole))
        XCTAssertEqual(text(events), "uso gpt-transcribe, sempre")
    }

    func testAnOpenWordIsNeverMatched() {
        let pipeline = VocabularyPipeline(rules: [rule("ok", "OK")], fillers: [])
        XCTAssertEqual(text(pipeline.push("ok")), "")
        XCTAssertEqual(text(pipeline.push("ay ")), "okay")
    }

    func testFlushReleasesTrailingWhitespace() {
        let pipeline = VocabularyPipeline(rules: [rule("a", "b")], fillers: [])
        XCTAssertEqual(text(pipeline.push("x ")), "x")
        XCTAssertEqual(text(pipeline.flush()), " ")
    }
}
