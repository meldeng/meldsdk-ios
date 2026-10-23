import Foundation
import PassKit

/// Whether this device can pay with a method, answered before any order exists. Advisory: a
/// mounted order that cannot pay still reports `MeldErrorCode.paymentMethodUnavailable`.
public enum MeldReadiness: Equatable, Sendable {
    /// Offer the method.
    case ready
    /// Do not offer the method. `code` uses the same terms a mounted order would.
    case unavailable(code: String, reason: String)
    /// The SDK could not tell. You may offer the method; the payment itself has the final word.
    case unknown(reason: String)
}

extension MeldReadiness {
    static func unavailable(_ reason: String) -> MeldReadiness {
        .unavailable(code: MeldErrorCode.paymentMethodUnavailable, reason: reason)
    }

    /// The answer for a method this SDK presents without asking the device anything.
    static let unchecked = MeldReadiness.unknown(
        reason: "This payment method has no device check; offer it and let the payment decide.")

    /// Wallets of other platforms, by the name a reason gives them. No build of this SDK can pay with them.
    static let otherPlatformWallets = ["GOOGLE_PAY": "Google Pay"]
}

/// PassKit's two availability gates, replaceable in tests.
struct WalletProbe {
    var device: () -> Bool = { PKPaymentAuthorizationController.canMakePayments() }
    var wallet: ([PKPaymentNetwork]) -> Bool = { PKPaymentAuthorizationController.canMakePayments(usingNetworks: $0) }
}

/// The Wallet cards a payment through an adapter can use.
enum WalletNetworks {
    /// The adapter builds the sheet's request with these networks.
    case requested([PKPaymentNetwork])
    /// The provider's merchant account sets them, so a card on a network the SDK's providers take is as far
    /// as the SDK can tell.
    case providerSet

    var networks: [PKPaymentNetwork] {
        switch self {
        case let .requested(networks): return networks
        case .providerSet: return MeldApplePayAvailability.supportedNetworks
        }
    }
}

extension MeldAdapter {
    func walletNetworks(paymentMethodType: String) -> WalletNetworks? { nil }
}

extension MeldAdapterRegistry {
    func readiness(for presentation: MeldHeadlessPresentation, paymentMethodType: String,
                   probe: WalletProbe) -> MeldReadiness {
        readiness(MeldAdapterPresentation(paymentMethodType, presentation.surface, presentation.protocolName,
                                          version: presentation.version), probe: probe)
    }

    /// The answer for `paymentMethodType` before any quote: PassKit is asked once about every network that a
    /// presentation of it this device can show takes.
    func readiness(of paymentMethodType: String, probe: WalletProbe) -> MeldReadiness {
        let wallets = presentations.filter { $0.method == paymentMethodType }.compactMap { presentation in
            adapter(for: presentation).flatMap { adapter in
                adapter.walletNetworks(paymentMethodType: paymentMethodType).map { (adapter, $0) }
            }
        }
        guard !wallets.isEmpty else {
            guard let name = MeldReadiness.otherPlatformWallets[paymentMethodType] else { return .unchecked }
            return .unavailable("\(name) is not available on iOS.")
        }
        var networks: [PKPaymentNetwork] = []
        for (adapter, wallet) in wallets where adapter.capabilities.surface != "unsupported" {
            networks += wallet.networks.filter { !networks.contains($0) }
        }
        guard !networks.isEmpty else {
            return .unavailable("This SDK cannot present \(paymentMethodType) on this device.")
        }
        return MeldApplePayAvailability.readiness(.requested(networks), probe: probe)
    }

    private func readiness(_ presentation: MeldAdapterPresentation, probe: WalletProbe) -> MeldReadiness {
        guard let adapter = adapter(for: presentation) else {
            return .unavailable("This SDK does not present \(presentation.method) via \(presentation.surface)/"
                                + "\(presentation.protocolName) v\(presentation.version).")
        }
        guard adapter.capabilities.surface != "unsupported" else {
            return .unavailable("This SDK cannot present this payment method on this device.")
        }
        guard let wallet = adapter.walletNetworks(paymentMethodType: presentation.method) else {
            return .unchecked
        }
        return MeldApplePayAvailability.readiness(wallet, probe: probe)
    }
}
