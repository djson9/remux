import XCTest
@testable import Remux

final class RemuxTerminalDeepLinkTests: XCTestCase {
    func testNativeTargetRoundTripsThroughURLWithoutChangingPunctuation() throws {
        let link = RemuxTerminalDeepLink(server: UUID().uuidString, target: "=Jay's Work & Play:@17.%42")
        XCTAssertEqual(RemuxTerminalDeepLink(url: link.url), link)
        XCTAssertEqual(link.sessionName, "Jay's Work & Play")
        XCTAssertTrue(link.url.absoluteString.contains("%2542"))
    }

    func testWindowAndPaneIndexesUseTheSameAddressForm() throws {
        let link = try XCTUnwrap(RemuxTerminalDeepLink(url: URL(string: "remuxdev://open?server=example.com&target=work:2.1")!))
        XCTAssertEqual(link.server, "example.com")
        XCTAssertEqual(link.sessionName, "work")
        XCTAssertEqual(link.target, "work:2.1")
    }

    func testMalformedOrAmbiguousURLsAreRejected() {
        for value in [
            "https://open?server=example.com&target=work:2.1",
            "remuxdev://open/other?server=example.com&target=work:2.1",
            "remuxdev://open?server=example.com&target=work",
            "remuxdev://open?server=example.com&target=:2.1",
            "remuxdev://open?server=example.com&target==:2.1",
            "remuxdev://open?server=example.com&target=work:",
            "remuxdev://open?server=&target=work:2.1",
            "remuxdev://open?server=example.com&server=other&target=work:2.1",
            "remuxdev://open?server=example.com&target=work:2.1&command=hello",
            "remuxdev://open?server=example.com&target=work:2.1%0Anew-window",
            "remuxdev://open?server=example.com&target=work:2.1#fragment",
            "remuxdev://user@open?server=example.com&target=work:2.1"
        ] {
            XCTAssertNil(RemuxTerminalDeepLink(url: URL(string: value)!), value)
        }
    }

    func testResolvedTargetParsesOnlyCompleteTypedIdentities() throws {
        let target = try XCTUnwrap(TmuxResolvedPaneTarget(reply: "Jay's Work\t@17\t%42\n"))
        XCTAssertEqual(target.sessionName, "Jay's Work")
        XCTAssertEqual(target.windowID, 17)
        XCTAssertEqual(target.paneID, 42)
        for value in ["", "work\t17\t42", "work\t@17\t%bad", "work\t@17\t%42\textra", "\t@17\t%42"] {
            XCTAssertNil(TmuxResolvedPaneTarget(reply: value))
        }
    }

    func testNativePaneIndexAndIDSelectTheRequestedPaneAmongSiblings() {
        let reply = "work\t@17\t%41\t0\t1\nwork\t@17\t%42\t1\t0\n"
        XCTAssertEqual(TmuxResolvedPaneTarget.resolve(reply: reply, target: "work:2.1")?.paneID, 42)
        XCTAssertEqual(TmuxResolvedPaneTarget.resolve(reply: reply, target: "=work:@17.%42")?.paneID, 42)
        XCTAssertEqual(TmuxResolvedPaneTarget.resolve(reply: reply, target: "work:2")?.paneID, 41)
        XCTAssertNil(TmuxResolvedPaneTarget.resolve(reply: reply, target: "work:2.99"))
        XCTAssertNil(TmuxResolvedPaneTarget.resolve(reply: reply, target: "work:2.%99"))
    }
}
