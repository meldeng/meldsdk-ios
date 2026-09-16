import XCTest

@testable import MeldSDK

/// One `onPaymentSubmitted` per mount, whichever way the provider says the customer finished.
final class TerminalGateTests: XCTestCase {

    private final class Recorder {
        private(set) var events: [String] = []
        lazy var handlers: MeldEventHandlers = MeldEventHandlers(
            onPaymentSubmitted: { [weak self] _ in self?.events.append("submitted") },
            onStatusChange: { [weak self] c in self?.events.append("status:\(c.status.rawValue)") },
            onCancel: { [weak self] _ in self?.events.append("cancel") },
            onError: { [weak self] _ in self?.events.append("error") }
        ).gated()

        func status(_ s: MeldStatus) {
            handlers.onStatusChange?(
                MeldStatusChange(orderId: "ord_1", status: s, providerStatus: nil, raw: nil))
        }

        func submitted() { handlers.onPaymentSubmitted?("ord_1") }

        func error(recoverable: Bool) {
            handlers.onError?(
                MeldError(orderId: "ord_1", code: "x", message: "x", recoverable: recoverable))
        }

        func count(_ kind: String) -> Int { events.filter { $0 == kind }.count }
    }

    /// Uphold's authorize widget: `complete` and nothing else, ever.
    func testSubmittedAlone() {
        let r = Recorder()

        r.submitted()

        XCTAssertEqual(r.count("submitted"), 1)
    }

    /// A provider that reports its own order complete and never sends a submitted message.
    func testCompletedStatusAloneFiresAfterTheStatus() {
        let r = Recorder()

        r.status(.completed)

        XCTAssertEqual(r.events, ["status:completed", "submitted"])
    }

    /// Hosted-link Apple Pay sends `commit_success` then `polling_start`, both meaning submitted.
    func testRepeatedSubmittedFiresOnce() {
        let r = Recorder()

        r.submitted()
        r.submitted()

        XCTAssertEqual(r.count("submitted"), 1)
    }

    /// The same flow's later `polling_success`. The status still lands; the callback does not repeat.
    func testCompletedAfterSubmittedDoesNotRefire() {
        let r = Recorder()

        r.submitted()
        r.status(.completed)

        XCTAssertEqual(r.count("submitted"), 1)
        XCTAssertEqual(r.count("status:completed"), 1)
    }

    /// Mercuryo card sends both as unrelated messages in no guaranteed order. Either wins.
    func testSubmittedAfterCompletedDoesNotRefire() {
        let r = Recorder()

        r.status(.completed)
        r.submitted()

        XCTAssertEqual(r.count("submitted"), 1)
    }

    func testPendingDoesNotCloseTheGate() {
        let r = Recorder()

        r.status(.pending)
        r.submitted()

        XCTAssertEqual(r.count("submitted"), 1)
    }

    /// "Payment failed" must never be followed by "payment submitted".
    func testFailedStatusClosesTheGate() {
        let r = Recorder()

        r.status(.failed)
        r.submitted()

        XCTAssertEqual(r.count("submitted"), 0)
        XCTAssertEqual(r.count("status:failed"), 1)
    }

    func testCancelledStatusClosesTheGate() {
        let r = Recorder()

        r.status(.cancelled)
        r.submitted()

        XCTAssertEqual(r.count("submitted"), 0)
    }

    func testCancelClosesTheGate() {
        let r = Recorder()

        r.handlers.onCancel?("ord_1")
        r.submitted()

        XCTAssertEqual(r.count("submitted"), 0)
        XCTAssertEqual(r.count("cancel"), 1)
    }

    func testTerminalErrorClosesTheGate() {
        let r = Recorder()

        r.error(recoverable: false)
        r.submitted()

        XCTAssertEqual(r.count("submitted"), 0)
    }

    /// A load failure is recoverable: the surface is still alive and the customer may yet pay, so
    /// closing here would swallow the real terminal event.
    func testRecoverableErrorLeavesTheGateOpen() {
        let r = Recorder()

        r.error(recoverable: true)
        r.submitted()

        XCTAssertEqual(r.count("submitted"), 1)
    }
}
