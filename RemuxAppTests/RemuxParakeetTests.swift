import AVFoundation
import XCTest
@testable import Remux

@MainActor
final class RemuxParakeetTests: XCTestCase {
    func testRecordingNeverDownloadsMissingModel() async throws {
        let engine = FakeParakeetEngine(cached: false)
        let model = RemuxParakeetModel(engine: engine)
        do {
            try await model.prepare()
            XCTFail("Missing model must direct the user to Settings")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Settings → Dictation"))
        }
        let counts = await engine.counts()
        XCTAssertEqual(counts.downloads, 0)
        XCTAssertEqual(counts.loads, 0)
    }

    func testExplicitDownloadLoadsModelAndTranscribesOffline() async throws {
        let engine = FakeParakeetEngine(cached: false)
        let model = RemuxParakeetModel(engine: engine)
        try await model.prepare(allowDownload: true)
        let ready = await model.snapshot()
        XCTAssertEqual(ready, .ready)
        let text = try await model.transcribe(URL(fileURLWithPath: "/unused.caf"))
        XCTAssertEqual(text, "Testing one two three.")
        let counts = await engine.counts()
        XCTAssertEqual(counts.downloads, 1)
        XCTAssertEqual(counts.loads, 1)
        XCTAssertEqual(counts.transcriptions, 1)
    }

    func testConcurrentPreparationCoalescesCachedLoad() async throws {
        let gate = ParakeetTestGate()
        let engine = FakeParakeetEngine(cached: true, loadGate: gate)
        let model = RemuxParakeetModel(engine: engine)
        let first = Task { try await model.prepare() }
        await gate.waitUntilEntered()
        let second = Task { try await model.prepare(allowDownload: true) }
        await Task.yield()
        await gate.open()
        try await first.value
        try await second.value
        let counts = await engine.counts()
        XCTAssertEqual(counts.downloads, 0)
        XCTAssertEqual(counts.loads, 1)
    }

    func testFailedLoadCanRetryWithoutDownloadingAgain() async throws {
        let engine = FakeParakeetEngine(cached: true)
        await engine.failNextLoad()
        let model = RemuxParakeetModel(engine: engine)
        do { try await model.prepare(); XCTFail("Expected load error") } catch {}
        try await model.prepare()
        let ready = await model.snapshot()
        let counts = await engine.counts()
        XCTAssertEqual(ready, .ready)
        XCTAssertEqual(counts.downloads, 0)
        XCTAssertEqual(counts.loads, 2)
    }

    func testMemoryReleaseWaitsForFinalTranscriptionThenReloadsCache() async throws {
        let gate = ParakeetTestGate()
        let engine = FakeParakeetEngine(cached: true, transcriptionGate: gate)
        let model = RemuxParakeetModel(engine: engine)
        let result = Task { try await model.transcribe(URL(fileURLWithPath: "/unused.caf")) }
        await gate.waitUntilEntered()
        await model.releaseWhenIdle()
        let during = await engine.counts()
        XCTAssertEqual(during.unloads, 0)
        await gate.open()
        _ = try await result.value
        let after = await engine.counts()
        XCTAssertEqual(after.unloads, 1)
        try await model.prepare()
        let reloaded = await engine.counts()
        XCTAssertEqual(reloaded.loads, 2)
        XCTAssertEqual(reloaded.downloads, 0)
    }

    func testAudioFileContainsFinalAcceptedBufferAndDeletesOnRelease() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<4_800 { samples[i] = 0.2 }
        var consumer: GhosttyParakeetAudioFileConsumer? = try .init(format: format, onLevel: { _ in })
        let url = try XCTUnwrap(consumer?.url)
        XCTAssertTrue(consumer!.accept(buffer, at: AVAudioTime(sampleTime: 0, atRate: 48_000)))
        XCTAssertTrue(consumer!.accept(buffer, at: AVAudioTime(sampleTime: 4_800, atRate: 48_000)))
        XCTAssertTrue(consumer!.finish())
        XCTAssertTrue(consumer!.finish())
        XCTAssertFalse(consumer!.accept(buffer, at: AVAudioTime(sampleTime: 9_600, atRate: 48_000)))
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 9_600)
        consumer = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testEnginePreferenceSelectsParakeetAndPreservesAppleDefault() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: RemuxDictationEngine.preferenceKey)
        defer { defaults.set(previous, forKey: RemuxDictationEngine.preferenceKey) }
        defaults.removeObject(forKey: RemuxDictationEngine.preferenceKey)
        XCTAssertEqual(RemuxDictationEngine.current, .apple)
        XCTAssertFalse(GhosttyComposerDictationBackendFactory.makeDefault() is GhosttyParakeetComposerDictationBackend)
        defaults.set("parakeet", forKey: RemuxDictationEngine.preferenceKey)
        let backend = GhosttyComposerDictationBackendFactory.makeDefault()
        XCTAssertTrue(backend is GhosttyParakeetComposerDictationBackend)
        XCTAssertFalse(backend.requiresSpeechRecognitionAuthorization)
        defaults.set("invalid-old-value", forKey: RemuxDictationEngine.preferenceKey)
        XCTAssertEqual(RemuxDictationEngine.current, .apple)
    }

    func testBackendReportsMissingModelWithoutStartingCapture() async {
        let model = RemuxParakeetModel(engine: FakeParakeetEngine(cached: false))
        let backend = GhosttyParakeetComposerDictationBackend(model: model)
        let failure = expectation(description: "Missing model explained")
        backend.start(id: 1, locale: .current, requestedAt: 0) { event in
            if case .failed(let message) = event {
                XCTAssertTrue(message.contains("Settings → Dictation"))
                failure.fulfill()
            }
        }
        await fulfillment(of: [failure], timeout: 3)
        backend.cancelAll {}
    }

    func testCancelledModelStartupDoesNotOpenMicrophoneLater() async throws {
        let gate = ParakeetTestGate()
        let model = RemuxParakeetModel(engine: FakeParakeetEngine(cached: true, loadGate: gate))
        let backend = GhosttyParakeetComposerDictationBackend(model: model)
        let unwanted = expectation(description: "Cancelled startup must not activate audio")
        unwanted.isInverted = true
        backend.start(id: 1, locale: .current, requestedAt: 0) { event in
            switch event {
            case .starting, .started, .failed, .recognitionFailed: unwanted.fulfill()
            default: break
            }
        }
        await gate.waitUntilEntered()
        let cancelled = expectation(description: "Cancelled")
        backend.cancel(id: 1) { cancelled.fulfill() }
        await fulfillment(of: [cancelled], timeout: 3)
        await gate.open()
        try await model.prepare()
        await fulfillment(of: [unwanted], timeout: 0.2)
    }

    func testMemoryWarningDoesNotPretendMissingModelWasDownloaded() async {
        let model = RemuxParakeetModel(engine: FakeParakeetEngine(cached: false))
        await model.releaseWhenIdle()
        let status = await model.snapshot()
        XCTAssertEqual(status, .missing)
    }
}

private actor ParakeetTestGate {
    private var entered = false
    private var opened = false
    private var entrants: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        entrants.forEach { $0.resume() }
        entrants.removeAll()
        if !opened { await withCheckedContinuation { waiters.append($0) } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entrants.append($0) } }
    }
    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private actor FakeParakeetEngine: RemuxParakeetEngine {
    private var cached: Bool
    private var downloads = 0
    private var loads = 0
    private var transcriptions = 0
    private var unloads = 0
    private var shouldFailLoad = false
    private let loadGate: ParakeetTestGate?
    private let transcriptionGate: ParakeetTestGate?
    init(cached: Bool, loadGate: ParakeetTestGate? = nil, transcriptionGate: ParakeetTestGate? = nil) {
        self.cached = cached
        self.loadGate = loadGate
        self.transcriptionGate = transcriptionGate
    }
    func isCached() -> Bool { cached }
    func download(progress: @escaping @Sendable (Double) -> Void) {
        downloads += 1
        progress(0.5)
        cached = true
        progress(1)
    }
    func load() async throws {
        loads += 1
        await loadGate?.wait()
        if shouldFailLoad { shouldFailLoad = false; throw RemuxParakeetError.notReady }
    }
    func failNextLoad() { shouldFailLoad = true }
    func transcribe(_ file: URL) async -> String {
        transcriptions += 1
        await transcriptionGate?.wait()
        return "Testing one two three."
    }
    func unload() { unloads += 1 }
    func counts() -> (downloads: Int, loads: Int, transcriptions: Int, unloads: Int) {
        (downloads, loads, transcriptions, unloads)
    }
}
