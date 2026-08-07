import Foundation

/// Shared machinery for batch providers: PCM is buffered in memory during
/// dictation and turned into a transcript in one go on finish(), so the whole
/// text arrives as a single completed segment.
///
/// Remote providers override `makeRequest`/`parseTranscript` and get the
/// default WAV + multipart upload. On-device providers override
/// `processBuffer(_:)` instead and report through `deliver`/`fail`.
class BatchTranscriptionClient: TranscriptionSession {
    var onReady: (() -> Void)?
    var onDelta: ((String) -> Void)?
    var onInterim: ((String) -> Void)?
    var onCompleted: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onFinished: (() -> Void)?

    private let queue = DispatchQueue(label: "com.samirettali.sottovoce.batch")
    private var pcm = Data()
    private var finished = false
    private var cancelled = false

    /// 24 kHz * 2 bytes/sample → 48 kB/s; cap the buffer at 30 minutes.
    private let maxBytes = 30 * 60 * 48_000

    // MARK: - Override points

    var providerName: String { "Provider" }

    /// Turns the buffered dictation into a transcript. The default packages it
    /// as a WAV and uploads it; override for on-device transcription.
    /// Must end in exactly one `deliver(_:)` or `fail(_:)`.
    func processBuffer(_ pcm: Data) {
        upload(makeRequest(wav: Self.wavFile(pcm: pcm, sampleRate: 24_000, channels: 1)))
    }

    func makeRequest(wav: Data) -> URLRequest {
        fatalError("subclass must override makeRequest(wav:)")
    }

    func parseTranscript(from data: Data) -> String? {
        fatalError("subclass must override parseTranscript(from:)")
    }

    func errorMessage(forStatus status: Int) -> String {
        switch status {
        case 401, 403: return "\(providerName) rejected the request — check your API key."
        default: return "\(providerName) returned HTTP \(status)."
        }
    }

    // MARK: - TranscriptionSession

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
            self.processBuffer(self.pcm)
        }
    }

    /// Reports a finished transcript to AppState. Call from any queue.
    func deliver(_ text: String) {
        DispatchQueue.main.async {
            guard !self.cancelled else { return }
            self.onCompleted?(text)
            self.onFinished?()
        }
    }

    /// Reports a failure to AppState. Call from any queue.
    func fail(_ message: String) {
        DispatchQueue.main.async {
            guard !self.cancelled else { return }
            self.onError?(message)
            self.onFinished?()
        }
    }

    func cancel() {
        queue.async {
            self.cancelled = true
            self.pcm.removeAll()
        }
    }

    // MARK: - Upload

    private func upload(_ request: URLRequest) {
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self, !self.cancelled else { return }
            DispatchQueue.main.async {
                defer { self.onFinished?() }
                if let error {
                    self.onError?("\(self.providerName) upload failed: \(error.localizedDescription)")
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, let data else {
                    self.onError?(self.errorMessage(forStatus: status))
                    return
                }
                guard let text = self.parseTranscript(from: data) else {
                    self.onError?("Unexpected response from \(self.providerName).")
                    return
                }
                self.onCompleted?(text)
            }
        }.resume()
    }

    // MARK: - Helpers for subclasses

    struct MultipartForm {
        let boundary = "sottovoce-\(UUID().uuidString)"
        private var body = Data()

        var contentType: String { "multipart/form-data; boundary=\(boundary)" }

        mutating func addField(name: String, value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }

        mutating func addFile(name: String, filename: String, contentType fileType: String, data: Data) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(fileType)\r\n\r\n".utf8))
            body.append(data)
            body.append(Data("\r\n".utf8))
        }

        func finalized() -> Data {
            body + Data("--\(boundary)--\r\n".utf8)
        }
    }

    static func wavFile(pcm: Data, sampleRate: UInt32, channels: UInt16) -> Data {
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
