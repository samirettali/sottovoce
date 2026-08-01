import Foundation

/// Batch transcription via Fish Audio's native ASR endpoint.
/// Fish Audio has no realtime/WebSocket ASR (their streaming API is TTS-only).
final class FishAudioClient: BatchTranscriptionClient {
    private let apiKey: String
    private let language: String?

    init(apiKey: String, language: String?) {
        self.apiKey = apiKey
        self.language = language
    }

    override var providerName: String { "Fish Audio" }

    override func makeRequest(wav: Data) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.fish.audio/v1/asr")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var form = MultipartForm()
        if let language, !language.isEmpty {
            form.addField(name: "language", value: language)
        }
        form.addFile(name: "audio", filename: "dictation.wav", contentType: "audio/wav", data: wav)
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finalized()
        return request
    }

    override func parseTranscript(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["text"] as? String
    }

    override func errorMessage(forStatus status: Int) -> String {
        switch status {
        case 401, 403: return "Fish Audio rejected the request — check your API key."
        case 402: return "Fish Audio: insufficient credits — top up at fish.audio."
        default: return "Fish Audio returned HTTP \(status)."
        }
    }
}
