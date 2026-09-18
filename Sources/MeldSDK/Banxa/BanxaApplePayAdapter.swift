import PassKit
import PrimerSDK
import UIKit
import os

/// Banxa Apple Pay, presented by Primer from the order's client token.
///
/// Banxa's processor is Primer, and the `sessionToken` on a Banxa Apple Pay order is a plain Primer
/// client token — `intent: CHECKOUT`, `configurationUrl` pointing at Primer's client SDK. Primer's
/// own SDK takes that token and does the whole flow: presents the Apple Pay sheet, tokenizes the
/// wallet payload against its PCI endpoint, and creates the payment.
///
/// Why Primer directly rather than Banxa's SDK: Banxa's is `Primer.shared.configure` plus
/// `showPaymentMethod(_:intent:clientToken:)` plus a delegate bridge, and beyond that only a REST
/// client for the catalog/quote/order endpoints Meld's backend already owns. It adds nothing we use,
/// while being distributed as a Swift package only — unbuildable for the CocoaPods consumers the
/// React Native wrapper is built on — and declaring swift-tools 6.3, which would raise the toolchain
/// floor for every MeldSDK integrator. Primer ships on both channels at swift-tools 5.3.
///
/// Why not the encrypted-token shape Mercuryo uses: there is nowhere to post the payload. Banxa's
/// API has no payment-completion endpoint, and Primer's `/payments` refuses a client token (401), so
/// only Primer's SDK can complete this payment.
///
/// Not embeddable: Primer owns a modal surface, and Apple Pay requires a user gesture.
struct BanxaApplePayAdapter: MeldAdapter {
    let label = "Banxa Apple Pay (APPLE_PAY / vendor SDK)"
    let capabilities = MeldCapabilities(embeddable: false, surface: "native-applepay", requiresUserGesture: true)

    private static let logger = Logger(subsystem: "io.meld.sdk", category: "BanxaApplePayAdapter")

    /// Keyed on the provider first, then on the shape only to step aside for a provider-hosted order.
    ///
    /// The provider gate is load-bearing in both directions. `VENDOR_SDK` says "a vendor SDK presents
    /// this", not which one, so a second vendor-SDK provider must not land here by default — that is
    /// what it keeps out. What it keeps *in* is a Banxa order whose presentation this build cannot
    /// read: `MeldOrder.presentation` falls back to fingerprinting when the server omits the field,
    /// and a Banxa Apple Pay order carries `sessionToken`, which fingerprints as `.nativeToken`.
    /// Requiring `.vendorSdk` would then decline it — and declining does not leave it unclaimed, it
    /// hands it to `MercuryoApplePayAdapter`, which treats native as its default and would post
    /// Banxa's Primer token to Mercuryo's processing endpoint. Registry order cannot help, because
    /// order only decides between adapters that both match.
    ///
    /// payment-domain does serve `VENDOR_SDK` for every Banxa Apple Pay order, so this is a guard
    /// against a contract change rather than a bug today. It is worth one clause: the failure it
    /// prevents is a token crossing providers, and the cost of being wrong in the other direction is
    /// a Banxa order failing in Banxa's own adapter, with Banxa's own message.
    let presentations = [MeldAdapterPresentation("APPLE_PAY", "VENDOR_SDK", "BANXA_CHECKOUT")]

    func acceptsDeclaredOrder(_ order: MeldOrder) -> Bool {
        let details = order.paymentMethodResponseDetails
        return order.hasCompatibleLegacyPresentation("VENDOR_SDK")
            && ((details?["sessionToken"] as? String) ?? (details?["sdkSessionToken"] as? String))?.isEmpty == false
    }

    func matches(_ order: MeldOrder) -> Bool {
        order.serviceProvider == "BANXA"
            && order.paymentMethodType == "APPLE_PAY"
            // A provider-hosted link is a different surface with its own adapter, and unambiguous.
            && order.presentation != .providerHosted
    }

    func mount(order: MeldOrder, context: MeldMountContext, handlers: MeldEventHandlers) throws -> MeldProviderSession {
        let details = order.paymentMethodResponseDetails
        guard let clientToken = (details?["sessionToken"] as? String) ?? details?["sdkSessionToken"] as? String,
              !clientToken.isEmpty
        else {
            throw MeldApplePayError.invalidOrder(
                "Banxa Apple Pay order is missing sessionToken, the Primer client token the sheet is presented from.")
        }
        // Apple encrypts the wallet payload for exactly one Payment Processing Certificate, and the
        // one Primer holds for Banxa is bound to this identifier. Without it Primer cannot build a
        // PKPaymentRequest, so fail here with the reason rather than let the sheet fail opaquely.
        guard let merchantIdentifier = nonEmpty(details?["merchantIdentifier"] as? String) else {
            throw MeldApplePayError.invalidOrder(
                "Banxa Apple Pay order is missing merchantIdentifier. It is configured per account "
                    + "under the provider's own key; an account without one cannot present Apple Pay.")
        }

        let session = BanxaPrimerApplePaySession(orderId: order.id, handlers: handlers)
        // Presenting is main-thread work by UIKit's rules and Primer's surface is @MainActor, while
        // mount() is nonisolated. Hop rather than assert isolation: an earlier revision of the sibling
        // adapter used MainActor.assumeIsolated here and trapped the first time it was reached off the
        // main thread.
        DispatchQueue.main.async {
            session.present(clientToken: clientToken, merchantIdentifier: merchantIdentifier)
        }
        return session
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}

/// Drives Primer's headless checkout for the life of one payment and relays its callbacks as Meld
/// events.
///
/// Headless (`PrimerHeadlessUniversalCheckout` + `NativeUIManager`) rather than the drop-in, because
/// the drop-in presents a Primer container view controller and shows the Apple Pay sheet on top of
/// it — so the app behind is replaced by Primer's opaque screen instead of showing through, and a
/// failure leaves that screen stranded. Mercuryo's sheet looks right precisely because nothing is
/// presented but PassKit's own sheet. `NativeUIManager` matches that: it sets integration type
/// `.headless` and turns off Primer's init, success and error screens, presenting only the sheet.
///
/// Primer's headless singleton has a single delegate slot, so this keeps a strong self-reference
/// until a terminal callback arrives — otherwise the session deallocates the moment `mount` returns
/// and the payment reports nothing.
final class BanxaPrimerApplePaySession: NSObject, MeldProviderSession {
    private let orderId: String?
    private let handlers: MeldEventHandlers
    private var selfReference: BanxaPrimerApplePaySession?
    private var finished = false
    private var manager: PrimerHeadlessUniversalCheckout.NativeUIManager?

    private static let logger = Logger(subsystem: "io.meld.sdk", category: "BanxaApplePay")

    init(orderId: String?, handlers: MeldEventHandlers) {
        self.orderId = orderId
        self.handlers = handlers
        super.init()
    }

    @MainActor
    func present(clientToken: String, merchantIdentifier: String) {
        // mount() hops to the main queue to get here, and the host can unmount in the gap. Without
        // this the sheet appears after the surface it belongs to has already been torn down.
        guard !finished else { return }
        selfReference = self
        let settings = PrimerSettings(
            paymentMethodOptions: PrimerPaymentMethodOptions(
                // merchantName is nil deliberately: Primer deprecated it in favour of the name on the
                // client session, which Banxa owns when it mints the token.
                applePayOptions: PrimerApplePayOptions(merchantIdentifier: merchantIdentifier, merchantName: nil)))

        PrimerHeadlessUniversalCheckout.current.start(
            withClientToken: clientToken,
            settings: settings,
            delegate: self,
            // Also the UI delegate: dismissal is reported there, not on the checkout delegate, and
            // without it a user who closes the sheet is never reported as having cancelled.
            uiDelegate: self
        ) { [weak self] _, error in
            guard let self else { return }
            // Re-checked here, not only before the call: `start(withClientToken:)` is a network
            // round-trip, and a host that calls unmount() during it has already had cleanUp() run and
            // the session reset. Without this the completion goes on to build the NativeUIManager and
            // call showPaymentMethod, putting an Apple Pay sheet over whatever the host navigated to,
            // and fires onReady after teardown. Worse, if the customer then authorises, didComplete
            // is swallowed by its own guard — a real payment that no callback ever reports.
            guard !self.finished else { return self.releaseRetain() }
            if let error {
                self.fail(error)
                return
            }
            do {
                // "APPLE_PAY" is Primer's own type string, the value Banxa's SDK maps to as well.
                let manager = try PrimerHeadlessUniversalCheckout.NativeUIManager(paymentMethodType: "APPLE_PAY")
                self.manager = manager
                try manager.showPaymentMethod(intent: .checkout)
                self.handlers.onReady?(self.orderId)
            } catch {
                self.fail(error)
            }
        }
    }

    /// The host tore the surface down: stop relaying, and reset Primer so the next checkout does not
    /// inherit this session.
    ///
    /// The self-reference deliberately survives. Primer holds its delegate weakly, so this retain is
    /// the only thing keeping the delegate alive — dropping it while the sheet is still up would
    /// deallocate the delegate mid-payment, and a payment that then succeeded would be reported to
    /// nobody. It is released instead when Primer's terminal callback arrives.
    func unmount() {
        guard !finished else { return }
        finished = true
        manager = nil
        // Thread-safe: Primer serialises this behind its own barrier queue.
        PrimerHeadlessUniversalCheckout.current.cleanUp()
    }

    fileprivate func fail(_ error: Error) {
        guard !finished else { return releaseRetain() }
        handlers.onError?(
            MeldError(
                orderId: orderId,
                code: "banxa_apple_pay_failed",
                message: error.localizedDescription,
                detail: nil,
                // A new order is needed: the client token is bound to one checkout session.
                recoverable: false))
        release()
    }

    private func release() {
        finished = true
        manager = nil
        selfReference = nil
    }

    /// A terminal callback that arrived after `unmount`: nothing left to report, but the retain
    /// `unmount` kept has done its job and must not become a leak.
    private func releaseRetain() {
        selfReference = nil
    }
}

extension BanxaPrimerApplePaySession: PrimerHeadlessUniversalCheckoutDelegate {
    /// Primer created the payment. Reported as `paymentSubmitted`, never as settlement: the money is
    /// confirmed server-side from Banxa's webhook, exactly as for every other provider here.
    func primerHeadlessUniversalCheckoutDidCompleteCheckoutWithData(_ data: PrimerCheckoutData) {
        guard !finished else { return releaseRetain() }
        Self.logger.info("Banxa Apple Pay checkout completed")
        handlers.onPaymentSubmitted?(orderId)
        release()
    }

    /// A dismissed sheet arrives here first, as a failure, and must not be reported as one.
    ///
    /// In headless mode Primer raises `PrimerError.cancelled` through `didFail` *before* it dismisses:
    /// `PaymentMethodTokenizationViewModel+Logic.start()` short-circuits a cancellation only for
    /// `sdkIntegrationType == .dropIn`, so headless goes to `raisePrimerDidFailWithError` first and
    /// reaches `UIDidDismissPaymentMethod` afterwards. By then `fail(_:)` has already emitted
    /// `onError` and set `finished`, so the dismiss handler's own guard swallows the cancel and the
    /// host is told the payment failed and needs a new order — for a customer who simply changed their
    /// mind. Recognising it here is the only place the distinction still exists.
    func primerHeadlessUniversalCheckoutDidFail(withError err: Error, checkoutData: PrimerCheckoutData?) {
        if isCancellation(err) {
            guard !finished else { return releaseRetain() }
            Self.logger.info("Banxa Apple Pay sheet dismissed by the user")
            handlers.onCancel?(orderId)
            return release()
        }
        fail(err)
    }

    /// Matched on `errorId` rather than by casting to `PrimerError`, so a Primer version that rewraps
    /// or nests the error still reports a cancel as a cancel. The cost of being wrong in this
    /// direction is a genuine failure reported as a cancel; the cost in the other is every cancelled
    /// checkout telling the host to start a new order.
    private func isCancellation(_ error: Error) -> Bool {
        if let primerError = error as? PrimerErrorProtocol {
            return primerError.errorId == "payment-cancelled"
        }
        return (error as NSError).userInfo["errorId"] as? String == "payment-cancelled"
    }
}

extension BanxaPrimerApplePaySession: PrimerHeadlessUniversalCheckoutUIDelegate {
    /// The user dismissed the sheet. Cancel, not error — nothing failed.
    func primerHeadlessUniversalCheckoutUIDidDismissPaymentMethod() {
        guard !finished else { return releaseRetain() }
        handlers.onCancel?(orderId)
        release()
    }
}
