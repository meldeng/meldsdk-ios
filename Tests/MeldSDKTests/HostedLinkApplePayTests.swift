import XCTest
@testable import MeldSDK

/// Provider-hosted Apple Pay (shape 3): dispatch, and the mapping from the hosted page's own event
/// vocabulary to Meld events. Mounting is not exercised here — it needs a real view hierarchy and a
/// device with a provisioned card — so the parts that can go wrong silently are tested directly.
final class HostedLinkApplePayTests: XCTestCase {

    private let adapter = HostedLinkApplePayAdapter()

    private func order(_ json: String) throws -> MeldOrder {
        try MeldOrder.from(jsonString: json)
    }

    private func linkOrder(_ url: String = "https://pay.coinbase.com/buy/x") throws -> MeldOrder {
        try order(#"{"id":"o1","paymentMethodType":"APPLE_PAY","paymentMethodResponseDetails":{"paymentLinkUrl":"\#(url)"}}"#)
    }

    // MARK: - Dispatch

    func testClaimsAProviderHostedPaymentLink() throws {
        let order = try linkOrder()
        XCTAssertTrue(adapter.matches(order))
        let caps = Meld.capabilities(for: order)
        XCTAssertTrue(caps.embeddable, "a hosted page is mounted into a view, unlike a native sheet")
        XCTAssertEqual(caps.surface, "embedded")
        XCTAssertTrue(caps.requiresUserGesture, "the host must not put its own button in front")
    }

    func testDoesNotClaimANativeOrder() throws {
        let order = try order(#"{"id":"o1","paymentMethodType":"APPLE_PAY","paymentMethodResponseDetails":{"sessionToken":"jwt","merchantIdentifier":"m"}}"#)
        XCTAssertFalse(adapter.matches(order))
    }

    func testDoesNotClaimAnOrderWithNoPaymentLink() throws {
        // Provider-hosted is claimed only when there is a launchable link to load. An Apple Pay
        // order carrying neither a link nor the native fields is unsupported, not this adapter's.
        let order = try order(#"{"id":"o1","paymentMethodType":"APPLE_PAY","paymentMethodResponseDetails":{"presentation":"PROVIDER_HOSTED"}}"#)
        XCTAssertFalse(adapter.matches(order))
    }

    func testDoesNotClaimACardOrder() throws {
        let order = try order(#"{"id":"o1","paymentMethodType":"CREDIT_DEBIT_CARD","paymentMethodResponseDetails":{"paymentLinkUrl":"https://pay.coinbase.com/buy/x"}}"#)
        XCTAssertFalse(adapter.matches(order))
    }

    func testReadsTheForwardLookingSurfaceUrlToo() throws {
        // The contract is moving from a provider-shaped `paymentLinkUrl` to a neutral `surface.url`;
        // the adapter reads both so the rename is not a flag day.
        let order = try order(#"{"id":"o1","paymentMethodType":"APPLE_PAY","paymentMethodResponseDetails":{"presentation":"PROVIDER_HOSTED","surface":{"url":"https://pay.coinbase.com/buy/x"}}}"#)
        XCTAssertTrue(adapter.matches(order))
    }

    // MARK: - Event mapping

    private func events(_ eventName: String, data: String = "{}") -> [MeldEvent] {
        HostedLinkApplePayAdapter.interpret(
            ["handler": "cbOnramp", "body": #"{"eventName":"\#(eventName)","data":\#(data)}"#],
            orderId: "o1", host: nil)
    }

    func testLoadSuccessIsReady() {
        guard case .ready = events("onramp_api.load_success").first else {
            return XCTFail("expected .ready")
        }
    }

    func testCommitSuccessIsPaymentSubmittedNotCompleted() {
        // Deliberately NOT a completed status: the provider accepting the payment is a UX hint,
        // and settlement truth is the Meld webhook.
        guard case .paymentSubmitted = events("onramp_api.commit_success").first else {
            return XCTFail("expected .paymentSubmitted")
        }
    }

    func testCancelIsCancel() {
        guard case .cancel = events("onramp_api.cancel").first else {
            return XCTFail("expected .cancel")
        }
    }

    func testErrorCarriesTheProviderMessage() {
        let mapped = events("onramp_api.commit_error", data: #"{"errorMessage":"card declined"}"#)
        guard case let .error(error) = mapped.first else { return XCTFail("expected .error") }
        XCTAssertEqual(error.code, "onramp_api.commit_error")
        XCTAssertEqual(error.message, "card declined")
        XCTAssertTrue(error.recoverable, "a declined commit can be retried on the same order")
    }

    func testPollingStartIsAlsoPaymentSubmitted() {
        guard case .paymentSubmitted = events("onramp_api.polling_start").first else {
            return XCTFail("expected .paymentSubmitted")
        }
    }

    func testPollingSuccessIsACompletedStatusChange() {
        guard case let .statusChange(change) = events("onramp_api.polling_success").first else {
            return XCTFail("expected .statusChange")
        }
        XCTAssertEqual(change.status, .completed)
        XCTAssertEqual(change.providerStatus, "onramp_api.polling_success")
    }

    func testErrorCarriesTheProviderCodeSoAHostCanChooseARecoveryPath() {
        // Without the provider's own code a host cannot tell "start a new order" from "fall back to
        // the provider's full checkout", and would have to offer the same dead end for both.
        let loadError = events("onramp_api.load_error", data: #"{"errorMessage":"nope","errorCode":"ERROR_CODE_X"}"#)
        guard case let .error(recoverable) = loadError.first else { return XCTFail("expected .error") }
        XCTAssertEqual(recoverable.detail, "ERROR_CODE_X")
        XCTAssertTrue(recoverable.recoverable)

        // A spent order cannot be retried on the same link.
        let pollingError = events("onramp_api.polling_error", data: #"{"errorMessage":"gone"}"#)
        guard case let .error(terminal) = pollingError.first else { return XCTFail("expected .error") }
        XCTAssertFalse(terminal.recoverable)

        // Nor can an init failure.
        let initError = events("onramp_api.load_error", data: #"{"errorCode":"ERROR_CODE_INIT"}"#)
        guard case let .error(initFailure) = initError.first else { return XCTFail("expected .error") }
        XCTAssertFalse(initFailure.recoverable)
    }

    func testUnmappedEventIsIgnoredRatherThanTreatedAsFailure() {
        XCTAssertTrue(events("onramp_api.something_new").isEmpty)
    }

    func testMalformedPayloadIsDropped() {
        let mapped = HostedLinkApplePayAdapter.interpret(
            ["handler": "cbOnramp", "body": "not json"], orderId: "o1", host: nil)
        XCTAssertTrue(mapped.isEmpty)
    }

    // MARK: - Signals a host's load-timeout depends on

    func testReadyComesFromTheProviderNotFromPageLoad() throws {
        // A host runs a load-timeout against "the provider never initialised". If the SDK reported
        // ready when the PAGE finished loading, that timeout would be cancelled by a page that
        // renders nothing, and the user would wait forever with no error and no fallback.
        let order = try linkOrder()
        XCTAssertTrue(adapter.matches(order))

        // Nothing but load_success produces .ready.
        for event in ["onramp_api.polling_start", "onramp_api.commit_success", "onramp_api.cancel"] {
            for mapped in events(event) {
                if case .ready = mapped { XCTFail("\(event) must not report ready") }
            }
        }
        guard case .ready = events("onramp_api.load_success").first else {
            return XCTFail("load_success is the ready signal")
        }
    }

    func testButtonNotFoundIsARecoverableError() {
        let mapped = HostedLinkApplePayAdapter.interpret(
            ["handler": HostedLinkApplePayAdapter.autoPresentChannel,
             "body": HostedLinkApplePayAdapter.autoPresentButtonNotFound],
            orderId: "o1", host: nil)
        guard case let .error(error) = mapped.first else { return XCTFail("expected .error") }
        XCTAssertEqual(error.code, "apple_pay_button_not_found")
        XCTAssertTrue(error.recoverable, "offer another method rather than retry the same page")
    }
}
