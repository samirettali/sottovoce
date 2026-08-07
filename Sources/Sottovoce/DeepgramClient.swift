import Foundation

/// Streaming transcription via Deepgram's realtime WebSocket (nova-3).
///
/// Deepgram doesn't emit append-only deltas: interim results are revisions of
/// the utterance in progress, then `is_final` marks a stable segment. Finals
/// are reported through onCompleted (inserted per phrase while dictating);
/// interims go through onInterim (overlay preview only, never inserted).
final class DeepgramClient: NSObject, TranscriptionSession, URLSessionWebSocketDelegate {
    var onReady: (() -> Void)?
    var onDelta: ((String) -> Void)?
    var onInterim: ((String) -> Void)?
    var onCompleted: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onFinished: (() -> Void)?

    private let apiKey: String
    private let languages: [String]
    private let keywords: [String]
    private let queue = DispatchQueue(label: "com.samirettali.sottovoce.deepgram")
    private lazy var urlSession = URLSession(
        configuration: .default, delegate: self, delegateQueue: nil
    )
    private var task: URLSessionWebSocketTask?

    private var ready = false
    private var finishing = false
    private var done = false
    private var pendingAudio: [Data] = []
    private var capTimer: DispatchWorkItem?

    init(apiKey: String, languages: [String], keywords: [String]) {
        self.apiKey = apiKey
        self.languages = languages
        self.keywords = keywords
    }

    // MARK: - TranscriptionSession

    func connect() {
        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        // nova-3 code-switches with language=multi; pin the language only when
        // exactly one hint is configured.
        let language = languages.count == 1 ? languages[0] : "multi"
        components.queryItems = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "24000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "language", value: language),
        ]
        // nova-3 keyterm prompting: one query item per term.
        components.queryItems?.append(
            contentsOf: keywords.map { URLQueryItem(name: "keyterm", value: $0) }
        )
        var request = URLRequest(url: components.url!)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = urlSession.webSocketTask(with: request)
        self.task = task
        task.resume()
        listen()
    }

    func sendAudio(_ chunk: Data) {
        queue.async {
            guard !self.done, !self.finishing else { return }
            if self.ready {
                self.task?.send(.data(chunk)) { _ in }
            } else if self.pendingAudio.count < 700 {
                self.pendingAudio.append(chunk)
            }
        }
    }

    func finish() {
        queue.async {
            guard !self.done, !self.finishing else { return }
            self.finishing = true
            self.flushPendingAudio()
            // Ask the server to flush remaining finals and close the stream.
            self.task?.send(.string(#"{"type":"CloseStream"}"#)) { _ in }
            let cap = DispatchWorkItem { [weak self] in self?.finishNow() }
            self.capTimer = cap
            self.queue.asyncAfter(deadline: .now() + 5, execute: cap)
        }
    }

    func cancel() {
        queue.async {
            guard !self.done else { return }
            self.done = true
            self.capTimer?.cancel()
            self.task?.cancel(with: .goingAway, reason: nil)
        }
    }

    // MARK: - Internals (on `queue`)

    private func flushPendingAudio() {
        guard ready else { return }
        for chunk in pendingAudio {
            task?.send(.data(chunk)) { _ in }
        }
        pendingAudio.removeAll()
    }

    private func finishNow() {
        guard !done else { return }
        done = true
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

    private func listen() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.queue.async {
                    self.fail("Deepgram connection lost — check your network and API key.")
                }
            case .success(let message):
                if case .string(let text) = message {
                    self.queue.async { self.handleEvent(text) }
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
        case "Results":
            guard let channel = event["channel"] as? [String: Any],
                  let alternatives = channel["alternatives"] as? [[String: Any]],
                  let transcript = alternatives.first?["transcript"] as? String
            else { return }
            let isFinal = event["is_final"] as? Bool ?? false
            if isFinal {
                if !transcript.isEmpty {
                    DispatchQueue.main.async { self.onCompleted?(transcript) }
                } else {
                    DispatchQueue.main.async { self.onInterim?("") }
                }
            } else if !transcript.isEmpty {
                DispatchQueue.main.async { self.onInterim?(transcript) }
            }

        case "Metadata":
            // Sent after CloseStream once everything has been flushed.
            if finishing { finishNow() }

        default:
            break
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        queue.async {
            self.ready = true
            self.flushPendingAudio()
            DispatchQueue.main.async { self.onReady?() }
        }
    }

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        queue.async {
            if self.finishing {
                self.finishNow()
            } else if !self.done {
                self.fail("The Deepgram session was closed by the server.")
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error != nil else { return }
        queue.async {
            if self.ready {
                self.fail("Deepgram connection lost.")
            } else {
                self.fail("Could not connect to Deepgram — check your API key (401?) and network.")
            }
        }
    }
}
