import Combine
import XCTest
@testable import Remux

@MainActor
final class RemuxVoiceComposerEntryTests: XCTestCase {
    func testIntentRetainsRequestBeforeTheViewIsReady() async throws {
        let entry = RemuxVoiceComposerEntry.shared
        entry.cancel()
        defer { entry.cancel() }
        var delivered: UUID?
        let observation = entry.$pendingRequestID.compactMap { $0 }.sink { delivered = $0 }
        defer { observation.cancel() }
        _ = try await RecordInRemuxComposerIntent().perform()
        XCTAssertNotNil(delivered)
    }

    func testRepeatedDeliveryCoalescesUntilConsumed() throws {
        let entry = RemuxVoiceComposerEntry()
        entry.request()
        let first = try XCTUnwrap(entry.pendingRequestID)
        entry.request()
        XCTAssertEqual(entry.pendingRequestID, first)
        entry.consume(first)
        XCTAssertNil(entry.pendingRequestID)
    }

    func testCancelledRequestCannotConsumeANewerPress() throws {
        let entry = RemuxVoiceComposerEntry()
        entry.request()
        let first = try XCTUnwrap(entry.pendingRequestID)
        entry.cancel()
        entry.request()
        let next = try XCTUnwrap(entry.pendingRequestID)
        entry.consume(first)
        XCTAssertEqual(entry.pendingRequestID, next)
    }

    func testOnlyDedicatedRecordingURLIsAccepted() {
        XCTAssertTrue(RemuxVoiceComposerEntry.accepts(URL(string: "remuxdev://record")!))
        for value in ["https://record", "remuxdev://other", "remuxdev://record/other", "remuxdev://record?text=hello"] {
            XCTAssertFalse(RemuxVoiceComposerEntry.accepts(URL(string: value)!))
        }
    }
}
