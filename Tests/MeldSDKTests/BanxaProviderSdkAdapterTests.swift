import XCTest

@testable import MeldSDK

/// Covers the Banxa flow where Banxa's own SDK creates the order on the device
/// (`providerOrderCreation = CLIENT`).
///
/// The risks here are selection ones, and both are silent. A CLIENT card order is also
/// `CREDIT_DEBIT_CARD`, so if `BanxaCardAdapter` claimed it the mount would fail on an
/// `sdkSessionToken` this shape correctly never carries. And if this adapter claimed a *web*
/// Banxa order it would hand Banxa's SDK an order Meld already created, producing a second Banxa
/// order for the same Meld one.
final class BanxaProviderSdkAdapterTests: XCTestCase {

    private func providerSdkOrder(
        paymentMethodType: String = "CREDIT_DEBIT_CARD",
        overrides: [String: Any] = [:],
        removing: [String] = []
    ) -> MeldOrder {
        var details: [String: Any] = [
            "paymentMethodId": "debit-credit-card",
            "crypto": "USDC",
            "blockchain": "POLYGON",
            "fiat": "USD",
            "fiatAmount": "100.00",
            "walletAddress": "0xWallet",
            "redirectUrl": "https://wallet.example.test/return",
            "externalCustomerId": "banxa-identity-ref",
            "externalOrderId": "integrator-order-1",
            "sdkConfigUrl": "https://api.meld.test/crypto/order/headless/order-1/provider-sdk-config",
            "sdkConfigToken": "config-token",
        ]
        details.merge(overrides) { _, new in new }
        for key in removing { details.removeValue(forKey: key) }

        let dict: [String: Any] = [
            "id": "order-1",
            "paymentMethodType": paymentMethodType,
            "payload": ["serviceProvider": "BANXA"],
            "paymentMethodResponseDetails": details,
        ]
        return try! MeldOrder.from(jsonData: try! JSONSerialization.data(withJSONObject: dict))
    }

    func testTheOrderCarriesNoCredentialOrPii() {
        // The order response is persisted verbatim for idempotent replay, so neither a provider account
        // key — which does not expire — nor the customer's email may appear in it. Only a short-lived
        // bearer for the config endpoint does.
        let details = providerSdkOrder().paymentMethodResponseDetails
        XCTAssertNil(details?["apiKey"])
        // Nor the customer's email — the same store, the same absent retention.
        XCTAssertNil(details?["email"])
        XCTAssertNotNil(details?["sdkConfigUrl"])
        XCTAssertNotNil(details?["sdkConfigToken"])
    }

    /// A web-flow Banxa card order: something to render, no SDK parameters.
    private func webOrder() -> MeldOrder {
        let dict: [String: Any] = [
            "id": "order-web",
            "paymentMethodType": "CREDIT_DEBIT_CARD",
            "payload": ["serviceProvider": "BANXA"],
            "paymentMethodResponseDetails": [
                "renderMode": "IFRAME",
                "sdkSessionToken": "primer-client-token",
            ],
        ]
        return try! MeldOrder.from(jsonData: try! JSONSerialization.data(withJSONObject: dict))
    }

    private final class RecordingPresenter: BanxaCheckoutPresenter {
        let capabilities = MeldCapabilities(
            embeddable: false, surface: "recording", requiresUserGesture: true)
        private(set) var presentedOrderId: String?

        final class Session: MeldProviderSession {
            func unmount() {}
        }

        func present(
            order: MeldOrder, context: MeldMountContext, handlers: MeldEventHandlers
        ) throws -> MeldProviderSession {
            presentedOrderId = order.id
            return Session()
        }
    }

    // MARK: - Selection

    func testClientCreatedCardOrderResolvesToTheProviderSdkAdapter() {
        // The registry-order regression: BanxaCardAdapter also matches CREDIT_DEBIT_CARD for BANXA and
        // would fail on the sdkSessionToken this shape does not have.
        let adapter = Meld.adapter(for: providerSdkOrder())
        XCTAssertTrue(
            adapter is BanxaProviderSdkAdapter, "expected BanxaProviderSdkAdapter, got \(String(describing: adapter))")
    }

    func testClientCreatedApplePayOrderResolvesToTheSameAdapter() {
        // One adapter serves both surfaces: paymentMethodId inside the order decides whether Banxa
        // asks Primer for card fields or the Apple Pay sheet.
        let order = providerSdkOrder(
            paymentMethodType: "APPLE_PAY", overrides: ["paymentMethodId": "apple-pay"])
        XCTAssertTrue(Meld.adapter(for: order) is BanxaProviderSdkAdapter)
    }

    func testWebOrderIsStillClaimedByTheCardAdapter() {
        // The other direction: claiming a server-created order would have Banxa's SDK create a second
        // Banxa order for the same Meld order.
        XCTAssertFalse(BanxaProviderSdkAdapter().matches(webOrder()))
        XCTAssertTrue(Meld.adapter(for: webOrder()) is BanxaCardAdapter)
    }

    func testAnotherProvidersSdkOrderIsNotClaimed() {
        var dict: [String: Any] = [
            "id": "order-other",
            "paymentMethodType": "CREDIT_DEBIT_CARD",
            "payload": ["serviceProvider": "MERCURYO"],
            "paymentMethodResponseDetails": ["sdkConfigUrl": "https://x.test/c", "externalOrderId": "o"],
        ]
        let order = try! MeldOrder.from(jsonData: try! JSONSerialization.data(withJSONObject: dict))
        dict.removeAll()
        XCTAssertFalse(BanxaProviderSdkAdapter().matches(order))
    }

    func testAnOrderWithoutTheJoinIsNotClaimed() {
        // externalOrderId is how the Banxa order Banxa is about to create is matched back to Meld's.
        // Without it the SDK would create an order nothing can correlate — worse than not matching.
        XCTAssertFalse(BanxaProviderSdkAdapter().matches(providerSdkOrder(removing: ["externalOrderId"])))
    }

    // MARK: - Capabilities

    func testCapabilitiesSayTheSurfaceIsNotEmbeddable() {
        // Banxa's SDK presents its own modal. An integrator guarding on `embeddable` must not lay out
        // a container for a sheet that never fills it.
        let capabilities = Meld.capabilities(for: providerSdkOrder())
        XCTAssertFalse(capabilities.embeddable)
        XCTAssertEqual(capabilities.surface, "native-sheet")
        XCTAssertTrue(capabilities.requiresUserGesture)
    }

    // MARK: - Mount

    func testMountDelegatesToThePresenter() {
        let presenter = RecordingPresenter()
        let session = try! BanxaProviderSdkAdapter(presenter: presenter).mount(
            order: providerSdkOrder(), context: MeldMountContext(host: nil, applePay: nil), handlers: .init())

        XCTAssertTrue(session is RecordingPresenter.Session)
        XCTAssertEqual(presenter.presentedOrderId, "order-1")
    }
}
