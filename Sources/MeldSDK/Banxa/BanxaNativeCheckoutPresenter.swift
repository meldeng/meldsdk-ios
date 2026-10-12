import PrimerSDK
import UIKit
import os

/// Presents a Banxa card order with Primer's native card form, from the order's client token.
///
/// The same token the web presenter hands `<banxa-primer-checkout>`, presented the way Banxa's own
/// mobile SDKs present it: Banxa's React Native SDK pays a card order with
/// `Primer.configure({ paymentHandling: 'AUTO' })` and Primer's drop-in, and its cards guide covers
/// only that native path. That buys native 3DS (`Primer3DS`) instead of a browser challenge inside a
/// WebView, and drops the vendored JS bundle. The order is still created server-side; nothing about
/// it changes.
///
/// Card only: `showPaymentMethod("PAYMENT_CARD")`, not `showUniversalCheckout`. Banxa's client session
/// also lists Apple Pay and Google Pay, and Apple Pay has its own adapter and merchant identifier.
///
/// Not embeddable: Primer's drop-in presents its own modal.
struct BanxaNativeCheckoutPresenter: BanxaCheckoutPresenter {

    let capabilities = MeldCapabilities(embeddable: false, surface: "native-sdk", requiresUserGesture: true)

    func present(
        order: MeldOrder,
        context: MeldMountContext,
        handlers: MeldEventHandlers
    ) throws -> MeldProviderSession {
        guard let clientToken = order.paymentMethodResponseDetails?["sdkSessionToken"] as? String,
              !clientToken.isEmpty
        else {
            throw MeldMountError.unsupported(
                "Banxa card order is missing sdkSessionToken, the Primer client token the card form is presented "
                    + "from. The backend did not receive one from Banxa for this order.")
        }
        let session = BanxaPrimerCardSession(orderId: order.id, handlers: handlers)
        // Presenting is main-thread work and mount() is nonisolated: hop, as the Apple Pay adapter does.
        DispatchQueue.main.async {
            session.present(clientToken: clientToken)
        }
        return session
    }
}

/// Drives Primer's drop-in card form for one payment and relays its callbacks as Meld events.
///
/// Primer's drop-in singleton holds its delegate weakly, so this keeps a strong self-reference until
/// a terminal callback arrives, exactly as `BanxaPrimerApplePaySession` does.
final class BanxaPrimerCardSession: NSObject, MeldProviderSession {
    private let orderId: String?
    private let handlers: MeldEventHandlers
    private let deadline: PresentationDeadline
    private var selfReference: BanxaPrimerCardSession?
    private var finished = false
    private var presented = false

    private static let logger = Logger(subsystem: "io.meld.sdk", category: "BanxaCard")

    /// The deadline covers Primer fetching its configuration and presenting the form, which is a
    /// network round-trip before anything appears; Apple Pay's sheet needs no such fetch.
    init(orderId: String?, handlers: MeldEventHandlers, deadline: PresentationDeadline = PresentationDeadline(interval: 20)) {
        self.orderId = orderId
        self.handlers = handlers
        self.deadline = deadline
        super.init()
    }

    @MainActor
    func present(clientToken: String) {
        // mount() hops to the main queue to get here, and the host can unmount in the gap.
        guard !finished else { return }
        selfReference = self
        Primer.shared.configure(settings: Self.settings(), delegate: self)
        deadline.arm { [weak self] in self?.presentationExpired() }
        Primer.shared.showPaymentMethod("PAYMENT_CARD", intent: .checkout, clientToken: clientToken) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard !self.finished else { return self.releaseRetain() }
                if let error { return self.fail(error) }
                self.formShown()
            }
        }
    }

    /// Primer's own success and error screens are off: the integrator owns the outcome copy (from
    /// `PAYMENT_REJECTED` and `MeldErrorMessage`), and a second message from Primer would
    /// contradict or duplicate it. The loading screen stays, since the form needs a configuration fetch.
    static func settings() -> PrimerSettings {
        PrimerSettings(
            paymentHandling: .auto,
            uiOptions: PrimerUIOptions(isSuccessScreenEnabled: false, isErrorScreenEnabled: false),
            debugOptions: debugOptions())
    }

    /// Primer3DS refuses to start on a simulator while its sanity check is on, which would push every
    /// simulator payment down the "continue without 3DS" path and make it unrepresentative. The check
    /// stays on for every device build; a simulator build never ships.
    private static func debugOptions() -> PrimerDebugOptions {
        #if targetEnvironment(simulator)
        return PrimerDebugOptions(is3DSSanityCheckEnabled: false)
        #else
        return PrimerDebugOptions()
        #endif
    }

    private func formShown() {
        presented = true
        deadline.disarm()
        handlers.onReady?(orderId)
    }

    /// The host tore the surface down: dismiss Primer's form and stop relaying. The self-reference
    /// survives until Primer's own terminal callback, for the reason given on the Apple Pay session.
    func unmount() {
        guard !finished else { return }
        finished = true
        deadline.disarm()
        DispatchQueue.main.async { Primer.shared.dismiss() }
    }

    fileprivate func fail(_ error: Error, checkoutData: PrimerCheckoutData? = nil) {
        guard !finished else { return releaseRetain() }
        let code = Self.code(for: error, checkoutData: checkoutData, presented: presented)
        handlers.onError?(MeldError(
            orderId: orderId,
            code: code,
            message: MeldErrorMessage.standard(for: code) ?? error.localizedDescription,
            detail: Self.detail(for: error, checkoutData: checkoutData),
            // A new order is needed: the client token is bound to one checkout session.
            recoverable: false))
        Primer.shared.dismiss()
        release()
    }

    static func code(for error: Error, checkoutData: PrimerCheckoutData?, presented: Bool) -> String {
        if !presented { return MeldErrorCode.presentationFailed }
        return paymentFailed(error, checkoutData: checkoutData)
            ? MeldErrorCode.paymentRejected : MeldErrorCode.paymentOutcomeUnknown
    }

    /// Whether Primer reported the payment itself as FAILED, i.e. declined.
    ///
    /// A card payment fails on resume more often than on create, because the resume follows 3DS. Primer
    /// throws `paymentFailed(status: "FAILED")` there and then rewraps it as `failed-to-resume-payment`,
    /// keeping only the inner error's description (`CreateResumePaymentService.resumePaymentWithPaymentId`).
    /// The wrapper alone is not enough: a resume that failed in flight carries the same id with a network
    /// description, and a payment may exist behind it.
    static func paymentFailed(_ error: Error, checkoutData: PrimerCheckoutData?) -> Bool {
        if checkoutData?.payment?.status == "FAILED" { return true }
        switch errorId(error) {
        case "payment-failed":
            if case let .paymentFailed(_, _, _, status, _) = error as? PrimerError { return status == "FAILED" }
            return false
        case "failed-to-resume-payment", "failed-to-create-payment":
            let description = error.localizedDescription
            return description.contains("[payment-failed]") && description.contains("FAILED status")
        default:
            return false
        }
    }

    static func detail(for error: Error, checkoutData: PrimerCheckoutData?) -> String {
        let raw = error as NSError
        return [
            "banxa_card_failed:\(errorId(error) ?? "\(raw.domain) #\(raw.code)")",
            (checkoutData?.payment?.id ?? paymentId(in: error.localizedDescription)).map { "primerPaymentId=\($0)" },
            ((error as? PrimerErrorProtocol)?.diagnosticsId).map { "diagnosticsId=\($0)" },
        ].compactMap { $0 }.joined(separator: " ")
    }

    /// Primer names the payment only inside the description it rewraps: "The payment with id X was…".
    private static func paymentId(in description: String) -> String? {
        guard let range = description.range(of: "payment with id ") else { return nil }
        let id = description[range.upperBound...].prefix { !$0.isWhitespace }
        return id.isEmpty ? nil : String(id)
    }

    static func errorId(_ error: Error) -> String? {
        (error as? PrimerErrorProtocol)?.errorId ?? (error as NSError).userInfo["errorId"] as? String
    }

    private func presentationExpired() {
        guard !finished else { return }
        handlers.onError?(MeldError(orderId: orderId, code: MeldErrorCode.presentationFailed,
                                    message: "The card form did not appear.", detail: "presentation_deadline",
                                    recoverable: false))
        Primer.shared.dismiss()
        release()
    }

    private func release() {
        finished = true
        deadline.disarm()
        selfReference = nil
        handlers.sessionEnded?(orderId)
    }

    private func releaseRetain() {
        selfReference = nil
    }
}

extension BanxaPrimerCardSession: PrimerDelegate {
    /// Primer created the payment. Reported as `paymentSubmitted`, never as settlement: the money is
    /// confirmed server-side from Banxa's webhook.
    func primerDidCompleteCheckoutWithData(_ data: PrimerCheckoutData) {
        guard !finished else { return releaseRetain() }
        Self.logger.info("Banxa card checkout completed")
        handlers.onPaymentSubmitted?(orderId)
        Primer.shared.dismiss()
        release()
    }

    /// Primer waits for the decision before it moves on; with its error screen off the message is unused.
    func primerDidFailWithError(_ error: Error, data: PrimerCheckoutData?, decisionHandler: @escaping ((PrimerErrorDecision) -> Void)) {
        decisionHandler(.fail(withErrorMessage: nil))
        guard Self.errorId(error) != "payment-cancelled" else { return cancel() }
        fail(error, checkoutData: data)
    }

    /// The customer closed the form. In drop-in mode Primer reports a cancellation here rather than
    /// through `primerDidFailWithError`, and after a terminal callback this is just the sheet leaving.
    func primerDidDismiss() {
        cancel()
    }

    private func cancel() {
        guard !finished else { return releaseRetain() }
        handlers.onCancel?(orderId)
        release()
    }
}
