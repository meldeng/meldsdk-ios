import XCTest
@testable import MeldSDK

/// Tests for the public Apple Pay surface that don't require presenting the PassKit sheet:
/// capabilities reporting and the order-validation guards `presentApplePay` applies before it
/// ever touches PassKit.
final class ApplePayPublicAPITests: XCTestCase {

    private func order(_ json: String) throws -> MeldOrder {
        try MeldOrder.from(jsonString: json)
    }

    private let request = MeldApplePayRequest(
        amount: 15, currencyCode: "EUR",
        walletAddress: "0xWallet", clientIpAddress: "203.0.113.7")

    func testCapabilitiesReportApplePayAsNonEmbeddableNativeSheet() throws {
        let order = try order(#"{"id":"o1","paymentMethodType":"APPLE_PAY","paymentMethodResponseDetails":{}}"#)
        let caps = Meld.capabilities(for: order)
        XCTAssertFalse(caps.embeddable, "Apple Pay isn't mounted into a view")
        XCTAssertEqual(caps.surface, "native-applepay")
        XCTAssertTrue(caps.requiresUserGesture)
    }

    func testMountDispatchesByOrderType_cardOrderWithoutHostThrowsMissingHost() throws {
        // The order type selects the adapter — passing `applePay:` doesn't make a card order use
        // the Apple Pay surface. A card order routed through mount with no host fails for a host.
        let order = try order(#"{"id":"o1","paymentMethodType":"CREDIT_DEBIT_CARD","paymentMethodResponseDetails":{"serviceProviderWidgetUrl":"https://sandbox-exchange.mrcr.io/x","renderMode":"IFRAME"}}"#)
        XCTAssertThrowsError(try Meld.mount(order, applePay: request)) { error in
            guard case MeldMountError.missingHost = error else {
                return XCTFail("expected missingHost, got \(error)")
            }
        }
    }

    func testMountApplePayOrderWithoutRequestThrowsInvalidOrder() throws {
        // An Apple Pay order needs the MeldApplePayRequest; mounting without it is a clear error.
        let order = try order(#"{"id":"o1","paymentMethodType":"APPLE_PAY","paymentMethodResponseDetails":{"sessionToken":"jwt","merchantTransactionId":"s","merchantIdentifier":"m"}}"#)
        XCTAssertThrowsError(try Meld.mount(order)) { error in
            guard case MeldApplePayError.invalidOrder = error else {
                return XCTFail("expected invalidOrder, got \(error)")
            }
        }
    }

    func testMountApplePayOrderMissingSessionTokenThrowsInvalidOrder() throws {
        // APPLE_PAY with the request supplied but no session token — must fail the order guards,
        // which run before any PassKit availability check.
        let order = try order(#"{"id":"o1","paymentMethodType":"APPLE_PAY","paymentMethodResponseDetails":{"merchantTransactionId":"s","merchantIdentifier":"m"}}"#)
        XCTAssertThrowsError(try Meld.mount(order, applePay: request)) { error in
            guard case let MeldApplePayError.invalidOrder(detail) = error else {
                return XCTFail("expected invalidOrder, got \(error)")
            }
            XCTAssertTrue(detail.contains("sessionToken"))
        }
    }

    // MARK: - Dispatch must not regress the shipped Apple Pay path

    func testSparseApplePayOrderStillReachesTheNativeAdapter() throws {
        // Guard for the behaviour that existed before shape dispatch: an APPLE_PAY order the SDK
        // cannot positively classify still resolves to the native adapter, so the caller gets the
        // adapter's precise "missing X" error rather than "unsupported order". An account whose
        // backend does not yet surface merchantIdentifier depends on this.
        let order = try order(#"{"id":"o1","paymentMethodType":"APPLE_PAY","paymentMethodResponseDetails":{"sessionToken":"jwt","merchantTransactionId":"s"}}"#)
        XCTAssertEqual(Meld.capabilities(for: order).surface, "native-applepay")
        XCTAssertThrowsError(try Meld.mount(order, applePay: request)) { error in
            guard case let MeldApplePayError.invalidOrder(detail) = error else {
                return XCTFail("expected invalidOrder, got \(error)")
            }
            XCTAssertTrue(detail.contains("merchantIdentifier"), "want the precise field error, got: \(detail)")
        }
    }

    func testProviderHostedApplePayOrderIsNotClaimedByTheNativeAdapter() throws {
        // The collision shape dispatch exists to fix: a provider-hosted order (payment link) must
        // never be built into a PKPaymentRequest by the native adapter.
        let order = try order(#"{"id":"o1","paymentMethodType":"APPLE_PAY","paymentMethodResponseDetails":{"paymentLinkUrl":"https://pay.coinbase.com/x"}}"#)
        XCTAssertEqual(order.presentation, .providerHosted)
        XCTAssertNotEqual(Meld.capabilities(for: order).surface, "native-applepay")
    }

    func testUnrecognizedPresentationFailsClosed() throws {
        // A shape added after this binary shipped must surface as unsupported, never fall through
        // to an adapter that happens to match on payment method.
        let order = try order(#"{"id":"o1","paymentMethodType":"APPLE_PAY","paymentMethodResponseDetails":{"presentation":"SOMETHING_NEW","sessionToken":"jwt"}}"#)
        XCTAssertEqual(order.presentation, .unrecognized("SOMETHING_NEW"))
        XCTAssertEqual(Meld.capabilities(for: order).surface, "unsupported")
        XCTAssertThrowsError(try Meld.mount(order, applePay: request)) { error in
            guard case MeldMountError.unsupported = error else {
                return XCTFail("expected unsupported, got \(error)")
            }
        }
    }

    func testServedPresentationWinsOverTheFingerprint() throws {
        // Once the backend labels the shape, the label is authoritative — the fingerprint is only
        // the fallback for today's unlabelled responses.
        let order = try order(#"{"id":"o1","paymentMethodType":"APPLE_PAY","paymentMethodResponseDetails":{"presentation":"PROVIDER_HOSTED","sessionToken":"jwt"}}"#)
        XCTAssertEqual(order.presentation, .providerHosted)
    }

    func testApplePayDetailFieldsReadableFromRaw() throws {
        let order = try order(#"{"id":"o1","paymentMethodType":"APPLE_PAY","paymentMethodResponseDetails":{"sessionToken":"jwt","merchantTransactionId":"s","merchantIdentifier":"merchant.io.meld.test"}}"#)
        XCTAssertEqual(order.paymentMethodResponseDetails?["sessionToken"] as? String, "jwt")
        XCTAssertEqual(order.paymentMethodResponseDetails?["merchantIdentifier"] as? String, "merchant.io.meld.test")
    }
}
