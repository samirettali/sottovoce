import Foundation

/// Streaming transcription via the Gemini Live API (`gemini-3.5-transcribe-live`).
///
/// Same delta semantics as Deepgram, under different names: the server sends
/// `interimInputTranscription` (speculative, revised while the speaker talks →
/// display only) and `inputTranscription` (finalized segment → inserted).
/// The socket is a general BidiGenerateContent stream, so nothing flows until
/// the server answers the `setup` frame with `setupComplete`.
final class GeminiLiveClient: NSObject, TranscriptionSession, URLSessionWebSocketDelegate {
    var onReady: (() -> Void)?
    var onDelta: ((String) -> Void)?
    var onInterim: ((String) -> Void)?
    var onCompleted: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onFinished: (() -> Void)?

    private let apiKey: String
    private let languages: [String]
    private let keywords: [String]

    private let queue = DispatchQueue(label: "com.samirettali.sottovoce.gemini")
    private lazy var urlSession = URLSession(
        configuration: .default, delegate: self, delegateQueue: nil
    )
    private var task: URLSessionWebSocketTask?

    /// `setupComplete` received — the session accepts audio.
    private var ready = false
    private var finishing = false
    private var done = false
    private var pendingAudio: [Data] = []
    private var capTimer: DispatchWorkItem?
    /// An interim has arrived that no final has closed yet, so the server still
    /// owes us a segment. Without speech in flight it owes us nothing and
    /// stays silent forever after `audioStreamEnd`.
    private var pendingSpeech = false

    init(apiKey: String, languages: [String], keywords: [String]) {
        self.apiKey = apiKey
        self.languages = languages
        self.keywords = keywords
    }

    // MARK: - TranscriptionSession

    func connect() {
        var components = URLComponents(
            string: "wss://generativelanguage.googleapis.com/ws/"
                + "google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        )!
        // The Live API takes the key in the query string, not in a header.
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        let task = urlSession.webSocketTask(with: URLRequest(url: components.url!))
        self.task = task
        task.resume()
        listen()
    }

    func sendAudio(_ chunk: Data) {
        queue.async {
            guard !self.done, !self.finishing else { return }
            if self.ready {
                self.send(self.audioFrame(chunk))
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
            // Tells the model the utterance is over so it emits the last final.
            self.send(#"{"realtimeInput":{"audioStreamEnd":true}}"#)
            // With a segment in flight the last final lands in ~0.3 s and
            // `generationComplete` ends the wait; with nothing in flight the
            // server sends nothing at all, so this timeout is the only way out
            // and a 5 s one would stall every dictation that ends on a pause.
            // The short wait still covers a last word not yet interim-ed.
            let cap = DispatchWorkItem { [weak self] in self?.finishNow() }
            self.capTimer = cap
            self.queue.asyncAfter(deadline: .now() + (self.pendingSpeech ? 5 : 0.8), execute: cap)
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

    private func send(_ json: String) {
        task?.send(.string(json)) { _ in }
    }

    /// The docs ask for 16 kHz, but the rate travels in the mime type and the
    /// server takes the capture's 24 kHz as it is — verified against the API,
    /// and it saves resampling every chunk on the way out.
    private func audioFrame(_ pcm: Data) -> String {
        """
        {"realtimeInput":{"audio":{"mimeType":"audio/pcm;rate=24000",\
        "data":"\(pcm.base64EncodedString())"}}}
        """
    }

    private func setupFrame() -> String {
        var transcription: [String: Any] = [
            // An empty list means auto-detection across 85+ languages.
            "languageCodes": languages,
            // SMART drops disfluencies and formats the text, which is what a
            // dictation wants; VERBATIM would type every "uhm" out.
            "mode": "SMART",
        ]
        if !keywords.isEmpty {
            // Up to 1000 terms; the docs put the sweet spot around 100.
            transcription["customVocabulary"] = Array(keywords.prefix(1_000))
        }
        let setup: [String: Any] = [
            "setup": [
                "model": "models/gemini-3.5-transcribe-live",
                "generationConfig": ["responseModalities": ["TEXT"]],
                "inputAudioTranscription": transcription,
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: setup),
              let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }

    private func flushPendingAudio() {
        guard ready else { return }
        for chunk in pendingAudio {
            send(audioFrame(chunk))
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

    private func handleEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if event["setupComplete"] != nil {
            ready = true
            flushPendingAudio()
            DispatchQueue.main.async { self.onReady?() }
            return
        }

        guard let content = event["serverContent"] as? [String: Any] else { return }

        // Interims are revisions of the segment in progress, not deltas: each
        // one restates it from the start, so it can only ever be displayed.
        if let interim = (content["interimInputTranscription"] as? [String: Any])?["text"] as? String {
            pendingSpeech = true
            DispatchQueue.main.async { self.onInterim?(interim) }
        }
        // Finals are per segment (one per pause), not cumulative.
        if let final = (content["inputTranscription"] as? [String: Any])?["text"] as? String,
           !final.isEmpty {
            pendingSpeech = false
            DispatchQueue.main.async {
                self.onInterim?("")
                self.onCompleted?(final)
            }
        }
        // Closes each segment, so it only means "we're done" once we have
        // stopped sending audio. `turnComplete` never arrives for this model.
        if content["generationComplete"] as? Bool == true, finishing {
            finishNow()
        }
    }

    private func listen() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.queue.async {
                    self.fail("Gemini connection lost — check your network and API key.")
                }
            case .success(let message):
                switch message {
                case .string(let text):
                    self.queue.async { self.handleEvent(text) }
                case .data(let data):
                    // The Live API sends its JSON as binary frames too.
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

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        queue.async { self.send(self.setupFrame()) }
    }

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        queue.async {
            if self.finishing {
                self.finishNow()
            } else if !self.done {
                // Billing and quota problems arrive as a close reason, not as
                // an error frame, so it's worth surfacing verbatim.
                let detail = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                self.fail(
                    detail.isEmpty
                        ? "The Gemini session was closed by the server."
                        : "Gemini closed the session: \(detail)"
                )
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error != nil else { return }
        queue.async {
            if self.ready {
                self.fail("Gemini connection lost.")
            } else {
                self.fail("Could not connect to Gemini — check your API key and network.")
            }
        }
    }
}
