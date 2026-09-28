import XCTest

@testable import MeldSDK

/// One terminal callback per mount, whichever way the provider says the customer finished.
final class TerminalGateTests: XCTestCase {

    private final class Recorder {
        let gate = TerminalGate()
        private(set) var events: [String] = []
        lazy var handlers: MeldEventHandlers = MeldEventHandlers(
            onReady: { [weak self] _ in self?.events.append("ready") },
            onPaymentSubmitted: { [weak self] _ in self?.events.append("submitted") },
            onStatusChange: { [weak self] c in self?.events.append("status:\(c.status.rawValue)") },
            onCancel: { [weak self] _ in self?.events.append("cancel") },
            onError: { [weak self] e in self?.events.append(e.recoverable ? "error" : "error:\(e.code)") }
        ).gated(by: gate)

        func status(_ s: MeldStatus) {
            handlers.onStatusChange?(
                MeldStatusChange(orderId: "ord_1", status: s, providerStatus: nil, raw: nil))
        }

        func submitted() { handlers.onPaymentSubmitted?("ord_1") }

        func error(recoverable: Bool) {
            handlers.onError?(
                MeldError(orderId: "ord_1", code: "x", message: "x", recoverable: recoverable))
        }

        func ended() { handlers.sessionEnded?("ord_1") }

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

    /// The same flow's later `polling_success`. Nothing follows the terminal callback, the status included.
    func testCompletedAfterSubmittedDoesNotRefire() {
        let r = Recorder()

        r.submitted()
        r.status(.completed)

        XCTAssertEqual(r.events, ["submitted"])
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

    /// A blocked submission is not the terminal callback: the adapter's own cancel still arrives.
    func testABlockedSubmissionLeavesTheTerminalToTheAdapter() {
        let r = Recorder()

        r.status(.cancelled)
        r.submitted()
        r.status(.completed)
        r.handlers.onCancel?("ord_1")

        XCTAssertEqual(r.events, ["status:cancelled", "status:completed", "cancel"])
    }

    func testNothingIsDeliveredAfterTheTerminalCallback() {
        let r = Recorder()

        r.submitted()
        r.status(.pending)
        r.handlers.onReady?("ord_1")
        r.handlers.onCancel?("ord_1")
        r.error(recoverable: true)
        r.error(recoverable: false)
        r.ended()

        XCTAssertEqual(r.events, ["submitted"])
    }

    func testFailedStatusIsFollowedByTheAdaptersError() {
        let r = Recorder()

        r.status(.failed)
        r.error(recoverable: false)

        XCTAssertEqual(r.events, ["status:failed", "error:x"])
    }

    func testCancelIsNeverRewritten() {
        let r = Recorder()

        r.status(.failed)
        r.handlers.onCancel?("ord_1")

        XCTAssertEqual(r.events, ["status:failed", "cancel"])
    }

    func testAnEndedSessionWithNothingSeenReportsAnUnknownOutcomeOnce() {
        let r = Recorder()

        r.status(.pending)
        r.ended()
        r.ended()

        XCTAssertEqual(r.events, ["status:pending", "error:PAYMENT_OUTCOME_UNKNOWN"])
    }

    func testAnEndedSessionAfterAFailedStatusReportsARejectionOnce() {
        let r = Recorder()

        r.status(.failed)
        r.ended()
        r.ended()

        XCTAssertEqual(r.events, ["status:failed", "error:PAYMENT_REJECTED"])
    }

    func testRecoverableErrorsDoNotSatisfyTheBackstop() {
        let r = Recorder()

        r.error(recoverable: true)
        r.ended()

        XCTAssertEqual(r.events, ["error", "error:PAYMENT_OUTCOME_UNKNOWN"])
    }

    func testNoBackstopAfterTheTerminalCallback() {
        let r = Recorder()

        r.handlers.onCancel?("ord_1")
        r.ended()

        XCTAssertEqual(r.events, ["cancel"])
    }

    func testNoBackstopWhenTheHandleIsUnmounted() {
        let r = Recorder()
        let handle = MeldWidgetHandle(mode: "test", session: EndingSession(r.handlers), gate: r.gate)

        handle.unmount()

        XCTAssertTrue(r.events.isEmpty)
    }

    func testNoBackstopWhenTheHandleIsReleasedWithoutUnmount() {
        let r = Recorder()
        let session = EndingSession(r.handlers)
        var handle: MeldWidgetHandle? = MeldWidgetHandle(mode: "test", session: session, gate: r.gate)
        XCTAssertNotNil(handle)

        handle = nil

        XCTAssertEqual(session.unmounts, 1)
        XCTAssertTrue(r.events.isEmpty)
    }

    func testOnlyTheCodesThatSayNoAttemptExistsRuleOutAnAttempt() {
        let codes = [MeldErrorCode.applePayUnavailable, MeldErrorCode.presentationFailed, MeldErrorCode.paymentRejected,
                     MeldErrorCode.orderStateChanged, MeldErrorCode.verificationPending, MeldErrorCode.paymentOutcomeUnknown]
        XCTAssertEqual(codes, ["APPLE_PAY_UNAVAILABLE", "PRESENTATION_FAILED", "PAYMENT_REJECTED", "ORDER_STATE_CHANGED",
                               "VERIFICATION_PENDING", "PAYMENT_OUTCOME_UNKNOWN"])
        XCTAssertEqual(codes.map(MeldErrorCode.attemptMayExist), [false, false, false, false, false, true])
        for code in ["PAYMENT_STATE_UNAVAILABLE", "WAIT_FOR_PAYMENT", "NAVIGATION_FAILED", "A_CODE_FROM_A_LATER_BUILD"] {
            XCTAssertTrue(MeldErrorCode.attemptMayExist(code), code)
        }
        XCTAssertFalse(MeldError(orderId: "ord_1", code: MeldErrorCode.paymentRejected, message: "x", recoverable: false).attemptMayExist)
        XCTAssertTrue(MeldError(orderId: "ord_1", code: MeldErrorCode.paymentOutcomeUnknown, message: "x", recoverable: false).attemptMayExist)
    }
}

/// An adapter session whose teardown reports through the backstop, as Stripe's and Banxa's do.
private final class EndingSession: MeldProviderSession {
    let handlers: MeldEventHandlers
    private(set) var unmounts = 0
    init(_ handlers: MeldEventHandlers) { self.handlers = handlers }
    func unmount() {
        unmounts += 1
        handlers.sessionEnded?("ord_1")
    }
}
