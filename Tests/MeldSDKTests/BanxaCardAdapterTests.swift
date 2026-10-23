import PrimerSDK
import UIKit
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

    func testWebPresenterThrowsWhenNoHostIsProvided() {
        // context.host is nil for surfaces that present themselves (Apple Pay sheets). The web
        // component is an embedded widget and has nowhere to render without one.
        XCTAssertThrowsError(
            try BanxaCardAdapter(presenter: BanxaWebCheckoutPresenter()).mount(
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

    func testCapabilitiesReportANativeSheet() {
        // Primer's drop-in presents its own modal: the integrator must not lay out a container for it,
        // and routes it the way it routes Stripe's native sheet.
        let capabilities = Meld.capabilities(for: order())
        XCTAssertFalse(capabilities.embeddable)
        XCTAssertEqual(capabilities.surface, "native-sdk")
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

    func testMountsTheWebComponentWhenTokenIsPresent() {
        let host = UIView()
        XCTAssertNoThrow(try BanxaCardAdapter(presenter: BanxaWebCheckoutPresenter())
            .mount(order: order(), context: MeldMountContext(host: host, applePay: nil), handlers: .init()))
    }

    func testNativePresenterNeedsNoHost() throws {
        // Unmounted straight away: the form is presented on the next main-queue turn, which the
        // finished guard then skips, so the test never drives Primer's singleton.
        let session = try BanxaCardAdapter().mount(
            order: order(), context: MeldMountContext(host: nil, applePay: nil), handlers: .init())
        XCTAssertTrue(session is BanxaPrimerCardSession)
        session.unmount()
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

    /// The `banxa:payment-failure` detail captured from a live production decline (test Visa, 3DS
    /// skipped, Primer payment FAILED / CHECKOUT_FAILURE), trimmed to the fields the mapping reads.
    private func primerFailure(origin: String?, paymentId: String? = "KiLILEZlP",
                               diagnosticsId: String? = nil) -> [String: Any] {
        var error: [String: Any] = ["code": "PAYMENT_FAILED",
                                    "message": "The payment \"KiLILEZlP\" was created but failed to be processed."]
        if let origin { error["data"] = ["error": ["name": "SdkError", "origin": origin, "code": "PAYMENT_FAILED"]] }
        if let diagnosticsId { error["diagnosticsId"] = diagnosticsId }
        var detail: [String: Any] = ["error": error, "paymentMethodType": "PAYMENT_CARD"]
        if let paymentId { detail["payment"] = ["id": paymentId, "orderId": "01a13056d9c875bfb148fb1ec2cad016"] }
        return ["type": "payment-failure", "detail": detail]
    }

    private func meldError(_ message: [String: Any]) -> MeldError? {
        guard case .error(let error)? = BanxaWebCheckoutPresenter.interpret(providerMessage: message, orderId: "order-1").first
        else { return nil }
        return error
    }

    func testADeclinedPaymentIsRejectedSoTheIntegratorCanSayItWasDeclined() throws {
        let error = try XCTUnwrap(meldError(primerFailure(origin: "payment", diagnosticsId: "diag-1")))
        XCTAssertEqual(error.code, MeldErrorCode.paymentRejected)
        XCTAssertFalse(error.attemptMayExist)
        XCTAssertFalse(error.recoverable)
        XCTAssertEqual(error.orderId, "order-1")
        XCTAssertEqual(error.message, MeldErrorMessage.paymentRejected)
    }

    func testAFailureDetailKeepsPrimersCodeOriginPaymentIdAndDiagnosticsId() throws {
        let error = try XCTUnwrap(meldError(primerFailure(origin: "payment", diagnosticsId: "diag-1")))
        XCTAssertEqual(error.detail,
                       "banxa_card_failed:PAYMENT_FAILED origin=payment primerPaymentId=KiLILEZlP diagnosticsId=diag-1")
    }

    func testAFailureNotRaisedByThePaymentMayStillHaveAnAttempt() throws {
        // Primer raises origin `primer` for a PENDING payment it cannot drive and `network` for a
        // request that failed in flight: a payment may exist, so the order must be tracked, not retried.
        for origin in ["primer", "network", nil] as [String?] {
            let error = try XCTUnwrap(meldError(primerFailure(origin: origin)))
            XCTAssertEqual(error.code, MeldErrorCode.paymentOutcomeUnknown, "origin \(origin ?? "nil")")
            XCTAssertTrue(error.attemptMayExist)
            XCTAssertEqual(error.message, MeldErrorMessage.paymentOutcomeUnknown)
        }
    }

    func testAFailureWithoutAnErrorObjectIsTreatedAsUnknown() throws {
        let error = try XCTUnwrap(meldError(["type": "payment-failure", "detail": [:] as [String: Any]]))
        XCTAssertEqual(error.code, MeldErrorCode.paymentOutcomeUnknown)
        XCTAssertEqual(error.detail, "banxa_card_failed:unknown")
    }

    func testACheckoutSdkThatDidNotLoadIsAProviderLoadFailure() throws {
        let error = try XCTUnwrap(meldError(["type": "error",
                                             "detail": ["error": ["code": "sdk_unavailable", "message": "boom"]]]))
        XCTAssertEqual(error.code, MeldErrorCode.providerLoadFailed)
        XCTAssertTrue(error.attemptMayExist)
        XCTAssertFalse(error.recoverable)
        XCTAssertEqual(error.detail, "banxa_card_failed:sdk_unavailable")
        XCTAssertEqual(error.message, "boom")
    }

    func testACheckoutThatNeverMountedIsAPresentationFailure() throws {
        for code in ["checkout_init_failed", "mount_failed"] {
            let error = try XCTUnwrap(meldError(["type": "error",
                                                 "detail": ["error": ["code": code, "message": "boom"]]]))
            XCTAssertEqual(error.code, MeldErrorCode.presentationFailed)
            XCTAssertFalse(error.attemptMayExist)
            XCTAssertEqual(error.detail, "banxa_card_failed:\(code)")
            XCTAssertEqual(error.message, "boom")
        }
    }

    // MARK: - Vendored bundle

    func testVendoredBundleMatchesItsPinnedHash() throws {
        // Fails closed if the vendored checkout bundle is swapped or revved without re-review.
        XCTAssertNoThrow(try BanxaWebCheckoutPresenter.loadBundle())
        let js = try BanxaWebCheckoutPresenter.loadBundle()
        XCTAssertTrue(js.contains("MeldBanxaCheckout"), "bundle must expose the global the bootstrap uses")
    }

    /// Primer ships no theme of its own: its components' CSS is all `var(--primer-*)`, so without
    /// these tokens the card form renders as unstyled labels and inputs. Guards both that the
    /// vendored theme still loads under its pin and that the bootstrap actually inlines it — a
    /// mount with an unthemed page succeeds and looks broken, which no other assertion would catch.
    func testThemeLoadsUnderItsPinAndIsInlinedIntoTheBootstrap() throws {
        let css = try BanxaWebCheckoutPresenter.loadTheme()
        XCTAssertTrue(css.contains("--primer-space-medium"), "theme must define the spacing tokens the form's CSS reads")
        XCTAssertTrue(css.contains("primer-checkout"), "selector must reach inside the component's shadow root, where :root does not match")

        let html = BanxaWebCheckoutPresenter.bootstrapHtml(bundleJs: "/*bundle*/", themeCss: css, clientToken: "tok")
        XCTAssertTrue(html.contains("--primer-space-medium"), "bootstrap must inline the theme, not just load it")
    }

    /// The bootstrap page must not claim Primer's origin.
    ///
    /// The vendored bundle mounts Primer's hosted card inputs and its api-controller from
    /// `sdk.primer.io`, and the bridge is injected `forMainFrameOnly: false`. If the page claimed that
    /// origin too, page-context script could read `iframe.contentDocument` — PAN and CVV — and the
    /// api-controller's token, which is exactly the isolation those hosted fields exist to provide.
    /// An earlier revision did claim it, to keep the page "same-origin with the SDK it loads".
    ///
    /// Primer's hosts stay in `allowedOrigins`: its subframes still have to reach the bridge. It is
    /// the PAGE origin that must differ.
    func testBootstrapOriginIsNotPrimers() {
        let origin = BanxaWebCheckoutPresenter.pageOrigin()

        XCTAssertNotEqual(origin.host, "sdk.primer.io")
        XCTAssertFalse(BanxaWebCheckoutPresenter.allowedOrigins.contains(origin.absoluteString),
                       "the page origin is trusted as the main frame; it does not belong in the subframe allowlist")
        // https, because Primer and Apple Pay both require a secure context.
        XCTAssertEqual(origin.scheme, "https")
        // Primer's own hosts remain allowlisted, or its subframes cannot post to the bridge.
        XCTAssertTrue(BanxaWebCheckoutPresenter.allowedOrigins.contains("https://sdk.primer.io"))
    }

    /// The same hazard the bundle's `</script` escape guards against, one tag over: a `</style`
    /// sequence would close the block early and spill the remainder into the document as markup.
    func testBootstrapEscapesAThemeThatWouldCloseItsOwnStyleBlock() {
        let html = BanxaWebCheckoutPresenter.bootstrapHtml(
            bundleJs: "/*bundle*/", themeCss: "a{}</style><b>", clientToken: "tok")

        XCTAssertTrue(html.contains("a{}"), "the theme itself must still be inlined")
        XCTAssertFalse(html.contains("</style><b>"), "an unescaped close would end the style block")
        XCTAssertTrue(html.contains("<\\/style><b>"))
    }

    /// Two separate hazards inside one interpolated token, and JSON encoding only covers the first.
    /// A quote would end the string literal; a `</script` would end the *tag*, which the HTML parser
    /// acts on before JavaScript ever sees the string — and JSON has no reason to escape `/`, so
    /// `JSONSerialization` leaves that sequence intact. Asserting on the whole token together would
    /// pass on the quote escape alone, which is how the gap survived: the bare `</script` must be
    /// absent by itself.
    func testBootstrapPassesTokenAsPropertyAndEscapesIt() {
        let html = BanxaWebCheckoutPresenter.bootstrapHtml(bundleJs: "/*bundle*/", themeCss: "/*theme*/", clientToken: "tok\"</script><b>x")
        XCTAssertTrue(html.contains("el.clientToken ="))
        XCTAssertFalse(html.contains("tok\"</script>"))
        // The tag-closing sequence is gone on its own, not merely as part of a longer literal.
        XCTAssertFalse(html.contains("</script><b>x"), "an unescaped close would end the bootstrap script")
        XCTAssertTrue(html.contains("<\\/script><b>x"))
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

    func testNativePresenterRejectsAnOrderWithNoToken() {
        XCTAssertThrowsError(
            try BanxaCardAdapter().mount(
                order: order(extra: [:]), context: MeldMountContext(host: nil, applePay: nil), handlers: .init())
        ) { error in
            guard case MeldMountError.unsupported(let detail) = error else {
                return XCTFail("expected .unsupported, got \(error)")
            }
            XCTAssertTrue(detail.contains("sdkSessionToken"))
        }
    }

    func testWebPresenterRejectsAnOrderWithNoToken() {
        // Validation belongs to the presenter now, not the adapter: the web component needs an
        // sdkSessionToken and Banxa's own SDK needs order parameters instead, so only the presenter
        // knows what "missing" means. Mounting without a token must fail rather than render a surface
        // Primer can never start a session for.
        XCTAssertThrowsError(
            try BanxaCardAdapter(presenter: BanxaWebCheckoutPresenter()).mount(
                order: order(extra: [:]), context: MeldMountContext(host: UIView(), applePay: nil),
                handlers: .init())
        ) { error in
            guard case MeldMountError.unsupported = error else {
                return XCTFail("expected .unsupported, got \(error)")
            }
        }
    }

    func testDefaultPresenterIsPrimersNativeCardForm() {
        XCTAssertTrue(BanxaCardAdapter().presenter is BanxaNativeCheckoutPresenter)
        XCTAssertEqual(BanxaCardAdapter().capabilities.surface, "native-sdk")
        XCTAssertFalse(BanxaCardAdapter().capabilities.embeddable)
        XCTAssertTrue(BanxaCardAdapter().capabilities.requiresUserGesture)
    }

    // MARK: - Native card outcome

    private func failed(_ status: String = "FAILED") -> PrimerError {
        PrimerError.paymentFailed(paymentMethodType: "PAYMENT_CARD", paymentId: "y3DQpU656", orderId: nil, status: status)
    }

    func testAPaymentFailedAtCreateIsRejected() {
        XCTAssertEqual(BanxaPrimerCardSession.code(for: failed(), checkoutData: nil, presented: true),
                       MeldErrorCode.paymentRejected)
    }

    func testAPaymentFailedOnResumeAfter3DSIsRejected() {
        // Primer rewraps the resume's paymentFailed as failed-to-resume-payment, keeping only its
        // description: the shape a real-card decline after 3DS took on Banxa's RN SDK (y3DQpU656).
        let resumed = PrimerError.failedToResumePayment(paymentMethodType: "PAYMENT_CARD",
                                                        description: failed().localizedDescription)
        XCTAssertEqual(BanxaPrimerCardSession.errorId(resumed), "failed-to-resume-payment")
        XCTAssertEqual(BanxaPrimerCardSession.code(for: resumed, checkoutData: nil, presented: true),
                       MeldErrorCode.paymentRejected)
        XCTAssertTrue(BanxaPrimerCardSession.detail(for: resumed, checkoutData: nil)
            .hasPrefix("banxa_card_failed:failed-to-resume-payment primerPaymentId=y3DQpU656 diagnosticsId="))
    }

    func testAResumeThatFailedInFlightMayStillHaveAPayment() {
        let resumed = PrimerError.failedToResumePayment(paymentMethodType: "PAYMENT_CARD",
                                                        description: "The request timed out.")
        let code = BanxaPrimerCardSession.code(for: resumed, checkoutData: nil, presented: true)
        XCTAssertEqual(code, MeldErrorCode.paymentOutcomeUnknown)
        XCTAssertTrue(MeldErrorCode.attemptMayExist(code))
    }

    func testAPendingPaymentIsNotReportedAsDeclined() {
        XCTAssertEqual(BanxaPrimerCardSession.code(for: failed("PENDING"), checkoutData: nil, presented: true),
                       MeldErrorCode.paymentOutcomeUnknown)
    }

    func testAFailureBeforeTheFormAppearedIsAPresentationFailure() {
        XCTAssertEqual(BanxaPrimerCardSession.code(for: failed(), checkoutData: nil, presented: false),
                       MeldErrorCode.presentationFailed)
    }

    func testPrimersOwnResultScreensAreOffSoTheIntegratorOwnsTheOutcome() {
        let settings = BanxaPrimerCardSession.settings()
        XCTAssertFalse(settings.uiOptions.isSuccessScreenEnabled)
        XCTAssertFalse(settings.uiOptions.isErrorScreenEnabled)
        XCTAssertTrue(settings.uiOptions.isInitScreenEnabled)
    }

    func testCapabilitiesFollowThePresenterRatherThanBeingFixedOnTheAdapter() {
        // A native Primer sheet is not embeddable. An integrator guards on `embeddable`, so this has
        // to be the presenter's answer and not a constant that outlives the web component.
        let adapter = BanxaCardAdapter(presenter: RecordingPresenter())
        XCTAssertFalse(adapter.capabilities.embeddable)
        XCTAssertEqual(adapter.capabilities.surface, "recording")
    }
}
