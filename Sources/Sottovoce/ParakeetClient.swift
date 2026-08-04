import Foundation
import FluidAudio

/// On-device batch transcription with Parakeet TDT v3. Nothing leaves the
/// machine and there is no API key; audio is buffered while dictating and
/// transcribed locally on stop (~110× realtime on Apple Silicon, so a normal
/// dictation resolves in a fraction of a second).
final class ParakeetClient: BatchTranscriptionClient {
    private let language: Language?

    /// `languageHint` is an ISO code from the Languages setting; unsupported
    /// codes are ignored and the model auto-detects.
    init(languageHint: String?) {
        self.language = languageHint.flatMap { Language(rawValue: $0) }
    }

    override var providerName: String { "Parakeet" }

    override func processBuffer(_ pcm: Data) {
        Task {
            do {
                let text = try await ParakeetEngine.shared.transcribe(pcm24k: pcm, language: language)
                deliver(text)
            } catch {
                fail("On-device transcription failed: \(error.localizedDescription)")
            }
        }
    }
}
