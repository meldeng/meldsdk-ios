import Foundation
import PassKit

/// Mercuryo native Apple Pay, presented as a PassKit sheet rather than an embedded widget. It's a
/// first-class adapter in the registry, so the same `Meld.mount` dispatches to it — the caller just
/// passes `applePay:` instead of `into:`. The order supplies `merchantIdentifier`, `sessionToken`,
/// and `merchantTransactionId`; the `MeldApplePayRequest` in the context supplies what the sheet and
/// the provider's `/process` endpoint need that the order doesn't carry.
struct MercuryoApplePayAdapter: MeldAdapter {
    let label = "Mercuryo Apple Pay (APPLE_PAY / native sheet)"
    // Not embeddable — it's a modal native sheet, not mounted into a view. Requires a user gesture.
    let capabilities = MeldCapabilities(embeddable: false, surface: "native-applepay", requiresUserGesture: true)

    // Apple Pay orders carry no renderMode; the payment method type alone selects this adapter.
    func matches(paymentMethodType: String?, renderMode: String?) -> Bool {
        paymentMethodType == "APPLE_PAY"
    }

    func mount(order: MeldOrder, context: MeldMountContext, handlers: MeldEventHandlers) throws -> MeldProviderSession {
        guard let request = context.applePay else {
            throw MeldApplePayError.invalidOrder(
                "Apple Pay orders need a MeldApplePayRequest — call mount(_:applePay:handlers:).")
        }
        let details = order.paymentMethodResponseDetails
        guard let sessionToken = details?["sessionToken"] as? String, !sessionToken.isEmpty else {
            throw MeldApplePayError.invalidOrder("Apple Pay order is missing sessionToken.")
        }
        guard let merchantTransactionId = details?["merchantTransactionId"] as? String,
              !merchantTransactionId.isEmpty else {
            throw MeldApplePayError.invalidOrder("Apple Pay order is missing merchantTransactionId.")
        }
        guard let merchantIdentifier = details?["merchantIdentifier"] as? String, !merchantIdentifier.isEmpty else {
            throw MeldApplePayError.invalidOrder(
                "Apple Pay order is missing merchantIdentifier — the account may not be configured for Apple Pay.")
        }
        guard Meld.canPresentApplePay() else { throw MeldApplePayError.unavailable }

        let client = MercuryoApplePayClient(environment: Meld.environment, sessionToken: sessionToken)
        let coordinator = ApplePayCoordinator(
            orderId: order.id,
            merchantIdentifier: merchantIdentifier,
            merchantTransactionId: merchantTransactionId,
            request: request,
            handlers: handlers,
            client: client)
        coordinator.present()
        return coordinator
    }
}
