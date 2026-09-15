import PrimerSDK
import XCTest

@testable import MeldSDK

/// Dispatch and input guards for Banxa Apple Pay. Presenting is not exercised: it hands off to
/// Primer's singleton drop-in, which owns a modal surface and a real Apple Pay sheet.
final class BanxaApplePayAdapterTests: XCTestCase {

    private func order(
        serviceProvider: String? = "BANXA",
        paymentMethodType: String? = "APPLE_PAY",
        presentation: String? = "VENDOR_SDK",
        details: [String: Any] = ["sessionToken": "primer-client-token", "merchantIdentifier": "merchant.io.meld.par.banxa"]
    ) -> MeldOrder {
        var raw = details
        if let presentation { raw["presentation"] = presentation }
        var dict: [String: Any] = ["id": "order-1", "paymentMethodResponseDetails": raw]
        if let paymentMethodType { dict["paymentMethodType"] = paymentMethodType }
        if let serviceProvider { dict["payload"] = ["serviceProvider": serviceProvider] }
        return try! MeldOrder.from(jsonData: try! JSONSerialization.data(withJSONObject: dict))
    }

    // MARK: - Dispatch

    /// The order this SDK could not present before: no Apple Pay adapter took VENDOR_SDK, so
    /// `capabilities` reported unsupported and `mount` threw on a perfectly good order.
    func testTheRegistryNowClaimsABanxaVendorSdkApplePayOrder() {
        let resolved = Meld.adapters.first { $0.matches(order()) }
        XCTAssertTrue(resolved is BanxaApplePayAdapter, "got \(String(describing: resolved?.label))")
        XCTAssertFalse(Meld.capabilities(for: order()).embeddable, "a modal sheet is never embeddable")
        XCTAssertEqual(Meld.capabilities(for: order()).surface, "native-applepay")
    }

    /// VENDOR_SDK says "a vendor SDK presents this", not which one. Without the provider gate a
    /// second vendor-SDK provider would land in Primer.
    func testItDoesNotClaimAnotherProvidersVendorSdkOrder() {
        XCTAssertFalse(BanxaApplePayAdapter().matches(order(serviceProvider: "SOMEONE_ELSE")))
    }

    /// Mercuryo's adapter treats native as the default and accepts an unrecognised presentation, so
    /// registry order — not just the matchers — is what keeps a Banxa order out of it.
    func testMercuryoDoesNotClaimTheBanxaOrder() {
        XCTAssertFalse(MercuryoApplePayAdapter().matches(order()))
    }

    /// Break caught: a Banxa token posted to Mercuryo's endpoint.
    ///
    /// `MeldOrder.presentation` falls back to fingerprinting when the server omits the field, and a
    /// Banxa Apple Pay order carries `sessionToken`, which fingerprints as `.nativeToken`. An adapter
    /// requiring `.vendorSdk` would decline it — and declining does not leave it unclaimed, it hands
    /// it to Mercuryo's adapter, which takes native by default.
    func testItStillClaimsABanxaOrderWhoseShapeCannotBeRead() {
        let unlabelled = order(presentation: nil)
        XCTAssertEqual(unlabelled.presentation, .nativeToken, "precondition: the fingerprint reads native")

        XCTAssertTrue(BanxaApplePayAdapter().matches(unlabelled))
        let resolved = Meld.adapters.first { $0.matches(unlabelled) }
        XCTAssertTrue(resolved is BanxaApplePayAdapter, "got \(String(describing: resolved?.label))")
    }

    /// A provider-hosted link is a different surface with an adapter of its own, so the provider gate
    /// does not swallow it.
    func testItLeavesAProviderHostedOrderToTheHostedAdapter() {
        let hosted = order(
            presentation: "PROVIDER_HOSTED",
            details: ["paymentLinkUrl": "https://banxa.test/pay"])
        XCTAssertFalse(BanxaApplePayAdapter().matches(hosted))
    }

    func testItLeavesBanxaCardOrdersAlone() {
        XCTAssertFalse(BanxaApplePayAdapter().matches(order(paymentMethodType: "CREDIT_DEBIT_CARD")))
    }

    // MARK: - Cancellation

    /**
     Break caught: a dismissed sheet reported as a failed payment.

     In headless mode Primer raises `PrimerError.cancelled` through `didFail` before it dismisses, so
     the error path ran first, set `finished`, and the dismiss handler's own guard then swallowed the
     cancel. The host was told the payment failed and a new order was needed, for a customer who just
     changed their mind.
     */
    func testACancelledSheetIsRecognisedByItsPrimerErrorId() {
        // Matched on errorId, which is the identity Primer keeps stable across wrapping.
        XCTAssertEqual(PrimerError.cancelled(paymentMethodType: "APPLE_PAY").errorId, "payment-cancelled")
    }

    // MARK: - Input guards

    /// The client token is the whole payment: Primer presents the sheet, tokenizes and charges from
    /// it. Missing means a sheet that could never complete, so refuse before showing one.
    func testMountRefusesAnOrderWithNoClientToken() {
        let bare = order(details: ["merchantIdentifier": "merchant.io.meld.par.banxa"])
        XCTAssertThrowsError(
            try BanxaApplePayAdapter().mount(order: bare, context: MeldMountContext(host: nil, applePay: nil), handlers: MeldEventHandlers())
        ) { error in
            XCTAssertTrue("\(error)".contains("sessionToken"), "\(error)")
        }
    }

    /// Apple encrypts the wallet payload for exactly one Payment Processing Certificate. Without the
    /// identifier bound to Primer's, the sheet cannot be built — fail with the reason rather than let
    /// PassKit fail opaquely.
    func testMountRefusesAnOrderWithNoMerchantIdentifier() {
        let bare = order(details: ["sessionToken": "primer-client-token"])
        XCTAssertThrowsError(
            try BanxaApplePayAdapter().mount(order: bare, context: MeldMountContext(host: nil, applePay: nil), handlers: MeldEventHandlers())
        ) { error in
            XCTAssertTrue("\(error)".contains("merchantIdentifier"), "\(error)")
        }
    }
}
