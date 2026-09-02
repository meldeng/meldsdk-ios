import Foundation
import UIKit

/// Banxa orders that Banxa's own SDK creates and presents — card and Apple Pay alike.
///
/// Selected by the shape of the response, not by the payment method: a `providerOrderCreation = CLIENT`
/// order carries the parameters the SDK needs instead of anything to render, and `paymentMethodId`
/// inside it decides whether Primer shows card fields or the Apple Pay sheet. That is why one adapter
/// serves both, where the web-component path needs a separate entry per surface.
///
/// Registered ahead of `BanxaCardAdapter`: a Banxa CLIENT card order is also
/// `CREDIT_DEBIT_CARD`, and the card adapter would claim it and then fail on the `sdkSessionToken`
/// that this shape correctly does not have.
struct BanxaProviderSdkAdapter: MeldAdapter {
    let label = "Banxa provider SDK (card / Apple Pay, order created on device)"

    /// Deferred to the presenter, which knows the surface is a modal the SDK owns rather than
    /// something that renders into a host view.
    var capabilities: MeldCapabilities { presenter.capabilities }

    let presenter: BanxaCheckoutPresenter

    init(presenter: BanxaCheckoutPresenter? = nil) {
        self.presenter = presenter ?? MainActor.assumeIsolated { BanxaNativeCheckoutPresenter() }
    }

    /// Keys on the two fields only this shape has.
    ///
    /// `sdkConfigUrl` is the decisive one: it exists solely to configure a provider SDK on the device,
    /// so no rendering payload carries it. `externalOrderId` is checked with it because it is what
    /// joins the order Banxa is about to create back to Meld's — an order missing it would create a
    /// Banxa order nothing can correlate, which is worse than not matching.
    func matches(_ order: MeldOrder) -> Bool {
        guard order.serviceProvider == "BANXA" else { return false }
        let details = order.paymentMethodResponseDetails
        return (details?["sdkConfigUrl"] as? String)?.isEmpty == false
            && (details?["externalOrderId"] as? String)?.isEmpty == false
    }

    func mount(
        order: MeldOrder, context: MeldMountContext, handlers: MeldEventHandlers
    ) throws -> MeldProviderSession {
        try presenter.present(order: order, context: context, handlers: handlers)
    }
}
