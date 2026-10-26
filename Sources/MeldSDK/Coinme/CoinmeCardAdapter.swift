import UIKit

/// Coinme credit/debit card (`VENDOR_SDK / COINME_VAULT / 1`), presented by the Meld web SDK's Coinme flow
/// in a WebView (`CoinmeWebCheckout`): Coinme's web Vault fields capture the card and its web Risk SDK
/// scores the device, so no Coinme library ships in this SDK. Settlement arrives by webhook.
struct CoinmeCardAdapter: MeldAdapter {
    let label = "Coinme card (CREDIT_DEBIT_CARD / VENDOR_SDK COINME_VAULT)"
    let capabilities = MeldCapabilities(embeddable: true, surface: "embedded", requiresUserGesture: false)
    let presentations = [MeldAdapterPresentation("CREDIT_DEBIT_CARD", "VENDOR_SDK", "COINME_VAULT")]

    func acceptsDeclaredOrder(_ order: MeldOrder) -> Bool { (try? CoinmeCardOrder(order, environment: Meld.environment)) != nil }
    func matches(_ order: MeldOrder) -> Bool { false }

    func mount(order: MeldOrder, context: MeldMountContext, handlers: MeldEventHandlers) throws -> MeldProviderSession {
        guard let host = context.host else { throw MeldMountError.missingHost(label) }
        guard Thread.isMainThread else { throw MeldMountError.presentationUnavailable }
        let coinme = try CoinmeCardOrder(order, environment: Meld.environment)
        return try CoinmeWebCheckout(coinme: coinme, order: order.raw, environment: Meld.environment, handlers: handlers)
            .present(into: host)
    }
}
