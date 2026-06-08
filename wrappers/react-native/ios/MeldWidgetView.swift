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
        guard handle == nil, let order else { return }

        // Parse failures used to be swallowed by `try?`, leaving a blank view with no signal to
        // JS. Surface them through onError so the integrator can react.
        let parsed: MeldOrder
        do {
            let data = try JSONSerialization.data(withJSONObject: order)
            parsed = try MeldOrder.from(jsonData: data)
        } catch {
            emitError(code: "INVALID_ORDER", message: "Could not parse the order JSON: \(error.localizedDescription)")
            return
        }

        do {
            // [weak self]: WebKit retains the script handler (and thus the session) for the
            // WebView's lifetime; capturing self strongly here would form a retain cycle that
            // only breaks at removeFromSuperview -> unmount.
            handle = try Meld.mount(parsed, into: self, handlers: MeldEventHandlers(
                onReady: { [weak self] id in self?.onReady?(["orderId": id ?? ""]) },
                onPaymentSubmitted: { [weak self] id in self?.onPaymentSubmitted?(["orderId": id ?? ""]) },
                onStatusChange: { [weak self] e in
                    var payload: [String: Any] = [
                        "orderId": e.orderId ?? "",
                        "status": e.status.rawValue,
                        "providerStatus": e.providerStatus ?? "",
                    ]
                    // Forward the raw provider payload when it's JSON-serializable, for parity
                    // with the native struct (logging/debugging on the JS side).
                    if let raw = e.raw, JSONSerialization.isValidJSONObject(raw) { payload["raw"] = raw }
                    self?.onStatusChange?(payload)
                },
                onCancel: { [weak self] id in self?.onCancel?(["orderId": id ?? ""]) },
                onError: { [weak self] e in self?.send(error: e) }
            ))
        } catch {
            // Mount failures (unsupported order, missing widget URL) also went silent under `try?`.
            emitError(code: "MOUNT_FAILED", message: error.localizedDescription)
        }
    }

    /// Forwards a native `MeldError` to JS, including `detail` for parity with the native struct.
    private func send(error e: MeldError) {
        onError?([
            "orderId": e.orderId ?? "",
            "code": e.code,
            "message": e.message,
            "detail": e.detail ?? "",
            "recoverable": e.recoverable,
        ])
    }

    private func emitError(code: String, message: String) {
        send(error: MeldError(orderId: nil, code: code, message: message, recoverable: false))
    }

    override func removeFromSuperview() {
        handle?.unmount() // teardown when RN removes the component
        handle = nil
        super.removeFromSuperview()
    }
}
