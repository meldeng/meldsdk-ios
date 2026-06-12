import UIKit

/// A normalized event the SDK relays to the integrator's `MeldEventHandlers`. A provider adapter
/// produces these from its widget; the host that renders the widget dispatches them.
enum MeldEvent {
    case ready
    case paymentSubmitted
    case statusChange(MeldStatusChange)
    case cancel
    case error(MeldError)
}

/// A live provider surface — an embedded widget or a native sheet. Call `unmount()` to tear it
/// down (remove the widget, or dismiss the sheet).
protocol MeldProviderSession: AnyObject {
    func unmount()
}

/// Everything `Meld.mount` knows that an adapter might need beyond the order itself. Each surface
/// uses a different subset: an embedded widget needs `host`; a native sheet (Apple Pay) needs its
/// method-specific `applePay` request and ignores `host`. An adapter validates what it requires and
/// throws if it's absent — that's why these are optional here rather than separate `mount` methods.
struct MeldMountContext {
    /// The view an embedded widget renders into. Nil for surfaces that present themselves.
    let host: UIView?
    /// Inputs for a native Apple Pay sheet (amount/currency/country/wallet/IP) not carried on the
    /// order. Nil for non-Apple-Pay orders.
    let applePay: MeldApplePayRequest?
}

/// A provider/payment-method adapter. The SDK is a container manager and event relay; everything
/// provider-specific — which orders it handles, how its surface is rendered (embedded widget or
/// native sheet), and how its events map to Meld events — lives behind this protocol. Supporting a
/// new provider or surface is a new adapter in the registry, never a change to the public API.
///
/// A provider that renders by loading a signed URL in a WebView (e.g. Mercuryo card) can build on
/// the generic `WebViewHost`; one that presents a native sheet (Apple Pay) drives PassKit instead —
/// the SDK doesn't care which, it just calls `mount` and relays the session's events.
protocol MeldAdapter {
    /// Human-readable "(paymentMethodType / renderMode)" this adapter handles. Used to build the
    /// "unsupported order" error so it stays truthful as adapters are added.
    var label: String { get }

    /// What this adapter can do with a matching order.
    var capabilities: MeldCapabilities { get }

    /// Whether this adapter handles the given order discriminators.
    func matches(paymentMethodType: String?, renderMode: String?) -> Bool

    /// Render the order's surface, wiring its lifecycle to `handlers`, and return a session to tear
    /// it down. Throws if the order or `context` lacks what this adapter needs (e.g. a host view
    /// for a widget, or the Apple Pay request for a sheet).
    func mount(order: MeldOrder, context: MeldMountContext, handlers: MeldEventHandlers) throws -> MeldProviderSession
}
