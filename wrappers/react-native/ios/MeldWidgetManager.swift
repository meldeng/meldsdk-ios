import React
import MeldSDK

/// Exposes the widget view and `Meld.configure` to React Native.
@objc(MeldWidgetManager)
final class MeldWidgetManager: RCTViewManager {
    override func view() -> UIView! { MeldWidgetView() }
    override static func requiresMainQueueSetup() -> Bool { true }

    @objc func configure(_ environment: NSString) {
        Meld.configure(environment: environment == "production" ? .production : .sandbox)
    }

    /// Inspect an order before rendering the widget — bridges to `Meld.capabilities(for:)`.
    @objc func capabilities(_ order: NSDictionary,
                            resolver resolve: @escaping RCTPromiseResolveBlock,
                            rejecter reject: @escaping RCTPromiseRejectBlock) {
        guard let data = try? JSONSerialization.data(withJSONObject: order),
              let parsed = try? MeldOrder.from(jsonData: data) else {
            reject("invalid_order", "Could not parse the order JSON", nil)
            return
        }
        let caps = Meld.capabilities(for: parsed)
        resolve([
            "embeddable": caps.embeddable,
            "surface": caps.surface,
            "requiresUserGesture": caps.requiresUserGesture,
        ])
    }
}
