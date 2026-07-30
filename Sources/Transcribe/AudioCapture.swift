import AVFoundation

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

    func start(onChunk: @escaping (Data) -> Void, onLevel: @escaping (Float) -> Void) throws {
        guard !running else { return }

        let input = engine.inputNode
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
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        running = false
    }
}
