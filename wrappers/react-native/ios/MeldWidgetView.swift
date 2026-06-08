import UIKit
import React
import MeldSDK

/// A UIView that hosts the Meld widget and forwards the SDK's events as React Native event blocks.
/// Thin pass-through — all SDK logic stays in MeldSDK.
final class MeldWidgetView: UIView {
    private var handle: MeldWidgetHandle?

    // Wired up by React Native from the matching JS props.
    @objc var onReady: RCTDirectEventBlock?
    @objc var onPaymentSubmitted: RCTDirectEventBlock?
    @objc var onStatusChange: RCTDirectEventBlock?
    @objc var onCancel: RCTDirectEventBlock?
    @objc var onError: RCTDirectEventBlock?

    // The order JSON from JS. Mount once it arrives.
    @objc var order: NSDictionary? { didSet { mountIfNeeded() } }

    private func mountIfNeeded() {
        guard handle == nil, let order,
              let data = try? JSONSerialization.data(withJSONObject: order),
              let parsed = try? MeldOrder.from(jsonData: data) else { return }

        handle = try? Meld.mount(parsed, into: self, handlers: MeldEventHandlers(
            onReady: { id in self.onReady?(["orderId": id ?? ""]) },
            onPaymentSubmitted: { id in self.onPaymentSubmitted?(["orderId": id ?? ""]) },
            onStatusChange: { e in
                self.onStatusChange?([
                    "orderId": e.orderId ?? "",
                    "status": e.status.rawValue,
                    "providerStatus": e.providerStatus ?? "",
                ])
            },
            onCancel: { id in self.onCancel?(["orderId": id ?? ""]) },
            onError: { e in
                self.onError?([
                    "orderId": e.orderId ?? "",
                    "code": e.code,
                    "message": e.message,
                    "recoverable": e.recoverable,
                ])
            }
        ))
    }

    override func removeFromSuperview() {
        handle?.unmount() // teardown when RN removes the component
        handle = nil
        super.removeFromSuperview()
    }
}
