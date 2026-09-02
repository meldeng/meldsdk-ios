import UIKit

/// How a Banxa order's capture surface is put on screen, given the Primer client token the order
/// carries.
///
/// This seam exists because the *right* answer differs by platform and is still moving. Banxa's own
/// mobile SDK is disqualified — it creates its own order (`startPayment` "checks eligibility,
/// creates the order, and presents the native payment sheet"), which would leave Meld without a
/// `headless_order` row to correlate, and it requires Banxa credentials on the device. That leaves
/// two presenters for the same token:
///
/// - ``BanxaWebCheckoutPresenter`` — Banxa's `<banxa-primer-checkout>` web component, run inside the
///   shared `WebViewHost`. Works today, and is what card ships on.
/// - a Primer-native presenter — Primer's own iOS SDK, which completes a payment on an order that
///   already exists. A true native sheet, native 3DS, no vendored bundle, and the only route that
///   can present **Apple Pay**: the web component cannot, because Apple Pay on the Web requires the
///   page origin to be a registered Apple Pay domain and the bootstrap page's origin is not ours.
///
/// Keeping the choice behind this protocol means adding the native presenter is one new file plus a
/// dependency, with the working web path untouched — rather than a rewrite of the adapter, its
/// selection, or its event mapping.
protocol BanxaCheckoutPresenter {
    /// What this surface can do, surfaced as the adapter's own ``MeldCapabilities``. It belongs to
    /// the presenter, not the adapter: the web component is an embedded widget that needs no user
    /// gesture, whereas Primer's drop-in presents its own modal and is not embeddable at all. An
    /// integrator guards on `capabilities.embeddable`, so answering for the wrong presenter would
    /// have it lay out a container for a sheet that never fills it.
    var capabilities: MeldCapabilities { get }

    /// Present the capture surface for `order`, wiring its lifecycle to `handlers`.
    ///
    /// Takes the whole order rather than a token because the presenters need different things from
    /// it: the web component needs `sdkSessionToken`, and Banxa's own SDK needs the order parameters
    /// it will create the Banxa order from. Each validates what it requires and throws if it is
    /// absent — the adapter cannot check on their behalf without knowing which one it has.
    func present(
        order: MeldOrder,
        context: MeldMountContext,
        handlers: MeldEventHandlers
    ) throws -> MeldProviderSession
}
