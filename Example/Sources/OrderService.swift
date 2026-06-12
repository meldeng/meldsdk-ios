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

    // Fixed corridor for the demo: 15 USD -> BTC, US, Mercuryo card.
    static let sourceAmount = "15"
    static let sourceCurrency = "USD"
    static let destinationCurrency = "BTC"
    static let country = "US"
    static let defaultWallet = "bc1qr74wmrcwqq9w5yxczxj6udts9mnqsh3xlhk5yp"

    /// Resolve a credential: scheme env var first (handy for CI), then the value injected from
    /// Secrets.xcconfig via Info.plist. An empty or unresolved `$(...)` placeholder reads as "".
    private static func secret(env: String, info: String) -> String {
        if let v = ProcessInfo.processInfo.environment[env], !v.isEmpty { return v }
        if let v = Bundle.main.object(forInfoDictionaryKey: info) as? String,
           !v.isEmpty, !v.hasPrefix("$(") { return v }
        return ""
    }
}

struct DemoQuote {
    let destinationAmount: Double?
    let totalFee: Double?
    let exchangeRate: Double?
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

    /// `POST /payments/crypto/quote?integrationMode=HEADLESS` — the live quote for the corridor.
    func quote() async throws -> DemoQuote {
        let (data, _) = try await post("/payments/crypto/quote?integrationMode=HEADLESS", [
            "countryCode": DemoConfig.country,
            "sourceAmount": DemoConfig.sourceAmount,
            "sourceCurrencyCode": DemoConfig.sourceCurrency,
            "destinationCurrencyCode": DemoConfig.destinationCurrency,
            "paymentMethodType": "CREDIT_DEBIT_CARD",
            "serviceProviders": ["MERCURYO"],
        ])
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let quote = (json?["quotes"] as? [[String: Any]])?.first else {
            throw demoError(json?["message"] as? String ?? "no quotes returned")
        }
        return DemoQuote(
            destinationAmount: quote["destinationAmount"] as? Double,
            totalFee: quote["totalFee"] as? Double,
            exchangeRate: quote["exchangeRate"] as? Double)
    }

    /// `POST /crypto/order/headless` — returns the raw order JSON to hand to `MeldOrder.from`.
    /// `paymentMethodType` is `CREDIT_DEBIT_CARD` (embedded widget) or `APPLE_PAY` (native sheet);
    /// the SDK reads the right surface off the response either way.
    func createOrder(
        customerId: String,
        wallet: String,
        clientIP: String?,
        paymentMethodType: String = "CREDIT_DEBIT_CARD"
    ) async throws -> Data {
        var body: [String: Any] = [
            "customerId": customerId,
            "externalOrderId": "ios-demo-\(Int(Date().timeIntervalSince1970 * 1000))",
            "sessionType": "BUY",
            "serviceProvider": "MERCURYO",
            "paymentMethodType": paymentMethodType,
            "sourceCurrencyCode": DemoConfig.sourceCurrency,
            "sourceAmount": DemoConfig.sourceAmount,
            "destinationCurrencyCode": DemoConfig.destinationCurrency,
            "destinationWalletAddress": wallet,
            "countryCode": DemoConfig.country,
        ]
        if let clientIP { body["clientIpAddress"] = clientIP }

        let (data, http) = try await post("/crypto/order/headless", body)
        guard (200..<300).contains(http.statusCode) else { // headless order returns 201 Created
            let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = info?["code"] as? String ?? String(http.statusCode)
            let message = info?["message"] as? String ?? "order creation failed"
            throw demoError("\(code) — \(message)")
        }
        return data
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
