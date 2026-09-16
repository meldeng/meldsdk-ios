import XCTest

@testable import MeldSDK

/// One `onPaymentSubmitted` per mount, whichever way the provider says the customer finished.
final class TerminalGateTests: XCTestCase {

    private func status(_ s: MeldStatus) -> MeldEvent {
        .statusChange(MeldStatusChange(orderId: "ord_1", status: s, providerStatus: nil, raw: nil))
    }

    private func error(recoverable: Bool) -> MeldEvent {
        .error(MeldError(orderId: "ord_1", code: "x", message: "x", recoverable: recoverable))
    }

    /// Uphold's authorize widget: `complete` and nothing else, ever.
    func testSubmittedAlone() {
        var gate = TerminalGate()

        XCTAssertTrue(gate.admit(.paymentSubmitted))
    }

    /// A provider that reports its own order complete and never sends a submitted message still
    /// gets the host its one terminal callback.
    func testCompletedStatusAlone() {
        var gate = TerminalGate()

        XCTAssertTrue(gate.admit(status(.completed)))
    }

    /// Hosted-link Apple Pay: `commit_success` then `polling_start`, both meaning submitted.
    func testRepeatedSubmittedFiresOnce() {
        var gate = TerminalGate()

        XCTAssertTrue(gate.admit(.paymentSubmitted))
        XCTAssertFalse(gate.admit(.paymentSubmitted))
    }

    /// The same flow's later `polling_success`. The status still reaches the host; the terminal
    /// callback does not repeat.
    func testCompletedAfterSubmittedDoesNotRefire() {
        var gate = TerminalGate()

        XCTAssertTrue(gate.admit(.paymentSubmitted))
        XCTAssertFalse(gate.admit(status(.completed)))
    }

    /// Mercuryo card sends "payment finished" and a `paid` status as unrelated messages, in no
    /// guaranteed order. Either arriving first must win.
    func testSubmittedAfterCompletedDoesNotRefire() {
        var gate = TerminalGate()

        XCTAssertTrue(gate.admit(status(.completed)))
        XCTAssertFalse(gate.admit(.paymentSubmitted))
    }

    /// Progress is not terminal.
    func testPendingIsNotTerminal() {
        var gate = TerminalGate()

        XCTAssertFalse(gate.admit(status(.pending)))
        XCTAssertTrue(gate.admit(.paymentSubmitted))
    }

    func testReadyIsNotTerminal() {
        var gate = TerminalGate()

        XCTAssertFalse(gate.admit(.ready))
        XCTAssertTrue(gate.admit(.paymentSubmitted))
    }

    /// "Payment failed" must never be followed by "payment submitted".
    func testFailedStatusClosesTheGate() {
        var gate = TerminalGate()

        XCTAssertFalse(gate.admit(status(.failed)))
        XCTAssertFalse(gate.admit(.paymentSubmitted))
    }

    func testCancelClosesTheGate() {
        var gate = TerminalGate()

        XCTAssertFalse(gate.admit(.cancel))
        XCTAssertFalse(gate.admit(.paymentSubmitted))
    }

    func testCancelledStatusClosesTheGate() {
        var gate = TerminalGate()

        XCTAssertFalse(gate.admit(status(.cancelled)))
        XCTAssertFalse(gate.admit(.paymentSubmitted))
    }

    func testTerminalErrorClosesTheGate() {
        var gate = TerminalGate()

        XCTAssertFalse(gate.admit(error(recoverable: false)))
        XCTAssertFalse(gate.admit(.paymentSubmitted))
    }

    /// A script that failed to load is recoverable: the mount is still alive and the customer may
    /// yet pay, so closing here would swallow the real terminal event.
    func testRecoverableErrorLeavesTheGateOpen() {
        var gate = TerminalGate()

        XCTAssertFalse(gate.admit(error(recoverable: true)))
        XCTAssertTrue(gate.admit(.paymentSubmitted))
    }
}
