import Foundation

/// A dictation session with a transcription provider.
///
/// Two families of implementations:
/// - streaming (OpenAI Realtime): live deltas while speaking, `finish()`
///   drains the tail;
/// - batch (Fish Audio): audio is buffered locally and uploaded on
///   `finish()`, so the whole transcript arrives as one completed segment.
protocol TranscriptionSession: AnyObject {
    /// The session is ready to accept audio.
    var onReady: (() -> Void)? { get set }
    /// Incremental transcript text (streaming providers only).
    var onDelta: ((String) -> Void)? { get set }
    /// A finalized transcript segment.
    var onCompleted: ((String) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    /// Fired exactly once (on the main queue) when a finish() has fully drained.
    var onFinished: (() -> Void)? { get set }

    func connect()
    func sendAudio(_ chunk: Data)
    func finish()
    func cancel()
}
