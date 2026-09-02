import Foundation
import UIKit

/// Banxa credit/debit card. Single-step: the backend has already created the Banxa order, and the
/// order carries a Primer client token (Banxa's `nativeToken`) as `sdkSessionToken`. There is no
/// provider URL to load — the capture surface is built on the device from the token alone, which
/// makes this the first adapter with no `serviceProviderWidgetUrl`.
///
/// Rendering runs Banxa's own `<banxa-primer-checkout>` web component (which wraps Primer's Checkout
/// Web SDK) inside the reused `WebViewHost`, the same shape as `UpholdCardAdapter`. That is Banxa's
/// documented order-first integration: the component takes only a client token, so no Banxa API
/// credential ever reaches the device. Banxa's *native* iOS SDK is deliberately not used — it creates
/// its own order inside `startPayment`, which would bypass Meld's order lifecycle entirely (no
/// `headless_order` row, nothing for the webhook to correlate, quote and routing skipped).
struct BanxaCardAdapter: MeldAdapter {
    let label = "Banxa card (CREDIT_DEBIT_CARD / IFRAME, SDK token)"
    /// How the capture surface is presented. Injected so the native (Primer SDK) presenter can be
    /// swapped in without touching selection or event mapping — see `BanxaCheckoutPresenter`.
    let presenter: BanxaCheckoutPresenter

    init(presenter: BanxaCheckoutPresenter = BanxaWebCheckoutPresenter()) {
        self.presenter = presenter
    }

    var capabilities: MeldCapabilities { presenter.capabilities }

    static let serviceProvider = "BANXA"

    /// Keys on the provider itself, not on rendering technology.
    ///
    /// An earlier revision matched on `sdkSessionFlow == "primer"`, which overloaded a field meaning
    /// "which step of Uphold's two-step flow this is" and, worse, would have matched every other
    /// Primer-backed provider — Primer is an orchestrator several PSPs sit behind.
    ///
    /// Registry order matters: `MercuryoCardAdapter` matches any CREDIT_DEBIT_CARD + IFRAME order, so
    /// Banxa must be registered ahead of it.
    func matches(_ order: MeldOrder) -> Bool {
        order.serviceProvider == Self.serviceProvider
            && order.paymentMethodType == "CREDIT_DEBIT_CARD"
            && order.paymentMethodResponseDetails?.renderMode == "IFRAME"
    }

    /// Headless card: Primer's fields render in place from the order's client token
    /// (`sdkSessionToken`), which Banxa returns as `nativeToken` for merchants provisioned for native
    /// payments.
    ///
    /// There is deliberately no fallback to `serviceProviderWidgetUrl`. For Banxa that URL is its full
    /// hosted checkout — sign-in, email OTP, KYC, method picker — a different product rather than a
    /// lesser rendering of this one, and mounting it here would silently turn a headless integration
    /// into a hosted one. A missing token is a provisioning fault, and says so.
    func mount(
        order: MeldOrder, context: MeldMountContext, handlers: MeldEventHandlers
    ) throws -> MeldProviderSession {
        return try presenter.present(order: order, context: context, handlers: handlers)
    }

}
