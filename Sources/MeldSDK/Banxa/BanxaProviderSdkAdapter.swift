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

    /// Constant, and deliberately NOT read off a presenter instance: the registry is a plain
    /// `static let`, and `Meld.capabilities(for:)` is a pure query callers may issue from any
    /// queue. Constructing the `@MainActor` presenter here (an earlier revision did, via
    /// `MainActor.assumeIsolated`) trapped with "Incorrect actor executor assumption" the first time
    /// the SDK was touched off the main thread. The surface is a modal the SDK owns rather than
    /// something that renders into a host view, hence not embeddable.
    let capabilities = MeldCapabilities(embeddable: false, surface: "native-sheet", requiresUserGesture: true)

    /// Built per mount, on the main actor, where presenting UI has to happen anyway.
    private let presenterFactory: @MainActor () -> BanxaCheckoutPresenter

    init(presenter: BanxaCheckoutPresenter? = nil) {
        if let presenter {
            presenterFactory = { presenter }
        } else {
            presenterFactory = { BanxaNativeCheckoutPresenter() }
        }
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
        // Presenting a sheet is main-thread work by UIKit's own rules; mount() inherits that
        // precondition (documented on Meld.mount) rather than hopping queues and returning a session
        // whose sheet has not appeared yet.
        try MainActor.assumeIsolated {
            try presenterFactory().present(order: order, context: context, handlers: handlers)
        }
    }
}
