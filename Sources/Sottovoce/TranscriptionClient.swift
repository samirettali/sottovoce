import Foundation

/// WebSocket client for an OpenAI Realtime transcription session
/// running the gpt-live-transcribe model.
final class TranscriptionClient: NSObject, TranscriptionSession, URLSessionWebSocketDelegate {
    var onReady: (() -> Void)?
    var onDelta: ((String) -> Void)?
    var onInterim: ((String) -> Void)?
    var onCompleted: ((String) -> Void)?
    var onError: ((String) -> Void)?
    /// Fired exactly once (on the main queue) when a finish() has fully drained.
    var onFinished: (() -> Void)?

    /// Model tuning options, captured at session start.
    struct Options {
        var languages: [String]
        var prompt: String
        var keywords: [String]
        var delay: TranscriptionDelay

        static func fromPrefs() -> Options {
            Options(
                languages: Prefs.languages,
                prompt: Prefs.transcriptionPrompt,
                keywords: Prefs.transcriptionKeywords,
                delay: Prefs.transcriptionDelay
            )
        }
    }

    private let apiKey: String
    private let options: Options
    private let queue = DispatchQueue(label: "com.samirettali.sottovoce.ws")
    private lazy var urlSession = URLSession(
        configuration: .default, delegate: self, delegateQueue: nil
    )
    private var task: URLSessionWebSocketTask?

    private var ready = false
    private var finishing = false
    private var done = false
    /// Audio chunks buffered until the session is configured.
    private var pendingAudio: [Data] = []
    private var appendedMs: Double = 0

    private var quietTimer: DispatchWorkItem?
    private var capTimer: DispatchWorkItem?

    init(apiKey: String, options: Options) {
        self.apiKey = apiKey
        self.options = options
    }

    // MARK: - Public API

    func connect() {
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = urlSession.webSocketTask(with: request)
        self.task = task
        task.resume()
        listen()
    }

    func sendAudio(_ chunk: Data) {
        queue.async {
            guard !self.done, !self.finishing else { return }
            self.appendedMs += Double(chunk.count) / 48.0 // 24 kHz * 2 bytes = 48 bytes/ms
            if self.ready {
                self.sendJSON(["type": "input_audio_buffer.append", "audio": chunk.base64EncodedString()])
            } else {
                // ~30 s of headroom while the session comes up.
                if self.pendingAudio.count < 700 { self.pendingAudio.append(chunk) }
            }
        }
    }

    /// Commits any remaining audio and waits for the final transcripts.
    func finish() {
        queue.async {
            guard !self.done, !self.finishing else { return }
            self.finishing = true
            self.flushPendingAudio()
            // Server VAD may already have committed everything; a redundant commit
            // just yields a harmless "buffer too small" error that we ignore.
            if self.appendedMs > 120 {
                self.sendJSON(["type": "input_audio_buffer.commit"])
            }
            self.scheduleQuietTimer(2.5)
            let cap = DispatchWorkItem { [weak self] in self?.finishNow() }
            self.capTimer = cap
            self.queue.asyncAfter(deadline: .now() + 5, execute: cap)
        }
    }

    /// Tears the session down immediately, discarding everything.
    func cancel() {
        queue.async {
            guard !self.done else { return }
            self.done = true
            self.quietTimer?.cancel()
            self.capTimer?.cancel()
            self.task?.cancel(with: .goingAway, reason: nil)
        }
    }

    // MARK: - Session lifecycle (all on `queue`)

    private func sendSessionUpdate() {
        var transcription: [String: Any] = ["model": "gpt-live-transcribe"]
        if !options.languages.isEmpty {
            transcription["languages"] = options.languages
        }
        if !options.prompt.isEmpty {
            transcription["prompt"] = options.prompt
        }
        if !options.keywords.isEmpty {
            transcription["keywords"] = options.keywords
        }
        if options.delay != .apiDefault {
            transcription["delay"] = options.delay.rawValue
        }
        // gpt-live-transcribe rejects server VAD ("turn detection is not
        // supported by this model") — it segments live on its own; the buffer
        // is committed manually on finish().
        let session: [String: Any] = [
            "type": "transcription",
            "audio": [
                "input": [
                    "format": ["type": "audio/pcm", "rate": 24_000],
                    "transcription": transcription,
                    "turn_detection": NSNull(),
                ],
            ],
        ]
        sendJSON(["type": "session.update", "session": session])
    }

    private func markReady() {
        guard !ready else { return }
        ready = true
        flushPendingAudio()
        DispatchQueue.main.async { self.onReady?() }
    }

    private func flushPendingAudio() {
        guard ready else { return }
        for chunk in pendingAudio {
            sendJSON(["type": "input_audio_buffer.append", "audio": chunk.base64EncodedString()])
        }
        pendingAudio.removeAll()
    }

    private func scheduleQuietTimer(_ interval: TimeInterval) {
        quietTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finishNow() }
        quietTimer = work
        queue.asyncAfter(deadline: .now() + interval, execute: work)
    }

    private func finishNow() {
        guard !done else { return }
        done = true
        quietTimer?.cancel()
        capTimer?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        DispatchQueue.main.async { self.onFinished?() }
    }

    private func fail(_ message: String) {
        guard !done else { return }
        if finishing {
            finishNow()
            return
        }
        done = true
        task?.cancel(with: .goingAway, reason: nil)
        DispatchQueue.main.async { self.onError?(message) }
    }

    // MARK: - Receiving

    private func listen() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.queue.async {
                    self.fail("Connection lost — check your network and API key.")
                }
            case .success(let message):
                switch message {
                case .string(let text):
                    self.queue.async { self.handleEvent(text) }
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.queue.async { self.handleEvent(text) }
                    }
                @unknown default:
                    break
                }
                self.listen()
            }
        }
    }

    private func handleEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String
        else { return }

        switch type {
        case "session.updated", "transcription_session.updated":
            markReady()

        case let t where t.hasSuffix("input_audio_transcription.delta"):
            if let delta = event["delta"] as? String, !delta.isEmpty {
                DispatchQueue.main.async { self.onDelta?(delta) }
            }

        case let t where t.hasSuffix("input_audio_transcription.completed"):
            let transcript = event["transcript"] as? String ?? ""
            DispatchQueue.main.async { self.onCompleted?(transcript) }
            if finishing {
                // Segments drain quickly once committed; a short quiet window
                // after the last one keeps stop latency low.
                scheduleQuietTimer(0.4)
            }

        case "error":
            let info = event["error"] as? [String: Any]
            let message = info?["message"] as? String ?? "Unknown API error."
            let code = info?["code"] as? String ?? ""
            // A commit on an already-drained buffer is expected during finish.
            let harmless = code.contains("commit_empty")
                || message.localizedCaseInsensitiveContains("buffer too small")
                || message.localizedCaseInsensitiveContains("buffer is empty")
            if harmless {
                if finishing { scheduleQuietTimer(0.4) }
            } else {
                fail(message)
            }

        default:
            break
        }
    }

    // MARK: - Sending

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8)
        else { return }
        task?.send(.string(text)) { [weak self] error in
            guard error != nil, let self else { return }
            self.queue.async { self.fail("Failed to send audio to the API.") }
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        queue.async { self.sendSessionUpdate() }
    }

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        queue.async {
            if self.finishing {
                self.finishNow()
            } else if !self.done {
                self.fail("The transcription session was closed by the server.")
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error != nil else { return }
        queue.async {
            if self.ready {
                self.fail("Connection lost.")
            } else {
                self.fail("Could not connect — check your API key and network.")
            }
        }
    }
}
