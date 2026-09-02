import XCTest

@testable import MeldSDK

/// Covers the two ways Banxa card support fails silently rather than loudly:
/// registry dispatch (a Banxa order being claimed by the Mercuryo catch-all) and the
/// Banxa→Meld event mapping.
final class BanxaCardAdapterTests: XCTestCase {

    private func order(
        serviceProvider: String? = "BANXA",
        paymentMethodType: String? = "CREDIT_DEBIT_CARD",
        renderMode: String? = "IFRAME",
        widgetUrl: String? = nil,
        extra: [String: Any] = ["sdkSessionToken": "primer-token"]
    ) -> MeldOrder {
        var raw: [String: Any] = extra
        raw["renderMode"] = renderMode
        if let widgetUrl { raw["serviceProviderWidgetUrl"] = widgetUrl }
        var dict: [String: Any] = ["id": "order-1", "paymentMethodResponseDetails": raw]
        if let paymentMethodType { dict["paymentMethodType"] = paymentMethodType }
        if let serviceProvider { dict["payload"] = ["serviceProvider": serviceProvider] }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! MeldOrder.from(jsonData: data)
    }

    // MARK: - Registry dispatch

    func testBanxaOrderResolvesToBanxaAdapterNotMercuryoCatchAll() {
        // The regression that matters: MercuryoCardAdapter matches any CREDIT_DEBIT_CARD + IFRAME
        // order, so without Banxa registered ahead of it a Banxa order lands in Mercuryo's adapter
        // and dies on the missing widget URL.
        let adapter = Meld.adapter(for: order())
        XCTAssertTrue(adapter is BanxaCardAdapter, "expected BanxaCardAdapter, got \(String(describing: adapter))")
    }

    func testMeldOrderParsesServiceProviderFromPayload() {
        XCTAssertEqual(order().serviceProvider, "BANXA")
        XCTAssertNil(order(serviceProvider: nil).serviceProvider)
    }

    func testMatchesThroughTheAdapterExistential() {
        // The registry holds MeldAdapter existentials, so matching has to work through the protocol
        // and not just on the concrete type.
        let existential: MeldAdapter = BanxaCardAdapter()
        XCTAssertTrue(existential.matches(order()))
    }

    func testMountThrowsWhenNoHostIsProvided() {
        // context.host is nil for surfaces that present themselves (Apple Pay sheets). Banxa card is
        // an embedded widget and has nowhere to render without one.
        XCTAssertThrowsError(
            try BanxaCardAdapter().mount(
                order: order(), context: MeldMountContext(host: nil, applePay: nil), handlers: .init())
        ) { error in
            guard case MeldMountError.missingHost = error else {
                return XCTFail("expected .missingHost, got \(error)")
            }
        }
    }

    func testMercuryoOrderStillResolvesToMercuryo() {
        let mercuryo = order(
            serviceProvider: "MERCURYO",
            widgetUrl: "https://exchange.mercuryo.io/?widget_id=x",
            extra: [:])
        XCTAssertTrue(Meld.adapter(for: mercuryo) is MercuryoCardAdapter)
    }

    func testAnotherPrimerBackedProviderIsNotClaimedByBanxa() {
        // The reason dispatch keys on the provider rather than on the rendering technology: another
        // Primer-backed provider carries the same token shape and must NOT land in Banxa's adapter.
        let stripe = order(serviceProvider: "STRIPE")
        XCTAssertFalse(BanxaCardAdapter().matches(stripe))
    }

    func testOrderWithNoProviderIsNotClaimedByBanxa() {
        // e.g. the mid-flow authorize-session response, which carries no payload.
        XCTAssertFalse(BanxaCardAdapter().matches(order(serviceProvider: nil)))
    }

    func testApplePayOrderIsNotClaimed() {
        // Banxa serves Apple Pay from the same component and the same token as card, and the web SDK
        // presents it — but this adapter cannot. Apple Pay on the Web refuses to run unless the page
        // origin is a domain registered with Apple for Apple Pay, and the bootstrap page's origin is
        // Primer's, which is not ours to register. Claiming the order would put a button on screen
        // that can never open a sheet. A native Primer session is the only route, and it is not built.
        XCTAssertFalse(BanxaCardAdapter().matches(order(paymentMethodType: "APPLE_PAY")))
    }

    func testBanxaApplePayOrderFailsLoudlyRatherThanBeingClaimedByAnotherAdapter() {
        // The other Apple Pay adapter matches on presentation == .providerHosted plus a payment link,
        // neither of which a Banxa order has — so this must surface as an unsupported order rather
        // than mounting something that cannot work.
        var dict: [String: Any] = [
            "id": "order-ap",
            "paymentMethodType": "APPLE_PAY",
            "payload": ["serviceProvider": "BANXA"],
            "paymentMethodResponseDetails": ["presentation": "PROVIDER_SDK", "sdkSessionToken": "tok"],
        ]
        let applePayOrder = try! MeldOrder.from(jsonData: try! JSONSerialization.data(withJSONObject: dict))
        dict.removeAll()

        XCTAssertNil(Meld.adapter(for: applePayOrder), "no adapter should claim a Banxa Apple Pay order")
    }

    func testCapabilitiesReportEmbeddable() {
        XCTAssertTrue(Meld.capabilities(for: order()).embeddable)
    }

    // MARK: - Mount preconditions

    func testMountThrowsWhenClientTokenMissing() {
        // No silent fallback to the hosted checkout URL: that is Banxa's full checkout, a different
        // product, and mounting it would turn a headless integration into a hosted one.
        let hostedOnly = order(widgetUrl: "https://meld.banxa-sandbox.com/papi/transit/?initId=x", extra: [:])
        XCTAssertThrowsError(
            try BanxaCardAdapter().mount(order: hostedOnly, context: MeldMountContext(host: UIView(), applePay: nil), handlers: .init())
        ) { error in
            guard case MeldMountError.unsupported(let detail) = error else {
                return XCTFail("expected .unsupported, got \(error)")
            }
            XCTAssertTrue(detail.contains("sdkSessionToken"))
        }
    }

    func testMountsNativeCheckoutWhenTokenIsPresent() {
        let host = UIView()
        XCTAssertNoThrow(try BanxaCardAdapter().mount(order: order(), context: MeldMountContext(host: host, applePay: nil), handlers: .init()))
    }

    // MARK: - Event mapping

    func testEventMapping() {
        func events(_ type: String, _ detail: [String: Any]? = nil) -> [MeldEvent] {
            var message: [String: Any] = ["type": type]
            if let detail { message["detail"] = detail }
            return BanxaWebCheckoutPresenter.interpret(providerMessage: message, orderId: "order-1")
        }

        guard case .ready = events("ready").first else { return XCTFail("ready") }
        // payment-success is a UX hint only — settlement is confirmed from Banxa's webhook.
        guard case .paymentSubmitted = events("payment-success").first else { return XCTFail("payment-success") }
        guard case .cancel = events("payment-cancel").first else { return XCTFail("payment-cancel") }
        guard case .error = events("payment-failure").first else { return XCTFail("payment-failure") }

        // Inline field validation must NOT surface as onError — it fires while the user types.
        XCTAssertTrue(events("card-error", ["errors": []]).isEmpty)
        // No Meld equivalent; must not be invented.
        XCTAssertTrue(events("payment-start").isEmpty)
        XCTAssertTrue(events("state-change").isEmpty)
    }

    func testPaymentFailureCarriesPrimerErrorCodeAndMessage() {
        // Primer's payment-failure detail is {errorCode, errorMessage}, not {error:{code,message}}.
        let events = BanxaWebCheckoutPresenter.interpret(
            providerMessage: ["type": "payment-failure",
                              "detail": ["errorCode": "card_declined", "errorMessage": "Card was declined"]],
            orderId: "order-1")
        guard case .error(let meldError)? = events.first else { return XCTFail("expected error") }
        XCTAssertEqual(meldError.code, "card_declined")
        XCTAssertEqual(meldError.message, "Card was declined")
        XCTAssertEqual(meldError.orderId, "order-1")
    }

    // MARK: - Vendored bundle

    func testVendoredBundleMatchesItsPinnedHash() throws {
        // Fails closed if the vendored checkout bundle is swapped or revved without re-review.
        XCTAssertNoThrow(try BanxaWebCheckoutPresenter.loadBundle())
        let js = try BanxaWebCheckoutPresenter.loadBundle()
        XCTAssertTrue(js.contains("MeldBanxaCheckout"), "bundle must expose the global the bootstrap uses")
    }

    func testBootstrapPassesTokenAsPropertyAndEscapesIt() {
        let html = BanxaWebCheckoutPresenter.bootstrapHtml(bundleJs: "/*bundle*/", clientToken: "tok\"</script>")
        XCTAssertTrue(html.contains("el.clientToken ="))
        // The token is JSON-encoded, so a quote or a </script> inside it cannot break out.
        XCTAssertFalse(html.contains("tok\"</script>"))
        XCTAssertTrue(html.contains("banxa-primer-checkout"))
    }

    // MARK: - Presenter seam

    /// Records what the adapter hands a presenter, so the seam can be tested without a WebView.
    private final class RecordingPresenter: BanxaCheckoutPresenter {
        let capabilities = MeldCapabilities(embeddable: false, surface: "recording", requiresUserGesture: true)
        private(set) var clientToken: String?
        private(set) var orderId: String?

        final class Session: MeldProviderSession {
            func unmount() {}
        }

        func present(
            order: MeldOrder, context: MeldMountContext, handlers: MeldEventHandlers
        ) throws -> MeldProviderSession {
            self.clientToken = order.paymentMethodResponseDetails?["sdkSessionToken"] as? String
            self.orderId = order.id
            return Session()
        }
    }

    func testMountDelegatesTokenAndOrderIdToTheInjectedPresenter() throws {
        // The seam that lets the Primer-native presenter replace the web one: selection, the token
        // guard and event mapping stay on the adapter, and only presentation is swapped.
        let presenter = RecordingPresenter()
        let session = try BanxaCardAdapter(presenter: presenter).mount(
            order: order(), context: MeldMountContext(host: UIView(), applePay: nil), handlers: .init())

        XCTAssertTrue(session is RecordingPresenter.Session)
        XCTAssertEqual(presenter.clientToken, "primer-token")
        XCTAssertEqual(presenter.orderId, "order-1")
    }

    func testWebPresenterRejectsAnOrderWithNoToken() {
        // Validation belongs to the presenter now, not the adapter: the web component needs an
        // sdkSessionToken and Banxa's own SDK needs order parameters instead, so only the presenter
        // knows what "missing" means. Mounting without a token must fail rather than render a surface
        // Primer can never start a session for.
        XCTAssertThrowsError(
            try BanxaCardAdapter().mount(
                order: order(extra: [:]), context: MeldMountContext(host: UIView(), applePay: nil),
                handlers: .init())
        ) { error in
            guard case MeldMountError.unsupported = error else {
                return XCTFail("expected .unsupported, got \(error)")
            }
        }
    }

    func testDefaultPresenterIsTheWebComponentSoExistingIntegrationsAreUnchanged() {
        XCTAssertTrue(BanxaCardAdapter().presenter is BanxaWebCheckoutPresenter)
        XCTAssertEqual(BanxaCardAdapter().capabilities.surface, "embedded")
        XCTAssertTrue(BanxaCardAdapter().capabilities.embeddable)
    }

    func testCapabilitiesFollowThePresenterRatherThanBeingFixedOnTheAdapter() {
        // A native Primer sheet is not embeddable. An integrator guards on `embeddable`, so this has
        // to be the presenter's answer and not a constant that outlives the web component.
        let adapter = BanxaCardAdapter(presenter: RecordingPresenter())
        XCTAssertFalse(adapter.capabilities.embeddable)
        XCTAssertEqual(adapter.capabilities.surface, "recording")
    }
}
