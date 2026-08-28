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

    /// nil when Apple Pay is usable; otherwise an integrator-facing reason it is not.
    ///
    /// `networks` is the card set the payment will actually be built against. Pass it only where we
    /// build the `PKPaymentRequest` ourselves and therefore know it. For a provider-hosted surface
    /// pass nothing: their merchant configuration decides which cards are accepted, and asserting
    /// our own list would refuse a user whose Wallet holds a card that provider does take.
    static func unavailableReason(requiring networks: [PKPaymentNetwork]? = nil) -> String? {
        guard PKPaymentAuthorizationController.canMakePayments() else {
            return "Apple Pay is not supported on this device."
        }
        guard let networks, !networks.isEmpty else { return nil }
        guard PKPaymentAuthorizationController.canMakePayments(usingNetworks: networks) else {
            return "Apple Pay has no usable card in Wallet on this device."
        }
        return nil
    }
}
