import Foundation
import PassKit
import UIKit

// Public surface of the SDK. The same shape as the web SDK (@meldcrypto/sdk):
//   Meld.configure(environment:)
//   Meld.capabilities(for:)
//   Meld.mount(order, into:, handlers:)
//   handle.unmount()
// The order's paymentMethodType and renderMode select the provider widget to embed, so
// supporting a new provider does not change this API. Supported today: Mercuryo card.

public enum MeldEnvironment: String {
    case sandbox
    case production
}

/// The HeadlessOrderResponse from `POST /crypto/order/headless`, passed verbatim. The fields the
/// SDK reads are exposed directly; the whole `paymentMethodResponseDetails` is also kept as `raw`
/// so provider-specific fields (a session token, etc.) stay available without modeling each one.
public struct MeldOrder {
    public let id: String?
    public let paymentMethodType: String?
    public let paymentMethodResponseDetails: Details?

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
        return MeldOrder(
            id: dict["id"] as? String,
            paymentMethodType: dict["paymentMethodType"] as? String,
            paymentMethodResponseDetails: details)
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
    public let recoverable: Bool

    public init(orderId: String?, code: String, message: String, detail: String? = nil, recoverable: Bool) {
        self.orderId = orderId
        self.code = code
        self.message = message
        self.detail = detail
        self.recoverable = recoverable
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

    public var errorDescription: String? {
        switch self {
        case let .unsupported(detail):
            return detail
        case .missingWidgetURL:
            return "Order has no paymentMethodResponseDetails.serviceProviderWidgetUrl to load."
        }
    }
}

/// Handle returned by `mount` — call `unmount()` on teardown (navigation, dismissal).
public final class MeldWidgetHandle {
    public let mode: String
    private weak var session: MeldProviderSession?

    init(mode: String, session: MeldProviderSession) {
        self.mode = mode
        self.session = session
    }

    public func unmount() { session?.unmount() }
}

public enum Meld {
    public private(set) static var environment: MeldEnvironment = .sandbox

    // Adapter registry — the only place provider knowledge lives. Dispatch is on
    // (paymentMethodType, renderMode); first match wins. Supporting a new provider is a new
    // entry here, never a change to the public API or the generic widget host.
    static let adapters: [MeldAdapter] = [
        MercuryoCardAdapter(),
    ]

    public static func configure(environment: MeldEnvironment) {
        self.environment = environment
    }

    public static func capabilities(for order: MeldOrder) -> MeldCapabilities {
        // Apple Pay is a native modal sheet, not a widget mounted into a view: it's not
        // `embeddable` (guard with this before `mount`), and is presented via `presentApplePay`.
        if order.paymentMethodType == "APPLE_PAY" {
            return MeldCapabilities(embeddable: false, surface: "native-applepay", requiresUserGesture: true)
        }
        return adapter(for: order)?.capabilities
            ?? MeldCapabilities(embeddable: false, surface: "unsupported", requiresUserGesture: false)
    }

    /// Mount the provider widget into a host `UIView` you own. Returns a handle; call
    /// `handle.unmount()` to tear down.
    @discardableResult
    public static func mount(
        _ order: MeldOrder,
        into host: UIView,
        handlers: MeldEventHandlers = MeldEventHandlers()
    ) throws -> MeldWidgetHandle {
        guard let adapter = adapter(for: order) else {
            let type = order.paymentMethodType ?? "nil"
            let mode = order.paymentMethodResponseDetails?.renderMode ?? "nil"
            let supported = adapters.map(\.label).joined(separator: ", ")
            throw MeldMountError.unsupported(
                "No embeddable adapter for paymentMethodType=\(type) renderMode=\(mode). "
                    + "This SDK supports: \(supported). "
                    + "Guard with Meld.capabilities(for:).embeddable before mount.")
        }
        // The adapter owns how its widget is rendered (URL in a WebView, provider SDK, …).
        let session = try adapter.mount(order: order, into: host, handlers: handlers)
        return MeldWidgetHandle(mode: adapter.capabilities.surface, session: session)
    }

    /// First registered adapter that handles the order, or nil if none do.
    static func adapter(for order: MeldOrder) -> MeldAdapter? {
        let mode = order.paymentMethodResponseDetails?.renderMode
        return adapters.first { $0.matches(paymentMethodType: order.paymentMethodType, renderMode: mode) }
    }
}

// MARK: - Native Apple Pay

public extension Meld {
    /// Whether this device and user can pay with Apple Pay right now (a card is provisioned and
    /// payments aren't restricted). Check before offering an Apple Pay button.
    static func canPresentApplePay() -> Bool {
        PKPaymentAuthorizationController.canMakePayments()
    }

    /// Present the native Apple Pay sheet for an `APPLE_PAY` order and drive it to completion.
    ///
    /// Unlike `mount`, Apple Pay isn't embedded in a view you own — PassKit presents its own modal
    /// sheet. On authorization the SDK posts the encrypted token to the order's session-scoped
    /// `/process` endpoint (authenticated with the order's session token — no API key) and relays
    /// the outcome through `handlers`. As everywhere in the SDK, settlement is your webhook, not
    /// `onPaymentSubmitted` or a `completed` status.
    ///
    /// The order supplies `merchantIdentifier`, `sessionToken`, and `merchantTransactionId`; the
    /// `request` supplies what the sheet and `/process` need that the order doesn't carry (amount,
    /// currency, country, destination wallet, end-user IP).
    ///
    /// - Returns: a handle whose `unmount()` dismisses the sheet.
    /// - Throws: `MeldApplePayError` if the order isn't a usable Apple Pay order or Apple Pay is
    ///   unavailable.
    @discardableResult
    static func presentApplePay(
        _ order: MeldOrder,
        request: MeldApplePayRequest,
        handlers: MeldEventHandlers = MeldEventHandlers()
    ) throws -> MeldWidgetHandle {
        guard order.paymentMethodType == "APPLE_PAY" else {
            throw MeldApplePayError.invalidOrder(
                "Order paymentMethodType is \(order.paymentMethodType ?? "nil"); expected APPLE_PAY.")
        }
        let details = order.paymentMethodResponseDetails
        guard let sessionToken = details?["sessionToken"] as? String, !sessionToken.isEmpty else {
            throw MeldApplePayError.invalidOrder("Apple Pay order is missing sessionToken.")
        }
        guard let merchantTransactionId = details?["merchantTransactionId"] as? String,
              !merchantTransactionId.isEmpty else {
            throw MeldApplePayError.invalidOrder("Apple Pay order is missing merchantTransactionId.")
        }
        guard let merchantIdentifier = details?["merchantIdentifier"] as? String, !merchantIdentifier.isEmpty else {
            throw MeldApplePayError.invalidOrder(
                "Apple Pay order is missing merchantIdentifier — the account may not be configured for Apple Pay.")
        }
        guard canPresentApplePay() else { throw MeldApplePayError.unavailable }

        let client = MercuryoApplePayClient(environment: environment, sessionToken: sessionToken)
        let coordinator = ApplePayCoordinator(
            orderId: order.id,
            merchantIdentifier: merchantIdentifier,
            merchantTransactionId: merchantTransactionId,
            request: request,
            handlers: handlers,
            client: client)
        coordinator.present()
        return MeldWidgetHandle(mode: "native-applepay", session: coordinator)
    }
}
