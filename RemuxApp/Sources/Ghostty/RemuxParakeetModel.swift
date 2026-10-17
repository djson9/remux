import CoreML
import FluidAudio
import Foundation

enum RemuxDictationEngine: String, CaseIterable, Identifiable {
    case apple
    case parakeet

    static let preferenceKey = "remux.dictation.engine"
    static var current: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .apple
    }
    var id: String { rawValue }
    var title: String { self == .apple ? "Apple" : "Parakeet" }
}

enum RemuxParakeetStatus: Equatable, Sendable {
    case missing
    case downloaded
    case downloading(Double)
    case loading
    case ready
    case failed(String)

    var isPreparing: Bool {
        switch self {
        case .downloading, .loading: true
        default: false
        }
    }
}

protocol RemuxParakeetEngine: Sendable {
    func isCached() async -> Bool
    func download(progress: @escaping @Sendable (Double) -> Void) async throws
    func load() async throws
    func transcribe(_ file: URL) async throws -> String
    func unload() async
}

/// Matches ACP Web's LocalDictationKit: FluidAudio 0.15.5, Parakeet TDT v2,
/// INT8 encoder, and a fresh decoder state for each utterance.
actor RemuxFluidAudioEngine: RemuxParakeetEngine {
    private let directory = AsrModels.defaultCacheDirectory(for: .v2)
    private var manager: AsrManager?

    func isCached() -> Bool {
        AsrModels.modelsExist(at: directory, version: .v2, encoderPrecision: .int8)
    }

    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await ModelHub.download(
            .parakeetV2,
            to: directory.deletingLastPathComponent(),
            progressHandler: { update in
                if case .downloading = update.phase {
                    // FluidAudio splits progress equally between download and load.
                    progress(min(max(update.fractionCompleted * 2, 0), 1))
                }
            }
        )
        try Task.checkCancellation()
    }

    func load() async throws {
        guard manager == nil else { return }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let models = try await AsrModels.load(
            from: directory,
            configuration: configuration,
            version: .v2,
            encoderPrecision: .int8
        )
        try Task.checkCancellation()
        let manager = AsrManager()
        try await manager.loadModels(models)
        try Task.checkCancellation()
        self.manager = manager
    }

    func transcribe(_ file: URL) async throws -> String {
        guard let manager else { throw RemuxParakeetError.notReady }
        var decoder = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(file, decoderState: &decoder)
        try Task.checkCancellation()
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func unload() async {
        let previous = manager
        manager = nil
        if let previous { await previous.cleanup() }
    }
}

enum RemuxParakeetError: LocalizedError {
    case missingModel
    case notReady

    var errorDescription: String? {
        switch self {
        case .missingModel: "Download Parakeet in Settings → Dictation before recording."
        case .notReady: "Parakeet isn’t ready. Load it in Settings → Dictation and try again."
        }
    }
}

actor RemuxParakeetModel {
    static let shared = RemuxParakeetModel(engine: RemuxFluidAudioEngine())

    private let engine: any RemuxParakeetEngine
    private var status = RemuxParakeetStatus.missing
    private var preparation: Task<Void, Error>?
    private var unloading: Task<Void, Never>?
    private var preparationID: UUID?
    private var observers: [UUID: AsyncStream<RemuxParakeetStatus>.Continuation] = [:]
    private var transcribing = false
    private var releaseRequested = false

    init(engine: any RemuxParakeetEngine) { self.engine = engine }

    func snapshot() async -> RemuxParakeetStatus {
        if status == .missing, await engine.isCached(), status == .missing { status = .downloaded }
        return status
    }

    func updates() async -> AsyncStream<RemuxParakeetStatus> {
        let initial = await snapshot()
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: RemuxParakeetStatus.self)
        observers[id] = continuation
        continuation.yield(initial)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    /// Only the explicit Settings button may download. Recording/prewarm reuse
    /// the cache and coalesce with an existing manual preparation.
    func prepare(allowDownload: Bool = false) async throws {
        if let unloading { await unloading.value }
        if let preparation { return try await preparation.value }
        if status == .ready { return }
        releaseRequested = false
        let id = UUID()
        preparationID = id
        let engine = engine
        let task = Task {
            if !(await engine.isCached()) {
                guard allowDownload else { throw RemuxParakeetError.missingModel }
                self.publish(.downloading(0))
                try await engine.download { [weak self] fraction in
                    Task { await self?.downloadProgress(fraction, id: id) }
                }
            }
            try Task.checkCancellation()
            self.publish(.loading)
            try await engine.load()
        }
        preparation = task
        do {
            try await task.value
            preparation = nil
            preparationID = nil
            publish(.ready)
            await releaseIfRequested()
        } catch {
            preparation = nil
            preparationID = nil
            publish(.failed(error.localizedDescription))
            throw error
        }
    }

    func transcribe(_ file: URL) async throws -> String {
        guard !transcribing else { throw RemuxParakeetError.notReady }
        transcribing = true
        do {
            try await prepare()
            let text = try await engine.transcribe(file)
            transcribing = false
            await releaseIfRequested()
            return text
        } catch {
            transcribing = false
            await releaseIfRequested()
            throw error
        }
    }

    func releaseWhenIdle() async {
        releaseRequested = true
        await releaseIfRequested()
    }

    private func releaseIfRequested() async {
        guard releaseRequested, preparation == nil, !transcribing else { return }
        guard status == .ready else { releaseRequested = false; return }
        // Preparation waits for cleanup to finish before loading again.
        publish(.downloaded)
        releaseRequested = false
        let engine = engine
        let task = Task { await engine.unload() }
        unloading = task
        await task.value
        unloading = nil
    }

    private func downloadProgress(_ fraction: Double, id: UUID) {
        guard preparationID == id, case .downloading(let previous) = status else { return }
        publish(.downloading(max(previous, fraction)))
    }

    private func publish(_ status: RemuxParakeetStatus) {
        self.status = status
        for observer in observers.values { observer.yield(status) }
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }
}
