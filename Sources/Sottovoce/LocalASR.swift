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
    /// The keyword boost for the current Keywords list, kept resident like
    /// the models; rebuilt when the list changes.
    private var boost: VocabularyBoost?

    private let converter = AudioConverter()

    /// Whether the model files are already on disk (checked without loading them).
    nonisolated static var modelsDownloaded: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }

    nonisolated static var cacheDirectory: URL {
        AsrModels.defaultCacheDirectory(for: version)
    }

    /// Whether the CTC models the keyword boost needs are on disk.
    nonisolated static var boostModelsDownloaded: Bool {
        CtcModels.modelsExist(at: VocabularyBoost.cacheDirectory)
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

    /// Downloads the CTC models for the keyword boost if missing.
    func prepareBoost() async throws {
        try await CtcModels.download(to: VocabularyBoost.cacheDirectory)
    }

    /// Transcribes 24 kHz mono PCM16 (the format `AudioCapture` produces).
    /// `keywords` are boosted through the CTC pass when its models are on
    /// disk; a failure there logs and returns the plain transcript.
    func transcribe(pcm24k: Data, language: Language?, keywords: [String] = []) async throws -> String {
        let manager = try await loadedManager()
        let samples = try converter.resample(Self.floatSamples(fromPCM16: pcm24k), from: 24_000)
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &state, language: language)

        guard !keywords.isEmpty, Self.boostModelsDownloaded,
              let timings = result.tokenTimings, !timings.isEmpty else { return result.text }
        do {
            let boost = try await loadedBoost(for: keywords)
            return try await boost.rescore(result.text, timings: timings, samples: samples)
        } catch {
            NSLog("Keyword boost skipped: \(error.localizedDescription)")
            return result.text
        }
    }

    /// Frees the CoreML models; the next dictation reloads them.
    func unload() {
        manager = nil
        boost = nil
    }

    private func loadedBoost(for keywords: [String]) async throws -> VocabularyBoost {
        if let boost, boost.keywords == keywords { return boost }
        let boost = try await VocabularyBoost(keywords: keywords)
        self.boost = boost
        return boost
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

// MARK: - Keyword boost

/// Makes the Keywords list count for the on-device model.
///
/// Parakeet TDT is a transducer: it cannot be asked how likely a given word
/// is at a given point, so keywords cannot condition its decoding. FluidAudio
/// ships a separate CTC head (Parakeet CTC 110M) whose per-frame posteriors
/// let any term be aligned against the audio and scored. The transcript is
/// still the TDT one; the CTC pass only decides, term by term, whether a word
/// the TDT got wrong sounds enough like a keyword to be swapped. Greedy CTC
/// decoding is useless by design (~113% WER, per the library) — the models
/// exist to score, not to transcribe.
private struct VocabularyBoost {
    let keywords: [String]
    private let vocabulary: CustomVocabularyContext
    private let spotter: CtcKeywordSpotter
    private let rescorer: VocabularyRescorer

    static var cacheDirectory: URL { CtcModels.defaultCacheDirectory(for: .ctc110m) }

    /// Loads the CTC models (already downloaded) and tokenises the keywords
    /// with the CTC tokenizer, as the library's own batch path does.
    init(keywords: [String]) async throws {
        let directory = Self.cacheDirectory
        let models = try await CtcModels.load(from: directory, variant: .ctc110m)
        let tokenizer = try await CtcTokenizer.load(from: directory)
        let terms = keywords.compactMap { keyword -> CustomVocabularyTerm? in
            let ids = tokenizer.encode(keyword)
            guard !ids.isEmpty else { return nil }
            return CustomVocabularyTerm(text: keyword, ctcTokenIds: ids)
        }
        let vocabulary = CustomVocabularyContext(terms: terms)
        let spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
        self.keywords = keywords
        self.vocabulary = vocabulary
        self.spotter = spotter
        self.rescorer = try await VocabularyRescorer.create(
            spotter: spotter, vocabulary: vocabulary, config: Self.rescorerConfig, ctcModelDirectory: directory
        )
    }

    /// The library's defaults are tuned for long lists of distinctive names
    /// (drug names, earnings calls). Its "spotter rescue" pass then replaces
    /// a word on acoustic evidence alone, with no string-similarity floor
    /// (`defaultSpotterRescueMinSimilarity` is 0), and its own notes call it
    /// the dominant source of over-firing on short keyword lists: with the
    /// single keyword "Hammerspoon" it rewrote a clearly spoken "Bitwarden".
    /// These are the short-vocab values the library recommends: the rescue
    /// keeps recovering a mangled name that still resembles the keyword, and
    /// short terms get a tapered boost so they can't beat a correct word.
    private static let rescorerConfig = VocabularyRescorer.Config(
        shortTermCbwTaperPivot: 5,
        shortTermCbwTaperExponent: 2.0,
        spotterRescueMinSimilarity: 0.30,
        spotterRescueMultiWordMinSimilarity: 0.50
    )

    func rescore(_ transcript: String, timings: [TokenTiming], samples: [Float]) async throws -> String {
        let spotted = try await spotter.spotKeywordsWithLogProbs(audioSamples: samples, customVocabulary: vocabulary)
        guard !spotted.logProbs.isEmpty else { return transcript }
        // Thresholds tighten with the list's size: a long list has more
        // near-misses to fire on.
        let config = ContextBiasingConstants.rescorerConfig(forVocabSize: vocabulary.terms.count)
        let output = rescorer.ctcTokenRescore(
            transcript: transcript,
            tokenTimings: timings,
            logProbs: spotted.logProbs,
            frameDuration: spotted.frameDuration,
            cbw: config.cbw,
            minSimilarity: config.minSimilarity
        )
        return output.text
    }
}

/// Observable mirror of the CTC models' state for Settings. Unlike the TDT
/// download there is no progress: `CtcModels.download` reports none.
@MainActor
final class BoostModelStatus: ObservableObject {
    static let shared = BoostModelStatus()

    enum Phase: Equatable {
        case missing
        case working
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = ParakeetEngine.boostModelsDownloaded ? .ready : .missing

    var statusText: String {
        switch phase {
        case .missing: return "Not downloaded"
        case .working: return "Downloading"
        case .ready: return "Ready"
        case .failed: return "Failed"
        }
    }

    func downloadIfNeeded() {
        guard phase != .working else { return }
        phase = .working
        Task {
            do {
                try await ParakeetEngine.shared.prepareBoost()
                phase = .ready
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func refresh() {
        guard phase != .working else { return }
        phase = ParakeetEngine.boostModelsDownloaded ? .ready : .missing
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
