@preconcurrency import AVFoundation
import Foundation

final class GhosttyParakeetComposerDictationBackend:
    GhosttyComposerDictationBackendProtocol, @unchecked Sendable
{
    let requiresSpeechRecognitionAuthorization = false
    private let state: State
    private let lock = NSLock()
    private var desiredRunID: UInt64?

    init(model: RemuxParakeetModel = .shared) { state = State(model: model) }

    func prepare(locale: Locale) {
        Task { await state.prepare() }
    }

    func start(
        id: UInt64, locale: Locale, requestedAt: UInt64,
        handler: @escaping @Sendable (GhosttyComposerDictationBackendEvent) -> Void
    ) {
        setDesired(id)
        Task {
            await state.start(id: id, handler: handler, isDesired: { self.isDesired(id) })
        }
    }

    func finish(id: UInt64) { Task { await state.finish(id: id) } }

    func cancel(id: UInt64, completion: @escaping @Sendable () -> Void) {
        lock.lock()
        if desiredRunID == id { desiredRunID = nil }
        lock.unlock()
        Task { await state.cancel(id: id); completion() }
    }

    func cancelAll(completion: @escaping @Sendable () -> Void) {
        setDesired(nil)
        Task { await state.cancel(id: nil); completion() }
    }

    private func setDesired(_ id: UInt64?) {
        lock.lock()
        desiredRunID = id
        lock.unlock()
    }

    private func isDesired(_ id: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return desiredRunID == id
    }

    private actor State {
        final class Run: @unchecked Sendable {
            let id: UInt64
            let handler: @Sendable (GhosttyComposerDictationBackendEvent) -> Void
            let capture = GhosttyComposerAudioCaptureSession()
            var audio: GhosttyParakeetAudioFileConsumer?
            var finishing = false

            init(id: UInt64, handler: @escaping @Sendable (GhosttyComposerDictationBackendEvent) -> Void) {
                self.id = id
                self.handler = handler
            }
        }

        let model: RemuxParakeetModel
        var run: Run?

        init(model: RemuxParakeetModel) { self.model = model }

        func prepare() async {
            // A missing model is explained on Record; never download on launch.
            if await model.snapshot() == .downloaded { try? await model.prepare() }
        }

        func start(
            id: UInt64,
            handler: @escaping @Sendable (GhosttyComposerDictationBackendEvent) -> Void,
            isDesired: @escaping @Sendable () -> Bool
        ) async {
            guard isDesired() else { return }
            await cancel(id: nil)
            do {
                handler(.preparing)
                try await model.prepare()
                guard isDesired() else { return }
                let current = Run(id: id, handler: handler)
                run = current
                handler(.starting)
                current.audio = try current.capture.start(
                    makeConsumer: { format in
                        try GhosttyParakeetAudioFileConsumer(format: format) { handler(.audioLevel($0)) }
                    },
                    onStarted: { [weak self] in Task { await self?.didStart(id: id) } },
                    onFailure: { [weak self] in Task { await self?.didFail(id: id) } }
                )
                if !isDesired() { await cancel(id: id) }
            } catch {
                guard isDesired() else { return }
                await cancel(id: id)
                handler(.failed(error is RemuxParakeetError
                    ? error.localizedDescription
                    : "Couldn’t start Parakeet. Check Settings → Dictation and try again."))
            }
        }

        func finish(id: UInt64) async {
            guard let current = run, current.id == id, !current.finishing else { return }
            current.finishing = true
            let drained = await withCheckedContinuation { continuation in
                current.capture.finish { continuation.resume(returning: $0) }
            }
            guard run === current else { return }
            guard drained, let file = current.audio?.url else {
                await didFail(id: id)
                return
            }
            do {
                let text = try await model.transcribe(file)
                guard run === current else { return }
                run = nil
                current.handler(.hypothesis(text))
                current.handler(.completed)
            } catch {
                guard run === current else { return }
                run = nil
                current.handler(.failed("Parakeet couldn’t transcribe this recording. Try again."))
            }
        }

        func cancel(id: UInt64?) async {
            guard let current = run, id == nil || current.id == id else { return }
            run = nil
            current.capture.cancel()
            current.audio?.cancel()
        }

        private func didStart(id: UInt64) {
            guard let run, run.id == id, !run.finishing else { return }
            run.handler(.started)
        }

        private func didFail(id: UInt64) async {
            guard let current = run, current.id == id else { return }
            await cancel(id: id)
            current.handler(.recognitionFailed)
        }
    }
}

/// Keep the recording on disk rather than retaining unbounded PCM in memory.
/// The shared capture owner drains through the stop timestamp before closing it.
final class GhosttyParakeetAudioFileConsumer: GhosttyComposerAudioCaptureConsumer, @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var failed = false
    private let onLevel: @Sendable (CGFloat) -> Void
    private var lastMeterTime = Date.distantPast

    init(format: AVAudioFormat, onLevel: @escaping @Sendable (CGFloat) -> Void) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("remux-dictation-\(UUID()).caf")
        self.onLevel = onLevel
        file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func accept(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let file, !failed else { return false }
        do { try file.write(from: buffer) } catch { failed = true; return false }
        let now = Date()
        if now.timeIntervalSince(lastMeterTime) >= 0.075 {
            lastMeterTime = now
            onLevel(GhosttyComposerAudioLevelMeter.normalizedPeak(for: buffer))
        }
        return true
    }

    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        file = nil
        return !failed
    }

    func cancel() { _ = finish() }
}
