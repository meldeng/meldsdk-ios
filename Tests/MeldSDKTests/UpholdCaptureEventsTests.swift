import XCTest

@testable import MeldSDK

/// The capture step manages cards; the authorize step takes a payment. Uphold's widget uses the same
/// `cancel` event for both "my dialog closed" and "the customer left", so which step it arrived on is
/// the only thing that distinguishes them.
final class UpholdCaptureEventsTests: XCTestCase {

    /// Observed on a real Uphold session: deleting a card posts a bare `{"type":"cancel"}`, and adding
    /// one does the same. Forwarding it ended the Meld flow and tore the host's checkout down while
    /// the customer was still managing their cards.
    func testCaptureCancelIsNotTerminal() {
        let events = UpholdCardAdapter.interpretCapture(providerMessage: ["type": "cancel"])

        XCTAssertTrue(events.isEmpty, "a capture-step cancel must not end the flow")
    }

    /// Closing the authorize widget is the customer declining to pay, which the host does need.
    func testAuthorizeCancelStillEndsTheFlow() {
        let events = UpholdCardAdapter.interpret(providerMessage: ["type": "cancel"], orderId: "ord_1")

        XCTAssertEqual(events.count, 1)
        guard case .cancel = events[0] else {
            return XCTFail("authorize cancel should map to .cancel, got \(events[0])")
        }
    }

    /// Dropping cancel must not cost us the events the host genuinely needs from this step.
    func testCaptureStillSurfacesReadyAndError() {
        guard case .ready = UpholdCardAdapter.interpretCapture(providerMessage: ["type": "ready"]).first else {
            return XCTFail("capture ready should still be surfaced")
        }
        guard case .error = UpholdCardAdapter.interpretCapture(providerMessage: ["type": "error"]).first else {
            return XCTFail("capture error should still be surfaced")
        }
    }

    /// The bootstrap's own codes are the shared ones on both steps; the widget's own codes pass through.
    func testBootstrapFailuresUseTheSharedCodes() throws {
        func error(_ code: String, capture: Bool) throws -> MeldError {
            let message: [String: Any] = ["type": "error", "detail": ["error": ["code": code, "message": "boom"]]]
            let events = capture ? UpholdCardAdapter.interpretCapture(providerMessage: message)
                : UpholdCardAdapter.interpret(providerMessage: message, orderId: "ord_1")
            guard case let .error(error)? = events.first else { return try XCTUnwrap(nil as MeldError?, "no error for \(code)") }
            return error
        }
        for capture in [true, false] {
            let unloaded = try error("sdk_unavailable", capture: capture)
            XCTAssertEqual(unloaded.code, MeldErrorCode.providerLoadFailed)
            XCTAssertTrue(unloaded.attemptMayExist)
            XCTAssertFalse(unloaded.recoverable)
            XCTAssertEqual(unloaded.detail, "uphold_card_failed:sdk_unavailable")
            XCTAssertEqual(unloaded.message, "boom")

            let unmounted = try error("mount_failed", capture: capture)
            XCTAssertEqual(unmounted.code, MeldErrorCode.presentationFailed)
            XCTAssertFalse(unmounted.attemptMayExist)
            XCTAssertEqual(unmounted.detail, "uphold_card_failed:mount_failed")

            let widget = try error("card_declined", capture: capture)
            XCTAssertEqual(widget.code, "card_declined")
            XCTAssertNil(widget.detail)
        }
    }

    /// The card selection advances the flow out-of-band, so `complete` is never an event of its own.
    func testCaptureCompleteIsNotSurfaced() {
        let events = UpholdCardAdapter.interpretCapture(providerMessage: ["type": "complete"])

        XCTAssertTrue(events.isEmpty)
    }
}
