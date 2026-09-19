import Foundation
import PassKit
import UIKit

// Public surface of the SDK. The same shape as the web SDK (@meldcrypto/sdk):
//   Meld.configure(environment:)
//   Meld.capabilities(for:)
//   Meld.mount(order, into:, handlers:)
//   handle.unmount()
// The order's versioned presentation protocol selects its adapter. Older stored orders use
// an isolated compatibility path; adding an adapter does not change this public API.

public enum MeldEnvironment: String {
    case sandbox
    case qa
    case production
}

/// The HeadlessOrderResponse from `POST /crypto/order/headless`, passed verbatim. The fields the
/// SDK reads are exposed directly. The original response is retained internally to resolve
/// server-declared action credentials without duplicating provider-specific field mappings.
public struct MeldOrder {
    public let id: String?
    public let paymentMethodType: String?
    /// `payload.serviceProvider` from the headless order response — the provider that will process
    /// this order (e.g. "BANXA", "MERCURYO"). Retained for display and legacy compatibility;
    /// declared protocol dispatch does not use provider identity.
    public let serviceProvider: String?
    public let paymentMethodResponseDetails: Details?
    let raw: [String: Any]
    let presentationDeclaration: HeadlessPresentationDeclaration

    /// Server-declared protocol metadata, including well-formed values this binary cannot present.
    public var headlessPresentation: MeldHeadlessPresentation? {
        if case .declared(let value) = presentationDeclaration { return value }
        return nil
    }

    public struct Details {
        public let serviceProviderWidgetUrl: String?
        public let renderMode: String?
        /// Every detail field as returned, including provider-specific ones not modeled above.
        public let raw: [String: Any]

        /// Convenience access to a raw detail field (e.g. a provider session token).
        public subscript(_ key: String) -> Any? { raw[key] }
    }

    /// Decode the order your backend returns (pass it through untouched).
    public static func from(jsonData: Data) throws -> MeldOrder {
        guard let dict = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw MeldOrderError.malformed
        }
        let details = (dict["paymentMethodResponseDetails"] as? [String: Any]).map { d in
            Details(serviceProviderWidgetUrl: d["serviceProviderWidgetUrl"] as? String,
                    renderMode: d["renderMode"] as? String,
                    raw: d)
        }
        // The provider is echoed under `payload` on the headless create response. It is required on
        // the request, so it is always present there — but read defensively, since the mid-flow
        // authorize-session response (Uphold) is a different shape that carries no payload.
        let serviceProvider = (dict["payload"] as? [String: Any])?["serviceProvider"] as? String
        return MeldOrder(
            id: dict["id"] as? String,
            paymentMethodType: dict["paymentMethodType"] as? String,
            serviceProvider: serviceProvider,
            paymentMethodResponseDetails: details,
            raw: dict,
            presentationDeclaration: .decode(order: dict))
    }

    public static func from(jsonString: String) throws -> MeldOrder {
        try from(jsonData: Data(jsonString.utf8))
    }
}

public enum MeldOrderError: LocalizedError {
    case malformed
    public var errorDescription: String? { "Order JSON is not a JSON object." }
}

/// Normalized order status, consistent across providers.
public enum MeldStatus: String {
    case pending, completed, failed, cancelled
}

public struct MeldStatusChange {
    public let orderId: String?
    public let status: MeldStatus
    public let providerStatus: String?
    public let raw: Any?
}

public struct MeldError {
    public let orderId: String?
    public let code: String
    public let message: String
    /// Extra diagnostic detail when the SDK has it (e.g. a load-failure probe). May be nil.
    public let detail: String?
    /// Legacy presentation hint; never authorizes payment replay or a replacement order.
    public let recoverable: Bool
    /// Shared recovery advice. Unclassified failures preserve the existing financial attempt.
    public let headlessError: MeldHeadlessError?

    public init(orderId: String?, code: String, message: String, detail: String? = nil, recoverable: Bool,
                headlessError: MeldHeadlessError? = nil) {
        self.orderId = orderId
        self.code = code
        self.message = message
        self.detail = detail
        self.recoverable = recoverable
        self.headlessError = headlessError ?? MeldHeadlessError(category: .outcomeUnknown, recovery: .readState)
    }
}

/// Lifecycle callbacks. Each callback receives the id of the order it relates to, so an app
/// handling several orders at once can tell them apart.
public struct MeldEventHandlers {
    public var onReady: ((_ orderId: String?) -> Void)?
    public var onPaymentSubmitted: ((_ orderId: String?) -> Void)?
    public var onStatusChange: ((MeldStatusChange) -> Void)?
    public var onCancel: ((_ orderId: String?) -> Void)?
    public var onError: ((MeldError) -> Void)?

    public init(
        onReady: ((_ orderId: String?) -> Void)? = nil,
        onPaymentSubmitted: ((_ orderId: String?) -> Void)? = nil,
        onStatusChange: ((MeldStatusChange) -> Void)? = nil,
        onCancel: ((_ orderId: String?) -> Void)? = nil,
        onError: ((MeldError) -> Void)? = nil
    ) {
        self.onReady = onReady
        self.onPaymentSubmitted = onPaymentSubmitted
        self.onStatusChange = onStatusChange
        self.onCancel = onCancel
        self.onError = onError
    }
}

public struct MeldCapabilities {
    public let embeddable: Bool
    public let surface: String
    public let requiresUserGesture: Bool
}

public enum MeldMountError: LocalizedError {
    /// No adapter handles the order. The detail is built from the adapter registry, so it
    /// lists whatever providers are supported without hardcoding any provider here.
    case unsupported(String)
    case missingWidgetURL
    /// This order's surface is an embedded widget, but `mount` was called without a host view.
    case missingHost(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupported(detail):
            return detail
        case .missingWidgetURL:
            return "Order has no paymentMethodResponseDetails.serviceProviderWidgetUrl to load."
        case let .missingHost(label):
            return "\(label) renders into a view — call mount(_:into:handlers:) with a host UIView."
        }
    }
}

/// Handle returned by `mount` — call `unmount()` on teardown (navigation, dismissal).
///
/// The handle STRONGLY owns the provider session: it is the mounted widget's lifecycle owner, so the
/// session must live exactly as long as the integrator keeps the handle. A weak reference would let a
/// session that isn't itself retained by the view tree deallocate immediately after `mount` returns —
/// which is fatal for multi-step providers (e.g. Uphold), whose orchestrating session object owns the
/// WebView(s) rather than being one. No retain cycle exists: a session never references its handle.
public final class MeldWidgetHandle {
    public let mode: String
    private let session: MeldProviderSession

    init(mode: String, session: MeldProviderSession) {
        self.mode = mode
        self.session = session
    }

    public func unmount() { session.unmount() }
    deinit {
        let session = session
        if Thread.isMainThread { session.unmount() }
        else { DispatchQueue.main.async { session.unmount() } }
    }
}

public enum Meld {
    public private(set) static var environment: MeldEnvironment = .sandbox

    // Declared protocols are indexed explicitly. Registration order matters only for legacy orders.
    static let adapters: [MeldAdapter] = [
        UpholdCardAdapter(), BanxaCardAdapter(), MercuryoCardAdapter(),
        HostedLinkApplePayAdapter(), BanxaApplePayAdapter(), MercuryoApplePayAdapter(),
        StripeNativeAdapter(),
    ]
    private static let registry: MeldAdapterRegistry = {
        do { return try MeldAdapterRegistry(adapters) }
        catch { preconditionFailure("Duplicate built-in Meld presentation registration") }
    }()

    public static func configure(environment: MeldEnvironment) {
        self.environment = environment
    }

    public static func capabilities(for order: MeldOrder) -> MeldCapabilities {
        adapter(for: order)?.capabilities
            ?? MeldCapabilities(embeddable: false, surface: "unsupported", requiresUserGesture: false)
    }

    /// Advisory support for a quote or payment method before creating an order. This only checks
    /// the installed adapter registry: it does not validate eligibility, Apple Pay availability,
    /// legal evidence or an order's credentials. Check `capabilities(for: order)` again before mount.
    /// Missing declarations must not be inferred from a provider name or legacy payload fields.
    public static func capabilities(for presentation: MeldHeadlessPresentation,
                                    paymentMethodType: String) -> MeldCapabilities {
        registry.adapter(for: presentation, paymentMethodType: paymentMethodType)?.capabilities
            ?? MeldCapabilities(embeddable: false, surface: "unsupported", requiresUserGesture: false)
    }

    /// Mount the order's payment surface and relay its lifecycle through `handlers`. One call for
    /// every surface — the order selects the adapter, which renders the right thing:
    ///
    /// - **Embedded widget** (e.g. Mercuryo card): pass the `UIView` you own as `into:`.
    ///   `Meld.mount(order, into: containerView, handlers:)`
    /// - **Native Apple Pay sheet**: pass `applePay:` with the order's amount/currency and billing
    ///   email fallback. `Meld.mount(order, applePay: request, handlers:)`
    ///
    /// Returns a handle; `handle.unmount()` tears down the surface (removes the widget or dismisses
    /// the sheet). Call on the main thread. Static payload errors throw; state-dependent validation
    /// (after an action-state read) reports through `onError`.
    @discardableResult
    public static func mount(
        _ order: MeldOrder,
        into host: UIView? = nil,
        applePay: MeldApplePayRequest? = nil,
        handlers: MeldEventHandlers = MeldEventHandlers()
    ) throws -> MeldWidgetHandle {
        guard let adapter = adapter(for: order) else {
            let type = order.paymentMethodType ?? "nil"
            let mode = order.paymentMethodResponseDetails?.renderMode ?? "nil"
            let supported = adapters.map(\.label).joined(separator: ", ")
            throw MeldMountError.unsupported(
                "No adapter for paymentMethodType=\(type) renderMode=\(mode). "
                    + "This SDK supports: \(supported).")
        }
        // The adapter owns how its surface is rendered (URL in a WebView, native PassKit sheet, …)
        // and validates whatever it needs from the context.
        let context = MeldMountContext(host: host, applePay: applePay)
        // Gate here rather than in a host's dispatch so it also covers adapters that invoke a
        // handler directly — see TerminalGate.
        let session = try adapter.mount(order: order, context: context, handlers: handlers.gated())
        return MeldWidgetHandle(mode: adapter.capabilities.surface, session: session)
    }

    /// Capabilities and mount share authoritative protocol dispatch and legacy replay compatibility.
    static func adapter(for order: MeldOrder) -> MeldAdapter? {
        registry.adapter(for: order)
    }

}

// MARK: - Native Apple Pay

public extension Meld {
    /// Whether this device and user can pay with Apple Pay right now (a card is provisioned and
    /// payments aren't restricted). Check before offering an Apple Pay button; Apple Pay orders are
    /// then presented through the normal `Meld.mount(order, applePay:handlers:)`.
    static func canPresentApplePay() -> Bool {
        PKPaymentAuthorizationController.canMakePayments()
    }
}
