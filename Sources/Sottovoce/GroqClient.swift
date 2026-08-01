import Foundation

/// Batch transcription via Groq's OpenAI-compatible Whisper endpoint.
/// Inference is fast enough that results feel near-instant on stop.
final class GroqClient: BatchTranscriptionClient {
    private let apiKey: String
    private let language: String?
    /// Whisper's prompt biases vocabulary/style; used for context + keywords.
    private let prompt: String?

    init(apiKey: String, language: String?, prompt: String?) {
        self.apiKey = apiKey
        self.language = language
        self.prompt = prompt
    }

    override var providerName: String { "Groq" }

    override func makeRequest(wav: Data) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var form = MultipartForm()
        form.addField(name: "model", value: "whisper-large-v3-turbo")
        form.addField(name: "response_format", value: "json")
        if let language, !language.isEmpty {
            form.addField(name: "language", value: language)
        }
        if let prompt, !prompt.isEmpty {
            form.addField(name: "prompt", value: prompt)
        }
        form.addFile(name: "file", filename: "dictation.wav", contentType: "audio/wav", data: wav)
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
        case 401, 403: return "Groq rejected the request — check your API key."
        case 429: return "Groq rate limit hit — wait a moment and retry."
        default: return "Groq returned HTTP \(status)."
        }
    }
}
