import Foundation
import PassKit

/// Whether Apple Pay can actually be used here, and if not, why — phrased for the integrator.
///
/// Apple Pay availability has two distinct gates, and conflating them is the classic bug:
/// `canMakePayments()` is true on any Apple-Pay-capable device **even with an empty Wallet**, while
/// `canMakePayments(usingNetworks:)` additionally requires a provisioned card. Building UX on the
/// former yields a button that does nothing.
///
/// Querying either needs no Apple Pay entitlement and no merchant id — only *presenting* a
/// `PKPaymentRequest` does.
enum MeldApplePayAvailability {

    /// Every card network at least one Apple Pay provider behind this SDK accepts.
    /// `Meld.canPresentApplePay()` has no order to ask about, so it requires a card on one of these.
    /// Stripe's request (`StripeAPI.paymentRequest`) lists all of them and Mercuryo's lists Visa and
    /// Mastercard. Banxa, through Primer, and Coinbase set networks on their own merchant accounts,
    /// and the cards they document are within this set. An adapter that builds a narrower request
    /// checks its own networks before presenting.
    static let supportedNetworks: [PKPaymentNetwork] = [.visa, .masterCard, .amex, .discover, .maestro]

    /// nil when Apple Pay is usable; otherwise an integrator-facing reason it is not.
    ///
    /// `networks` is the card set the payment will actually be built against. Pass it only where we
    /// build the `PKPaymentRequest` ourselves and therefore know it. For a provider-hosted surface
    /// pass nothing: their merchant configuration decides which cards are accepted, and asserting
    /// our own list would refuse a user whose Wallet holds a card that provider does take.
    static func unavailableReason(
        requiring networks: [PKPaymentNetwork]? = nil,
        device: () -> Bool = { PKPaymentAuthorizationController.canMakePayments() },
        wallet: ([PKPaymentNetwork]) -> Bool = { PKPaymentAuthorizationController.canMakePayments(usingNetworks: $0) }
    ) -> String? {
        guard device() else {
            return "Apple Pay is not supported on this device."
        }
        guard let networks, !networks.isEmpty else { return nil }
        guard wallet(networks) else {
            return "Apple Pay has no usable card in Wallet on this device."
        }
        return nil
    }
}
