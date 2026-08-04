import Foundation
import FluidAudio

/// On-device transcription with Parakeet TDT 0.6B v3 (CoreML, runs on the ANE
/// via FluidAudio).
///
/// The models are ~470 MB and live in FluidAudio's cache directory under
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

    /// Bytes the installed model occupies. The `.mlmodelc` bundles are
    /// directories, so this walks the tree; call it off the main thread.
    nonisolated static func installedSizeBytes() -> Int64? {
        guard let files = FileManager.default.enumerator(
            at: cacheDirectory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
        ) else { return nil }

        var total: Int64 = 0
        for case let url as URL in files {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let size = values?.totalFileAllocatedSize else { continue }
            total += Int64(size)
        }
        return total > 0 ? total : nil
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

    enum Step: Equatable {
        case downloading
        case building

        var label: String {
            switch self {
            case .downloading: return "Downloading"
            case .building: return "Building model"
            }
        }
    }

    struct Progress: Equatable {
        var step: Step
        /// 1-based index of the CoreML model being fetched/compiled.
        var modelIndex: Int
        var modelCount: Int
        /// Progress within the current model's sub-operation, 0–1.
        var modelFraction: Double
        /// Progress across the whole setup, 0–1.
        var overall: Double

        var percentText: String { "\(Int(overall * 100))%" }

        /// Plain-language description of what is happening right now.
        var detailSentence: String {
            switch step {
            case .downloading: return "Downloading model \(modelIndex) of \(modelCount)"
            case .building: return "Building model \(modelIndex) of \(modelCount)"
            }
        }
    }

    enum Phase: Equatable {
        case missing
        case working(Progress)
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = ParakeetEngine.modelsDownloaded ? .ready : .missing

    var isBusy: Bool {
        if case .working = phase { return true }
        return false
    }

    func downloadIfNeeded() {
        guard !isBusy else { return }
        let aggregator = ProgressAggregator()
        phase = .working(aggregator.initialProgress)
        Task {
            do {
                try await ParakeetEngine.shared.prepare { raw in
                    guard let progress = aggregator.consume(raw) else { return }
                    Task { @MainActor in
                        LocalModelStatus.shared.publish(progress)
                    }
                }
                phase = .ready
                measureInstalledSize()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Main-queue hops aren't ordered, so drop any update that would make the
    /// bar walk backwards.
    private func publish(_ progress: Progress) {
        guard case .working(let current) = phase else { return }
        guard progress.overall >= current.overall else { return }
        phase = .working(progress)
    }

    /// Formatted size the installed model takes on disk, once measured.
    @Published private(set) var installedSize: String?

    /// Trailing status on the title row.
    var statusText: String {
        switch phase {
        case .missing: return "Not downloaded"
        case .working: return "Setting up"
        case .ready: return "Ready"
        case .failed: return "Failed"
        }
    }

    /// Second row once installed — facts about what is on disk, rather than
    /// repeating the status from the row above.
    var readyDetail: String {
        var parts = ["Parakeet TDT 0.6B v3", "25 languages", "Neural Engine"]
        if let installedSize {
            parts.insert(installedSize, at: 1)
        }
        return parts.joined(separator: " · ")
    }

    /// Refreshes from disk — the files may have been deleted behind our back.
    func refresh() {
        guard !isBusy else { return }
        phase = ParakeetEngine.modelsDownloaded ? .ready : .missing
        measureInstalledSize()
    }

    /// Walks the model tree off the main thread; the row shows the size only
    /// once it lands.
    private func measureInstalledSize() {
        guard case .ready = phase else {
            installedSize = nil
            return
        }
        Task.detached(priority: .utility) {
            guard let bytes = ParakeetEngine.installedSizeBytes() else { return }
            let text = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            await MainActor.run { LocalModelStatus.shared.installedSize = text }
        }
    }


}

/// Turns FluidAudio's progress callbacks into one monotonic 0–1 for the whole
/// setup.
///
/// The library does **not** report a single sweep. `AsrModels.download` calls
/// `ModelHub.loadModels` once per CoreML model (Preprocessor, Encoder, Decoder,
/// Joint), and each call reports its own independent 0→1: `listing` at 0, bytes
/// over 0–0.5, compile over 0.5–1.0, then `finished` at exactly 1.0 with an
/// empty model name. Handed straight to a progress bar that reads as four
/// resets. Verified by instrumenting the handler, not from the docs.
///
/// Two consequences worth knowing before trusting these numbers:
/// - the compile half of each sub-operation only ever emits 0% then 100%
///   (`count` is 1 per call), so a *percentage* while building is meaningless —
///   only the model counter carries information;
/// - the four models are wildly uneven (the encoder is most of the ~470 MB), so
///   `overall` advances in lumpy quarters rather than at a steady rate.
///
/// Thread-safe: the handler runs on FluidAudio's own queue.
private final class ProgressAggregator: @unchecked Sendable {
    /// Where the library splits bytes from CoreML compilation within one model.
    private static let downloadPhaseWeight = 0.5

    private let lock = NSLock()
    private var completedModels = 0

    /// Number of sub-operations to expect. Coupled to FluidAudio's download
    /// loop, so treat it as a hint: `consume` clamps if reality disagrees.
    private let expectedModels = max(AsrModels.requiredModelNames.count, 1)

    var initialProgress: LocalModelStatus.Progress {
        .init(step: .downloading, modelIndex: 1, modelCount: expectedModels,
              modelFraction: 0, overall: 0)
    }

    func consume(_ raw: DownloadProgress) -> LocalModelStatus.Progress? {
        lock.lock()
        defer { lock.unlock() }

        let weight = Self.downloadPhaseWeight
        let step: LocalModelStatus.Step
        let fraction: Double

        switch raw.phase {
        case .listing:
            step = .downloading
            fraction = 0
        case .downloading:
            step = .downloading
            fraction = min(raw.fractionCompleted / weight, 1)
        case .compiling(let name):
            // An empty name is the sub-operation's `finished()`: this model is
            // done, so bank it and move on to the next.
            if name.isEmpty {
                completedModels += 1
                let done = min(completedModels, expectedModels)
                return .init(
                    step: .building, modelIndex: min(done + 1, expectedModels),
                    modelCount: expectedModels, modelFraction: 1,
                    overall: Double(done) / Double(expectedModels)
                )
            }
            step = .building
            fraction = min(max((raw.fractionCompleted - weight) / (1 - weight), 0), 1)
        }

        let count = max(expectedModels, completedModels + 1)
        let overall = min((Double(completedModels) + fraction) / Double(count), 1)
        return .init(
            step: step, modelIndex: min(completedModels + 1, count),
            modelCount: count, modelFraction: fraction, overall: overall
        )
    }
}
