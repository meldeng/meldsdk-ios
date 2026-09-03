import BanxaPaymentSDK
import Foundation
import UIKit
import os

/// Bridges Banxa's SDK delegate to Meld events for the duration of one checkout.
///
/// Holds itself alive while the sheet is up: `BanxaPaymentSDK.shared.delegate` is `weak` and the SDK
/// is a singleton, so a session the caller stops referencing would be deallocated mid-flow and every
/// callback silently dropped. The self-reference is released on the first terminal callback, and by
/// `unmount()`.
@MainActor
final class BanxaNativeSession: NSObject, MeldProviderSession, BanxaPaymentSDKDelegate {

    private let orderId: String?
    private let handlers: MeldEventHandlers
    /// Set once the configuration fetch lands, before the sheet is started.
    var link: ProviderOrderLink?
    /// The controller Banxa's SDK presents from; `unmount()` dismisses what it presented.
    weak var presentingController: UIViewController?
    private(set) var isFinished = false
    private var selfReference: BanxaNativeSession?

    /// Where to report the Banxa order id, and the bearer that authorises it. Both come from the order.
    struct ProviderOrderLink {
        let url: URL
        let token: String
    }
    private static let logger = Logger(subsystem: "io.meld.sdk", category: "BanxaNativeSession")

    init(orderId: String?, handlers: MeldEventHandlers) {
        self.orderId = orderId
        self.handlers = handlers
    }

    /// The flow never reached Banxa's SDK — configuration could not be fetched. Reported as an error
    /// rather than a cancel, because nothing was presented and nobody chose to stop.
    func failBeforeStart(_ error: Error) {
        let fetch = error as? BanxaSdkConfigFetchError
        let refusal = error as? BanxaMountRefusal
        handlers.onError?(
            MeldError(
                orderId: orderId,
                // The server's code when it sent one (e.g. CUSTOMER_NOT_PAYMENT_READY), so the
                // integrator branches on the same vocabulary as the REST API.
                code: refusal?.code ?? fetch?.code ?? "banxa_sdk_config_unavailable",
                message: refusal?.message ?? fetch?.message ?? error.localizedDescription,
                detail: fetch.map { "HTTP \($0.status)" },
                // No Banxa order exists yet, so retrying the same Meld order is safe for transport and
                // server failures — but not for a 4xx or a configuration refusal, which are decisions
                // about this order.
                recoverable: refusal == nil && (fetch?.isRecoverable ?? true)))
        finish()
    }

    func retainUntilFinished() {
        selfReference = self
    }

    private func finish() {
        isFinished = true
        // Clear the singleton's pointer at us too, so a later stray callback cannot reach a session
        // whose flow is over.
        if BanxaPaymentSDK.shared.delegate === self {
            BanxaPaymentSDK.shared.delegate = nil
        }
        selfReference = nil
    }

    // MARK: - MeldProviderSession

    func unmount() {
        // Banxa's SDK exposes no dismiss of its own, but it presents from the controller we handed
        // it, so tearing down means dismissing that controller's presented sheet. Without this the
        // handle contract ("unmount tears down the surface") was silently false: the sheet stayed up
        // with its callbacks detached, and a user could complete a payment nothing was listening to.
        presentingController?.presentedViewController?.dismiss(animated: true)
        // Deliberately silent: as everywhere else in this SDK, unmount() does not emit onCancel.
        finish()
    }

    // MARK: - BanxaPaymentSDKDelegate

    func banxaDidCompleteCheckout(_ result: BanxaCheckoutResult) {
        // A UX signal, not settlement — Banxa's own docs say the same. Settlement truth is the Meld
        // webhook to the integrator's backend.
        //
        // `orderId` is the Banxa order id for the native path and nil for the hosted-checkout
        // fallback, which reports only a query string. It is surfaced as the provider status' raw
        // payload so a host can report it back and shortcut the join; when it is absent the backend
        // still recovers the order from the webhook via externalOrderId.
        Self.logger.debug(
            "banxa checkout complete providerOrderId=\(result.orderId ?? "<none>", privacy: .public)")
        // Join the two orders now rather than waiting on Banxa's webhook. Best-effort by design: the
        // backend recovers the same join from the webhook by externalOrderId, so a failure here delays
        // reconciliation rather than losing it — which is why it does not surface as onError and why
        // the hosted-checkout path, which reports no order id at all, is simply skipped.
        if let providerOrderId = result.orderId, !providerOrderId.isEmpty {
            reportProviderOrder(providerOrderId)
        } else {
            // No Banxa order id means the SDK fell back to Banxa's HOSTED checkout (the token was
            // withheld). Today that is the common path, not the edge case, and it is the product the
            // headless contract refuses to serve — so it must be visible to the host rather than
            // indistinguishable from a native sheet. Reported as a status change; the join then rests
            // on the webhook matching externalOrderId.
            handlers.onStatusChange?(
                MeldStatusChange(
                    orderId: orderId, status: .pending, providerStatus: "HOSTED_CHECKOUT_FALLBACK", raw: nil))
        }
        handlers.onPaymentSubmitted?(orderId)
        handlers.onStatusChange?(
            MeldStatusChange(
                orderId: orderId,
                status: .pending,
                providerStatus: result.status,
                raw: [
                    "providerOrderId": result.orderId as Any,
                    "providerPaymentId": result.paymentId as Any,
                ]))
        finish()
    }

    /// POSTs the Banxa order id to the link endpoint named on the order.
    private func reportProviderOrder(_ providerOrderId: String) {
        guard let link else { return }
        var request = URLRequest(url: link.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Audience-scoped and bound to this order, so it grants nothing else.
        request.setValue("Bearer \(link.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["providerOrderId": providerOrderId])

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                Self.logger.warning(
                    "provider-order link failed (the webhook will still join it): \(error.localizedDescription, privacy: .public)")
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if !(200...299).contains(status) {
                Self.logger.warning(
                    "provider-order link rejected (the webhook will still join it), status \(status, privacy: .public)")
            }
        }.resume()
    }

    func banxaDidFail(error: Error) {
        handlers.onError?(
            MeldError(
                orderId: orderId,
                code: "banxa_sdk_error",
                message: error.localizedDescription,
                detail: nil,
                // The Banxa order may or may not exist by the time this fires, and a retry on the same
                // Meld order would risk a second Banxa order against it. A new order is the safe move.
                recoverable: false))
        finish()
    }

    func banxaDidDismiss() {
        handlers.onCancel?(orderId)
        finish()
    }
}
