import AVFoundation
import Combine
import Foundation

/// Live microphone level for the meter in Settings.
///
/// Runs its own engine rather than reusing `AudioCapture`, which only exists
/// for the duration of a dictation — the meter has to work while nothing is
/// being dictated, which is the whole point of it.
final class InputLevelMonitor: ObservableObject {
    /// 0…1, derived from peak amplitude.
    @Published private(set) var level: Float = 0
    /// The signal reached full scale recently and is likely clipping.
    @Published private(set) var overloading = false

    private let engine = AVAudioEngine()
    private var running = false
    private var overloadUntil: Date?

    /// Everything below this is visually empty anyway, and it keeps room
    /// noise from lighting the first segments.
    private let floorDB: Float = -60

    var isRunning: Bool { running }

    func start() {
        guard !running else { return }

        let input = engine.inputNode
        AudioDevices.applyPreferredInput(to: input.auAudioUnit)

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            // Peak, not RMS: RMS averages away the short transients that are
            // exactly what clips, so an RMS meter reads comfortable while the
            // signal is already square on top.
            var peak: Float = 0
            for i in 0..<Int(buffer.frameLength) {
                peak = max(peak, abs(channel[i]))
            }
            DispatchQueue.main.async { self?.absorb(peak: peak) }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return
        }
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        level = 0
        overloading = false
        overloadUntil = nil
    }

    /// Picks up a change of input device: the engine has to be torn down for
    /// the new device's format to take effect.
    func restart() {
        guard running else { return }
        stop()
        start()
    }

    private func absorb(peak: Float) {
        let db = 20 * log10(max(peak, 1e-6))
        let normalised = max(0, min(1, (db - floorDB) / -floorDB))

        // Fast attack, slow decay. A meter that fell as fast as speech does
        // would flicker uselessly; holding the fall makes peaks readable.
        level = normalised > level ? normalised : max(normalised, level * 0.82)

        if peak >= 0.99 {
            overloading = true
            overloadUntil = Date().addingTimeInterval(1.5)
        } else if let until = overloadUntil, Date() >= until {
            overloading = false
            overloadUntil = nil
        }
    }
}
