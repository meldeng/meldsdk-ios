import CoreFoundation
import Foundation
import PassKit
import StripeCore

enum StripeNativeError: Error {
    case invalidOrder, invalidResponse, unavailable, busy, cancelled, authorizationRequired, actionRequired
}

/// Validated inputs for the native adapter. Descriptions never expose customer or SDK credentials.
struct StripeNativeOrder: CustomStringConvertible {
    let id: String
    let method: String
    let intent: String
    let flow: String
    let expiresAt: Date
    let publicKey: String
    let walletNetwork: String
    let walletAddress: String
    let merchantIdentifier: String?
    let amount: Decimal
    let actions: PaymentActionDescriptor
    var description: String { "StripeNativeOrder[REDACTED]" }

    init(_ order: MeldOrder, environment: MeldEnvironment) throws {
        guard let presentation = order.headlessPresentation,
              presentation.surface == "NATIVE_SDK", presentation.protocolName == "STRIPE_CRYPTO_ONRAMP",
              presentation.version == 1,
              let id = StripeNativeValue.text(order.id, limit: 64),
              let method = order.paymentMethodType, ["APPLE_PAY", "CREDIT_DEBIT_CARD"].contains(method),
              let details = order.paymentMethodResponseDetails?.raw,
              details["sdkBootstrapType"] as? String == "STRIPE_CRYPTO_ONRAMP",
              let intent = StripeNativeValue.identifier(details["providerIntentId"], prefix: "lai_"),
              let flow = details["sdkFlow"] as? String, ["AUTHORIZE", "SEAMLESS"].contains(flow),
              let expiry = PaymentActionJSON.integer(details["expiresAtEpochSeconds"]), expiry > 0,
              let sdkEnvironment = details["sdkEnvironment"] as? String,
              ["SANDBOX", "DEVELOPMENT", "PRODUCTION"].contains(sdkEnvironment),
              (environment == .production) == (sdkEnvironment == "PRODUCTION"),
              let configuration = details["clientConfiguration"] as? [String: Any],
              let publicKey = StripeNativeValue.text(configuration["publicKey"], limit: 255),
              StripeNativeValue.matches(publicKey, "pk_\(sdkEnvironment == "PRODUCTION" ? "live" : "test")_[A-Za-z0-9]+"),
              let network = configuration["walletNetwork"] as? String, Self.networks.contains(network),
              let payload = order.raw["payload"] as? [String: Any],
              payload["sourceCurrencyCode"] as? String == "USD", payload["countryCode"] as? String == "US",
              let wallet = StripeNativeValue.text(payload["destinationWalletAddress"], limit: 255),
              let amount = StripeNativeValue.amount(payload["sourceAmount"])
        else { throw StripeNativeError.invalidOrder }
        let merchant: String?
        if method == "APPLE_PAY" {
            guard let value = StripeNativeValue.text(configuration["merchantIdentifier"], limit: 255),
                  StripeNativeValue.matches(value, "merchant\\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*")
            else { throw StripeNativeError.invalidOrder }
            merchant = value
        } else { merchant = nil }
        let actions = try PaymentActionDescriptor(order: order, environment: environment)
        let required = ["READ_SUBMISSION": false, "READ_CUSTOMER_STATUS": false, "READ_LIMITS": false,
                        "COMPLETE_CUSTOMER_LINK": true, "CREATE_CUSTOMER_AUTH_TOKEN": true,
                        "PREPARE_CUSTOMER_AUTHORIZATION": true,
                        "READ_LEGAL_DISCLOSURE": false, "RECORD_LEGAL_EVIDENCE": true,
                        "CREATE_PAYMENT_SESSION": true, "CONFIRM_PAYMENT": true, "REFRESH_QUOTE": true]
        guard required.allSatisfy({ actions.operations[$0.key] == $0.value }) else { throw StripeNativeError.invalidOrder }
        self.id = id; self.method = method; self.intent = intent; self.flow = flow
        expiresAt = Date(timeIntervalSince1970: TimeInterval(expiry))
        self.publicKey = publicKey; walletNetwork = network; walletAddress = wallet
        merchantIdentifier = merchant; self.amount = amount; self.actions = actions
    }

    /// This request represents the order's fee-inclusive total, already bound on the server.
    func paymentRequest(_ input: MeldApplePayRequest? = nil) throws -> PKPaymentRequest {
        guard method == "APPLE_PAY", let merchantIdentifier,
              input == nil || (input?.amount == amount && input?.currencyCode == "USD")
        else { throw StripeNativeError.invalidOrder }
        let label = input?.summaryItemLabel ?? "Crypto purchase"
        guard StripeNativeValue.text(label, limit: 128) != nil else { throw StripeNativeError.invalidOrder }
        let request = StripeAPI.paymentRequest(withMerchantIdentifier: merchantIdentifier, country: "US", currency: "USD")
        request.requiredBillingContactFields = [.name, .postalAddress]
        request.requiredShippingContactFields = [.emailAddress]
        request.paymentSummaryItems = [PKPaymentSummaryItem(label: label, amount: NSDecimalNumber(decimal: amount))]
        return request
    }

    private static let networks: Set<String> = ["bitcoin", "ethereum", "solana", "polygon", "stellar", "avalanche",
                                               "base", "aptos", "optimism", "worldchain", "xrpl", "sui", "arbitrum", "tempo"]
}

enum StripeNativeValue {
    static func text(_ value: Any?, limit: Int) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= limit,
              text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              text.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return nil }
        return text
    }

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: "\\A(?:" + pattern + ")\\z", options: .regularExpression) != nil
    }

    static func identifier(_ value: Any?, prefix: String) -> String? {
        guard let text = text(value, limit: 255), matches(text, prefix + "[A-Za-z0-9_]+") else { return nil }
        return text
    }

    static func amount(_ value: Any?) -> Decimal? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              let decimal = Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX")),
              decimal > 0 else { return nil }
        var original = decimal, rounded = Decimal()
        NSDecimalRound(&rounded, &original, 2, .plain)
        return rounded == decimal ? decimal : nil
    }
}

/// One actual SDK checkout callback owns one pair. A failed callback never authorizes an automatic replay.
struct StripeCheckoutInvocation: CustomStringConvertible {
    let callbackID = UUID()
    let idempotencyKey = UUID()
    var fields: [String: Any] { ["callbackInvocationId": callbackID.uuidString.lowercased()] }
    var description: String { "StripeCheckoutInvocation[REDACTED]" }
}
