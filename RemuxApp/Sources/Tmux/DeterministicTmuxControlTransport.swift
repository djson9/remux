import Foundation

actor DeterministicTmuxControlTransport: TmuxControlTransport {
    nonisolated let receivedBytes: AsyncThrowingStream<Data, Error>

    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let chunks: [Data]
    private var started = false
    private var sentCommands: [Data] = []
    private let responder: (@Sendable (Data) async -> Data)?

    init(chunks: [Data], responder: (@Sendable (Data) async -> Data)? = nil) {
        self.chunks = chunks
        self.responder = responder

        var capturedContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        receivedBytes = AsyncThrowingStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation!
    }

    func start(initialViewport: TmuxControlViewport?) async throws {
        _ = initialViewport
        guard !started else { return }
        started = true

        for chunk in chunks {
            continuation.yield(chunk)
        }
    }

    func send(_ data: Data) async throws {
        sentCommands.append(data)
        if TmuxControlClientExit.isRequested(in: data) {
            continuation.finish()
        } else if let responder {
            continuation.yield(await responder(data))
        }
    }

    func close(disposition: TmuxControlTransportCloseDisposition) async {
        _ = disposition
        continuation.finish()
    }

    func commandsSentByGhostty() -> [Data] {
        sentCommands
    }
}
