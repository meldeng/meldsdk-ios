import Foundation

enum CoinmeCardError: Error { case invalidOrder }

/// Validated `VENDOR_SDK / COINME_VAULT / 1` card order. Descriptions never expose tokens or customer ids.
struct CoinmeCardOrder: CustomStringConvertible {
    let id: String
    /// Coinme `live`; otherwise its `sandbox`.
    let live: Bool
    let actions: PaymentActionDescriptor
    var description: String { "CoinmeCardOrder[REDACTED]" }

    static let operations = ["CREATE_CUSTOMER_AUTH_TOKEN": true, "CREATE_PAYMENT_SESSION": true]

    init(_ order: MeldOrder, environment: MeldEnvironment) throws {
        guard let presentation = order.headlessPresentation,
              presentation.surface == "VENDOR_SDK", presentation.protocolName == "COINME_VAULT",
              presentation.version == 1, order.paymentMethodType == "CREDIT_DEBIT_CARD",
              let id = order.id, !id.isEmpty,
              let details = order.paymentMethodResponseDetails?.raw,
              Self.token(details["sdkSessionToken"]) != nil,
              let data = details["sdkSessionData"] as? [String: Any],
              ["customerId", "paymentProviderId", "riskClientId", "riskPartnerId"].allSatisfy({ Self.token(data[$0]) != nil }),
              let coinmeEnvironment = data["environment"] as? String, ["sandbox", "live"].contains(coinmeEnvironment),
              (environment == .production) == (coinmeEnvironment == "live"),
              data["savedCards"] == nil || data["savedCards"] is [Any]
        else { throw CoinmeCardError.invalidOrder }
        let actions = try PaymentActionDescriptor(order: order, environment: environment)
        guard Self.operations.allSatisfy({ actions.operations[$0.key] == $0.value }) else { throw CoinmeCardError.invalidOrder }
        self.id = id
        live = coinmeEnvironment == "live"
        self.actions = actions
    }

    /// Ids and tokens travel in headers and JSON bodies: printable ASCII, no spaces.
    static func token(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 16384,
              text.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else { return nil }
        return text
    }
}
