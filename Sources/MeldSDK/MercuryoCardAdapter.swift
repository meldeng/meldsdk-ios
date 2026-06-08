import Foundation
import UIKit

/// Mercuryo credit/debit card, rendered by loading the signed widget URL in a WebView. Maps
/// Mercuryo's widget messages onto the Meld event model:
///
///   mercuryoReady           -> .ready
///   mercuryoPaymentFinished -> .paymentSubmitted (UX hint — user finished the flow, NOT settlement)
///   mercuryoStatusChanged   -> .statusChange with a normalized status; terminal `failed`
///                              additionally -> .error, terminal `cancelled` -> .cancel
struct MercuryoCardAdapter: MeldAdapter {
    let label = "Mercuryo card (CREDIT_DEBIT_CARD / IFRAME)"
    let capabilities = MeldCapabilities(embeddable: true, surface: "embedded", requiresUserGesture: false)

    func matches(paymentMethodType: String?, renderMode: String?) -> Bool {
        paymentMethodType == "CREDIT_DEBIT_CARD" && renderMode == "IFRAME"
    }

    func mount(order: MeldOrder, into host: UIView, handlers: MeldEventHandlers) throws -> MeldProviderSession {
        guard let urlString = order.paymentMethodResponseDetails?.serviceProviderWidgetUrl,
              let url = URL(string: urlString) else {
            throw MeldMountError.missingWidgetURL
        }
        warnIfEnvironmentMismatch(widgetHost: url.host)

        let session = WebViewHost(url: url, orderId: order.id, handlers: handlers) { message in
            Self.interpret(providerMessage: message, orderId: order.id)
        }
        session.mount(into: host)
        return session
    }

    // MARK: - Mercuryo message -> Meld events

    private static func interpret(providerMessage: [String: Any], orderId: String?) -> [MeldEvent] {
        guard let type = providerMessage["type"] as? String else { return [] }
        let payload = providerMessage["data"] as? [String: Any]

        switch type {
        case "mercuryoReady":
            return [.ready]

        case "mercuryoPaymentFinished":
            return [.paymentSubmitted]

        case "mercuryoStatusChanged":
            let code = payload?["status"] as? String
            let status = normalize(code)
            var events: [MeldEvent] = [.statusChange(MeldStatusChange(
                orderId: orderId, status: status, providerStatus: code, raw: payload ?? providerMessage))]
            if status == .failed {
                events.append(.error(MeldError(
                    orderId: orderId, code: code ?? "failed",
                    message: "Mercuryo reported terminal status: \(code ?? "failed")",
                    recoverable: false)))
            } else if status == .cancelled {
                events.append(.cancel)
            }
            return events

        default:
            return [] // non-lifecycle provider messages
        }
    }

    // Mercuryo's status vocabulary -> the SDK's normalized set. Interim/unknown codes
    // (new, pending, processing, …) collapse to `.pending`.
    private static let statusMap: [String: MeldStatus] = [
        "paid": .completed, "completed": .completed, "order_completed": .completed,
        "succeeded": .completed, "success": .completed,
        "failed": .failed, "order_failed": .failed, "failed_exchange": .failed,
        "descriptor_failed": .failed, "rejected": .failed,
        "cancelled": .cancelled, "canceled": .cancelled,
    ]

    private static func normalize(_ code: String?) -> MeldStatus {
        guard let code, !code.isEmpty else { return .pending }
        return statusMap[code] ?? .pending
    }

    // MARK: - Environment sanity check

    // Recognized widget URL hosts per environment. The order's signed URL is authoritative;
    // this lets the SDK flag a configured environment that doesn't match the order.
    private static let hostsByEnvironment: [MeldEnvironment: Set<String>] = [
        .sandbox: ["sandbox-widget.mrcr.io", "sandbox-exchange.mrcr.io"],
        .production: ["widget.mercuryo.io", "exchange.mercuryo.io"],
    ]

    private func warnIfEnvironmentMismatch(widgetHost: String?) {
        guard let widgetHost,
              let orderEnv = Self.hostsByEnvironment.first(where: { $0.value.contains(widgetHost) })?.key,
              orderEnv != Meld.environment
        else { return }
        print("[MeldSDK] order environment is '\(orderEnv.rawValue)' but Meld.configure set "
            + "'\(Meld.environment.rawValue)'. Configure the matching environment to silence this.")
    }
}
