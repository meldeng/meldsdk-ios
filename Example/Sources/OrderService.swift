import Foundation

// ⚠️ POC ONLY — DO NOT SHIP.
// This file talks to the Meld API directly, which puts your API key in the app binary. In a
// real app, quote/order creation happens on YOUR backend (the key never reaches the client);
// the app just receives the order JSON and hands it to MeldSDK. The SDK itself is frontend-only
// and never sees the key.

// MARK: - Config

enum DemoConfig {
    // Credentials come from Secrets.xcconfig (via Info.plist) or a scheme env var. Never hardcoded.
    static var meldApiKey: String { secret(env: "MELD_API_KEY", info: "MeldApiKey") }
    static var meldCustomerId: String { secret(env: "MELD_CUSTOMER_ID", info: "MeldCustomerId") }

    /// API host. Defaults to sandbox; set MELD_API_HOST (e.g. `api-qa.meld.io`) for another env.
    /// Host only, no scheme — `https://` would be eaten by xcconfig's `//` comment syntax.
    static var apiBase: String {
        let host = secret(env: "MELD_API_HOST", info: "MeldApiHost")
        return "https://\(host.isEmpty ? "api-sb.meld.io" : host)"
    }

    static let version = "2026-05-01"

    // Corridor for the demo. Defaults to a EU corridor (15 EUR -> BTC, FR) because Mercuryo's
    // native Apple Pay does NOT process US/GB users or US/GB-issued cards — a US corridor can never
    // complete via Apple Pay. Override per your account via Secrets.xcconfig (MELD_COUNTRY etc.):
    // the Uphold card demo wants a US corridor (USD -> USDC, US, an 0x wallet), so set
    // MELD_SOURCE_CURRENCY/MELD_DEST_CURRENCY/MELD_COUNTRY/MELD_WALLET when exercising that one.
    static let sourceAmount = "15"
    static var sourceCurrency: String { setting(env: "MELD_SOURCE_CURRENCY", info: "MeldSourceCurrency", default: "EUR") }
    static var destinationCurrency: String { setting(env: "MELD_DEST_CURRENCY", info: "MeldDestCurrency", default: "BTC") }
    static var country: String { setting(env: "MELD_COUNTRY", info: "MeldCountry", default: "FR") }
    static var defaultWallet: String {
        setting(env: "MELD_WALLET", info: "MeldWallet", default: "bc1qr74wmrcwqq9w5yxczxj6udts9mnqsh3xlhk5yp")
    }

    /// Two-letter country code rendered as a flag emoji (regional-indicator symbols).
    static var countryFlag: String {
        country.uppercased().unicodeScalars
            .compactMap { UnicodeScalar(127_397 + $0.value).map(String.init) }
            .joined()
    }

    /// Apple Pay merchant id used for the Simulator preview / device test — must match
    /// `MeldDemo.entitlements` (and, for a real device, an account whose `merchant.io.meld` Apple Pay
    /// cert Mercuryo holds). Used as a demo-only fallback when the backend doesn't surface one (see
    /// `OrderService.injectingMerchantIdIfMissing`).
    static let applePayMerchantId = "merchant.io.meld"

    /// Resolve a credential: scheme env var first (handy for CI), then the value injected from
    /// Secrets.xcconfig via Info.plist. An empty or unresolved `$(...)` placeholder reads as "".
    private static func secret(env: String, info: String) -> String {
        if let v = ProcessInfo.processInfo.environment[env], !v.isEmpty { return v }
        if let v = Bundle.main.object(forInfoDictionaryKey: info) as? String,
           !v.isEmpty, !v.hasPrefix("$(") { return v }
        return ""
    }

    /// Like `secret`, but falls back to `def` when unset — for optional corridor settings.
    private static func setting(env: String, info: String, default def: String) -> String {
        let v = secret(env: env, info: info)
        return v.isEmpty ? def : v
    }
}

struct DemoQuote: Identifiable {
    var id: String { serviceProvider }
    let serviceProvider: String
    let destinationAmount: Double?
    let totalFee: Double?
    let exchangeRate: Double?
    let kycMode: String?
}

// MARK: - Backend calls (in a real app, these live on your server)

struct OrderService {
    /// The order's `clientIpAddress` must match the IP the WebView egresses on — Mercuryo binds
    /// the widget signature to it — so discover the device's public IP and pass it on the order.
    func publicIP() async -> String? {
        for host in ["https://api64.ipify.org?format=json", "https://api.ipify.org?format=json"] {
            guard let url = URL(string: host),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ip = json["ip"] as? String
            else { continue }
            return ip
        }
        return nil
    }

    /// `POST /payments/crypto/quote?integrationMode=HEADLESS` — one quote per headless-capable provider
    /// for the corridor (no `serviceProviders` filter), so the user can pick which provider to use.
    func quotes() async throws -> [DemoQuote] {
        // Headless providers that quote on-behalf-of a customer (e.g. Uphold) require the customer id
        // on the quote itself, so the provider can resolve that customer's service-provider identity.
        var body: [String: Any] = [
            "countryCode": DemoConfig.country,
            "sourceAmount": DemoConfig.sourceAmount,
            "sourceCurrencyCode": DemoConfig.sourceCurrency,
            "destinationCurrencyCode": DemoConfig.destinationCurrency,
            "paymentMethodType": "CREDIT_DEBIT_CARD",
        ]
        if !DemoConfig.meldCustomerId.isEmpty { body["customerId"] = DemoConfig.meldCustomerId }
        let (data, _) = try await post("/payments/crypto/quote?integrationMode=HEADLESS", body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let rawQuotes = json?["quotes"] as? [[String: Any]], !rawQuotes.isEmpty else {
            throw demoError(json?["message"] as? String ?? "no quotes returned")
        }
        return rawQuotes.compactMap { quote in
            guard let provider = quote["serviceProvider"] as? String else { return nil }
            return DemoQuote(
                serviceProvider: provider,
                destinationAmount: quote["destinationAmount"] as? Double,
                totalFee: quote["totalFee"] as? Double,
                exchangeRate: quote["exchangeRate"] as? Double,
                kycMode: quote["kycMode"] as? String)
        }
    }

    /// `POST /crypto/order/headless/onramp` — returns the raw order JSON to hand to `MeldOrder.from`.
    /// `serviceProvider` is whichever quote the user selected; `paymentMethodType` is
    /// `CREDIT_DEBIT_CARD` (embedded widget) or `APPLE_PAY`. The SDK reads the right surface off
    /// the response either way — which of the two Apple Pay shapes it gets is the provider's
    /// business, not the caller's.
    func createOrder(
        serviceProvider: String,
        customerId: String,
        wallet: String,
        clientIP: String?,
        paymentMethodType: String = "CREDIT_DEBIT_CARD"
    ) async throws -> Data {
        var body: [String: Any] = [
            "customerId": customerId,
            "externalOrderId": "ios-demo-\(Int(Date().timeIntervalSince1970 * 1000))",
            "serviceProvider": serviceProvider,
            "paymentMethodType": paymentMethodType,
            "sourceCurrencyCode": DemoConfig.sourceCurrency,
            "sourceAmount": DemoConfig.sourceAmount,
            "destinationCurrencyCode": DemoConfig.destinationCurrency,
            "destinationWalletAddress": wallet,
            "countryCode": DemoConfig.country,
        ]
        if let clientIP { body["clientIpAddress"] = clientIP }

        let (data, http) = try await post("/crypto/order/headless/onramp", body)
        guard (200..<300).contains(http.statusCode) else { // headless order returns 201 Created
            let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = info?["code"] as? String ?? String(http.statusCode)
            let message = info?["message"] as? String ?? "order creation failed"
            throw demoError("\(code) — \(message)")
        }
        return data
    }

    /// demo-only: the sandbox/QA backend may not yet surface `merchantIdentifier` on Apple Pay
    /// orders (it's added by a pending backend change). For the Simulator preview, inject a
    /// placeholder — the same id as the app's Apple Pay entitlement — when the order doesn't carry
    /// one, so the sheet can present. A real Apple-Pay-configured account returns its own
    /// `merchantIdentifier` and this leaves the order untouched. Not something a real app does.
    static func injectingMerchantIdIfMissing(_ orderJSON: Data, _ merchantId: String) -> Data {
        guard var dict = (try? JSONSerialization.jsonObject(with: orderJSON)) as? [String: Any],
              var details = dict["paymentMethodResponseDetails"] as? [String: Any],
              (details["merchantIdentifier"] as? String)?.isEmpty != false
        else { return orderJSON }
        details["merchantIdentifier"] = merchantId
        dict["paymentMethodResponseDetails"] = details
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? orderJSON
    }

    private func post(_ path: String, _ body: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: DemoConfig.apiBase + path)!)
        request.httpMethod = "POST"
        request.setValue("BASIC \(DemoConfig.meldApiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(DemoConfig.version, forHTTPHeaderField: "Meld-Version")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Idempotency-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, response as! HTTPURLResponse)
    }

    private func demoError(_ message: String) -> NSError {
        NSError(domain: "MeldDemo", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
