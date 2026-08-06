import AVFoundation
import CoreAudio

/// Captures microphone audio and delivers 24 kHz mono PCM16 chunks
/// (the format the Realtime transcription API expects).
final class AudioCapture {
    struct CaptureError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true
    )!
    private var converter: AVAudioConverter?
    private(set) var running = false

    /// Set by `start` when the configured microphone could not be used and the
    /// system default was taken instead. Read once, after `start` returns.
    private(set) var deviceFallbackNotice: String?

    /// Called when the audio hardware changes under a running capture — the
    /// selected microphone being unplugged, typically.
    var onInterrupted: (() -> Void)?

    private var configurationObserver: NSObjectProtocol?

    func start(onChunk: @escaping (Data) -> Void, onLevel: @escaping (Float) -> Void) throws {
        guard !running else { return }

        let input = engine.inputNode
        // Before anything reads a format: the format belongs to the device, so
        // choosing the device has to come first or the converter is built for
        // the wrong one.
        deviceFallbackNotice = selectInputDevice()

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError(message: "No audio input device available.")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError(message: "Unsupported microphone format.")
        }
        self.converter = converter

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }

            if let channel = buffer.floatChannelData?[0] {
                let frames = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frames { sum += channel[i] * channel[i] }
                let rms = sqrt(sum / Float(max(frames, 1)))
                let db = 20 * log10(max(rms, 1e-7))
                onLevel(max(0, min(1, (db + 50) / 50)))
            }

            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: self.targetFormat, frameCapacity: capacity) else {
                return
            }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData?[0] else {
                return
            }
            onChunk(Data(bytes: samples, count: Int(out.frameLength) * 2))
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError(message: "Could not start the microphone: \(error.localizedDescription)")
        }
        running = true

        // A device vanishing mid-dictation stops the engine delivering audio
        // without throwing anywhere; this notification is the only signal.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.running else { return }
            self.onInterrupted?()
        }
    }

    func stop() {
        guard running else { return }
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        running = false
    }

    /// Points the engine's input at the configured microphone. Returns a
    /// message to surface when the configured device isn't available, having
    /// fallen back to the system default; `nil` when all is well.
    ///
    /// The device is always set explicitly, including for "system default":
    /// the audio unit remembers the last device it was given, so leaving it
    /// alone would keep capturing from a microphone the user just deselected.
    private func selectInputDevice() -> String? {
        let unit = engine.inputNode.auAudioUnit
        let wanted = Prefs.inputDeviceUID

        var notice: String?
        var deviceID = AudioDevices.systemDefaultInputID()

        if !wanted.isEmpty {
            if let configured = AudioDevices.deviceID(uid: wanted) {
                deviceID = configured
            } else {
                notice = "The selected microphone isn't available — using the system default."
            }
        }

        guard let deviceID else { return notice }
        do {
            try unit.setDeviceID(deviceID)
        } catch {
            return "Could not use the selected microphone — using the system default."
        }
        return notice
    }
}
