import Foundation
import FluidAudio

/// On-device transcription with Parakeet TDT 0.6B v3 (CoreML, runs on the ANE
/// via FluidAudio).
///
/// The models are ~600 MB and live in FluidAudio's cache directory under
/// Application Support, fetched once from Hugging Face. Loading them costs a
/// few seconds, so this is a singleton that keeps them resident for the
/// lifetime of the app — reloading per session would put that cost on every
/// hotkey press.
actor ParakeetEngine {
    static let shared = ParakeetEngine()

    /// v3 is the multilingual export (25 European languages, Italian included);
    /// v2 is faster but English-only.
    private static let version: AsrModelVersion = .v3

    private var manager: AsrManager?
    /// In-flight load, so a dictation started while Settings is downloading
    /// waits for that same work instead of kicking off a second download.
    private var loadTask: Task<AsrManager, Error>?

    private let converter = AudioConverter()

    /// Whether the model files are already on disk (checked without loading them).
    nonisolated static var modelsDownloaded: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }

    nonisolated static var cacheDirectory: URL {
        AsrModels.defaultCacheDirectory(for: version)
    }

    /// Whether the models are downloaded *and* loaded into memory, so the next
    /// dictation transcribes without a stall.
    var isLoaded: Bool { manager != nil }

    /// Downloads the models if missing, then loads them. Safe to call repeatedly.
    func prepare(progress: ProgressHandler? = nil) async throws {
        _ = try await loadedManager(progress: progress)
    }

    /// Transcribes 24 kHz mono PCM16 (the format `AudioCapture` produces).
    func transcribe(pcm24k: Data, language: Language?) async throws -> String {
        let manager = try await loadedManager()
        let samples = try converter.resample(Self.floatSamples(fromPCM16: pcm24k), from: 24_000)
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &state, language: language)
        return result.text
    }

    /// Frees the CoreML models; the next dictation reloads them.
    func unload() {
        manager = nil
    }

    // MARK: - Loading

    private func loadedManager(progress: ProgressHandler? = nil) async throws -> AsrManager {
        if let manager { return manager }
        if let loadTask { return try await loadTask.value }

        let task = Task<AsrManager, Error> {
            // No-ops the download when the files are already cached.
            let models = try await AsrModels.downloadAndLoad(
                version: Self.version, progressHandler: progress
            )
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        loadTask = task
        defer { loadTask = nil }

        let manager = try await task.value
        self.manager = manager
        return manager
    }

    // MARK: - Audio

    /// Interleaved little-endian PCM16 → normalized floats.
    private static func floatSamples(fromPCM16 data: Data) -> [Float] {
        data.withUnsafeBytes { raw -> [Float] in
            let samples = raw.bindMemory(to: Int16.self)
            return samples.map { Float(Int16(littleEndian: $0)) / 32_768.0 }
        }
    }
}

// MARK: - Download status for Settings

/// Observable mirror of the engine's state, so Settings can show whether the
/// model is on disk and drive the download.
@MainActor
final class LocalModelStatus: ObservableObject {
    static let shared = LocalModelStatus()

    enum Phase: Equatable {
        case missing
        case downloading(fraction: Double, detail: String)
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = ParakeetEngine.modelsDownloaded ? .ready : .missing

    var isBusy: Bool {
        if case .downloading = phase { return true }
        return false
    }

    func downloadIfNeeded() {
        guard !isBusy else { return }
        phase = .downloading(fraction: 0, detail: "Preparing…")
        Task {
            do {
                try await ParakeetEngine.shared.prepare { progress in
                    Task { @MainActor in
                        LocalModelStatus.shared.phase = .downloading(
                            fraction: progress.fractionCompleted,
                            detail: Self.describe(progress.phase)
                        )
                    }
                }
                phase = .ready
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Refreshes from disk — the files may have been deleted behind our back.
    func refresh() {
        guard !isBusy else { return }
        phase = ParakeetEngine.modelsDownloaded ? .ready : .missing
    }

    private static func describe(_ phase: DownloadPhase) -> String {
        switch phase {
        case .listing:
            return "Listing files…"
        case .downloading(let completed, let total):
            return "Downloading \(completed) of \(total) files…"
        case .compiling(let model):
            return "Compiling \(model)…"
        }
    }
}
