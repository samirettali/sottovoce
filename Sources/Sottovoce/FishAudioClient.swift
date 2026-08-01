import Foundation

/// Batch transcription via Fish Audio's native ASR endpoint.
///
/// Fish Audio has no realtime/WebSocket ASR: PCM chunks are buffered in
/// memory during dictation and uploaded as one WAV on finish(), so the whole
/// transcript arrives at once (no live deltas).
final class FishAudioClient: TranscriptionSession {
    var onReady: (() -> Void)?
    var onDelta: ((String) -> Void)?
    var onCompleted: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onFinished: (() -> Void)?

    private let apiKey: String
    private let language: String?
    private let queue = DispatchQueue(label: "dev.samir.sottovoce.fish")

    private var pcm = Data()
    private var finished = false
    private var cancelled = false

    /// 24 kHz * 2 bytes/sample → 48 kB/s; cap the buffer at 30 minutes.
    private let maxBytes = 30 * 60 * 48_000

    init(apiKey: String, language: String?) {
        self.apiKey = apiKey
        self.language = language
    }

    func connect() {
        // Nothing to set up; recording can start immediately.
        DispatchQueue.main.async { self.onReady?() }
    }

    func sendAudio(_ chunk: Data) {
        queue.async {
            guard !self.finished, !self.cancelled, self.pcm.count < self.maxBytes else { return }
            self.pcm.append(chunk)
        }
    }

    func finish() {
        queue.async {
            guard !self.finished, !self.cancelled else { return }
            self.finished = true
            // Less than ~100 ms of audio is silence or a stray tap.
            guard self.pcm.count > 4_800 else {
                DispatchQueue.main.async { self.onFinished?() }
                return
            }
            self.upload(wav: Self.wavFile(pcm: self.pcm, sampleRate: 24_000, channels: 1))
        }
    }

    func cancel() {
        queue.async {
            self.cancelled = true
            self.pcm.removeAll()
        }
    }

    // MARK: - Upload

    private func upload(wav: Data) {
        var request = URLRequest(url: URL(string: "https://api.fish.audio/v1/asr")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "sottovoce-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendLine(_ string: String) { body.append(Data(string.utf8)) }
        if let language, !language.isEmpty {
            appendLine("--\(boundary)\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\n\(language)\r\n")
        }
        appendLine("--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(wav)
        appendLine("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self, !self.cancelled else { return }
            DispatchQueue.main.async {
                defer { self.onFinished?() }
                if let error {
                    self.onError?("Fish Audio upload failed: \(error.localizedDescription)")
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, let data else {
                    switch status {
                    case 401, 403:
                        self.onError?("Fish Audio rejected the request — check your API key.")
                    case 402:
                        self.onError?("Fish Audio: insufficient credits — top up at fish.audio.")
                    default:
                        self.onError?("Fish Audio returned HTTP \(status).")
                    }
                    return
                }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let text = json["text"] as? String
                else {
                    self.onError?("Unexpected response from Fish Audio.")
                    return
                }
                self.onCompleted?(text)
            }
        }.resume()
    }

    // MARK: - WAV

    private static func wavFile(pcm: Data, sampleRate: UInt32, channels: UInt16) -> Data {
        let bytesPerSample: UInt16 = 2
        let byteRate = sampleRate * UInt32(channels) * UInt32(bytesPerSample)
        let blockAlign = channels * bytesPerSample

        var data = Data()
        func append(_ string: String) { data.append(Data(string.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        append("RIFF")
        append32(UInt32(36 + pcm.count))
        append("WAVE")
        append("fmt ")
        append32(16)
        append16(1) // PCM
        append16(channels)
        append32(sampleRate)
        append32(byteRate)
        append16(blockAlign)
        append16(bytesPerSample * 8)
        append("data")
        append32(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}
