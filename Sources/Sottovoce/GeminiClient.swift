import Foundation

/// Batch transcription with `gemini-3.5-transcribe` over the Interactions API.
///
/// A normal dictation goes inline: base64 in the request, one round trip. The
/// docs only show audio passed by reference, but inline `data` works and skips
/// an upload — it just can't carry a long one, since the request as a whole is
/// capped around 20 MB and base64 inflates by a third. Past that the dictation
/// goes through the Files API instead (resumable upload, start then
/// upload+finalize) and the returned URI is what gets transcribed; the file is
/// deleted right after use, and would expire on its own within 48 hours.
final class GeminiClient: BatchTranscriptionClient {
    private let apiKey: String
    private let languages: [String]
    private let keywords: [String]

    private static let base = "https://generativelanguage.googleapis.com"
    /// WAV bytes that still fit inline once base64-encoded: ~4 minutes of the
    /// 24 kHz mono PCM16 the capture produces.
    private static let inlineLimit = 12 * 1_024 * 1_024

    init(apiKey: String, languages: [String], keywords: [String]) {
        self.apiKey = apiKey
        self.languages = languages
        self.keywords = keywords
    }

    override var providerName: String { "Gemini" }

    override func processBuffer(_ pcm: Data) {
        let wav = Self.wavFile(pcm: pcm, sampleRate: 24_000, channels: 1)
        Task {
            do {
                if wav.count <= Self.inlineLimit {
                    deliver(try await transcribe(audio: [
                        "type": "audio", "mime_type": "audio/wav",
                        "data": wav.base64EncodedString(),
                    ]))
                } else {
                    let file = try await uploadFile(wav)
                    defer { Task { try? await deleteFile(named: file.name) } }
                    deliver(try await transcribe(audio: [
                        "type": "audio", "mime_type": "audio/wav", "uri": file.uri,
                    ]))
                }
            } catch let error as GeminiError {
                fail(error.message)
            } catch {
                fail("Gemini request failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Files API

    private struct UploadedFile {
        /// `files/abc123`, the handle used to poll and delete.
        let name: String
        let uri: String
    }

    private struct GeminiError: Error {
        let message: String
    }

    private func request(_ url: URL, method: String = "POST") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        return request
    }

    private func uploadFile(_ wav: Data) async throws -> UploadedFile {
        var start = request(URL(string: "\(Self.base)/upload/v1beta/files")!)
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue("\(wav.count)", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue("audio/wav", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        start.httpBody = try JSONSerialization.data(
            withJSONObject: ["file": ["display_name": "dictation"]]
        )

        let (_, startResponse) = try await URLSession.shared.data(for: start)
        let http = startResponse as? HTTPURLResponse
        guard let http, http.statusCode == 200 else {
            throw GeminiError(message: Self.uploadError(status: http?.statusCode ?? 0))
        }
        // Case-insensitive: the header comes back lowercased over HTTP/2.
        guard let location = http.value(forHTTPHeaderField: "X-Goog-Upload-URL"),
              let uploadURL = URL(string: location)
        else {
            throw GeminiError(message: "Gemini did not return an upload URL.")
        }

        var upload = request(uploadURL)
        upload.setValue("\(wav.count)", forHTTPHeaderField: "Content-Length")
        upload.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        upload.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        upload.httpBody = wav

        let (data, response) = try await URLSession.shared.data(for: upload)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let file = json["file"] as? [String: Any],
              let name = file["name"] as? String,
              let uri = file["uri"] as? String
        else {
            throw GeminiError(message: Self.uploadError(status: status))
        }
        // Short audio is usually ACTIVE straight away; a long dictation may
        // still be PROCESSING, and the Interactions API rejects it until it
        // isn't.
        if file["state"] as? String == "PROCESSING" {
            try await waitUntilActive(name: name)
        }
        return UploadedFile(name: name, uri: uri)
    }

    private func waitUntilActive(name: String) async throws {
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 500_000_000)
            let (data, _) = try await URLSession.shared.data(
                for: request(URL(string: "\(Self.base)/v1beta/\(name)")!, method: "GET")
            )
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            switch json?["state"] as? String {
            case "ACTIVE": return
            case "FAILED": throw GeminiError(message: "Gemini could not process the audio.")
            default: continue
            }
        }
        throw GeminiError(message: "Gemini is still processing the audio — try again.")
    }

    private func deleteFile(named name: String) async throws {
        _ = try await URLSession.shared.data(
            for: request(URL(string: "\(Self.base)/v1beta/\(name)")!, method: "DELETE")
        )
    }

    // MARK: - Interactions API

    private func transcribe(audio: [String: String]) async throws -> String {
        var config: [String: Any] = [
            // Empty means auto-detection across 85+ languages.
            "language_codes": languages,
            // Smart formatting cleans up disfluencies; it rules out word
            // timestamps and diarization, neither of which a dictation needs.
            "mode": ["type": "smart"],
        ]
        if !keywords.isEmpty {
            config["custom_vocabulary"] = Array(keywords.prefix(1_000))
        }
        let body: [String: Any] = [
            "model": "gemini-3.5-transcribe",
            "input": [audio],
            "generation_config": ["transcription_config": config],
        ]

        var interaction = request(URL(string: "\(Self.base)/v1beta/interactions")!)
        interaction.setValue("application/json", forHTTPHeaderField: "Content-Type")
        interaction.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: interaction)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw GeminiError(message: errorMessage(forStatus: status))
        }
        guard let text = Self.transcript(from: data) else {
            throw GeminiError(message: "Unexpected response from Gemini.")
        }
        return text
    }

    /// The transcript lives in `steps[].content[].text`. The `output_text` the
    /// docs mention is synthesised by the SDKs and is not on the wire.
    static func transcript(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let steps = json["steps"] as? [[String: Any]]
        else { return nil }
        let parts = steps
            .compactMap { $0["content"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["text"] as? String }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    override func errorMessage(forStatus status: Int) -> String {
        switch status {
        case 400: return "Gemini rejected the audio — check the Languages and Keywords settings."
        case 401, 403: return "Gemini rejected the request — check your API key."
        case 429: return "Gemini quota exhausted — check billing or wait for the free tier to reset."
        default: return "Gemini returned HTTP \(status)."
        }
    }

    private static func uploadError(status: Int) -> String {
        switch status {
        case 401, 403: return "Gemini rejected the upload — check your API key."
        case 429: return "Gemini quota exhausted — check billing or wait for the free tier to reset."
        default: return "Gemini upload failed (HTTP \(status))."
        }
    }
}
