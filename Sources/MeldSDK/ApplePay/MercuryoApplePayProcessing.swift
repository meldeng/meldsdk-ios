import Foundation

// Native Apple Pay processing for Mercuryo. The SDK presents the PassKit sheet, then drives the
// order's session-scoped endpoint `POST /crypto/session/mercuryo/apple-pay/process`, authenticated
// with the order's `sessionToken` (no API key reaches the client). Unlike the web ApplePaySession
// flow, native PassKit performs merchant validation in the OS, so the SDK never calls
// `validate-merchant` or `paymentsession` — only `/process`.
//
// The body building and response interpretation are pure (no PassKit / network), so they're unit
// tested directly; the coordinator only adapts PassKit objects into these calls.

/// Builds the JSON body for the Mercuryo native Apple Pay `/process` request. Keys are the
/// snake_case wire names the backend expects. `buy_token` is intentionally omitted — the server
/// fills it from the session bound to the token.
enum ApplePayProcessBody {
    struct BillingAddress {
        let countryCode: String?
        let streetLine1: String?
        let streetLine2: String?
        let stateCode: String?
        let city: String?
        let zipCode: String?

        var isEmpty: Bool {
            [countryCode, streetLine1, streetLine2, stateCode, city, zipCode]
                .allSatisfy { ($0 ?? "").isEmpty }
        }
    }

    static func make(
        payTokenBase64: String,
        merchantTransactionId: String,
        walletAddress: String,
        clientIpAddress: String,
        firstName: String,
        lastName: String,
        email: String?,
        billing: BillingAddress?
    ) -> [String: Any] {
        var body: [String: Any] = [
            "pay_token": payTokenBase64,
            "first_name": firstName,
            "last_name": lastName,
            "address": walletAddress,
            "ip": clientIpAddress,
            "merchant_transaction_id": merchantTransactionId,
        ]
        if let email, !email.isEmpty { body["email"] = email }
        if let billing, !billing.isEmpty {
            var address: [String: Any] = [:]
            if let v = billing.countryCode, !v.isEmpty { address["country_code"] = v }
            if let v = billing.streetLine1, !v.isEmpty { address["street_line_1"] = v }
            if let v = billing.streetLine2, !v.isEmpty { address["street_line_2"] = v }
            if let v = billing.stateCode, !v.isEmpty { address["state_code"] = v }
            if let v = billing.city, !v.isEmpty { address["city"] = v }
            if let v = billing.zipCode, !v.isEmpty { address["zip_code"] = v }
            body["billing_address"] = address
        }
        return body
    }
}

/// The verdict of interpreting a `/process` response: the Meld events to relay, plus whether the
/// PassKit sheet should report success or failure to the user.
struct ApplePayProcessOutcome {
    let events: [MeldEvent]
    /// `true` → `PKPaymentAuthorizationResult(.success)`; `false` → `.failure`.
    let succeeded: Bool
}

/// Maps a `/process` response onto Meld events. A transport-level failure is surfaced by the
/// caller as `.error` before this runs; here we interpret a delivered HTTP response body.
enum ApplePayResponseInterpreter {
    // Mercuryo's status vocabulary -> the SDK's normalized set, mirroring MercuryoCardAdapter.
    // Interim/unknown codes collapse to `.pending` (settlement is the webhook, never the client).
    private static let statusMap: [String: MeldStatus] = [
        "paid": .completed, "completed": .completed, "order_completed": .completed,
        "succeeded": .completed, "success": .completed,
        "failed": .failed, "order_failed": .failed, "failed_exchange": .failed,
        "descriptor_failed": .failed, "rejected": .failed,
        "cancelled": .cancelled, "canceled": .cancelled,
    ]

    static func normalize(_ code: String?) -> MeldStatus {
        guard let code, !code.isEmpty else { return .pending }
        return statusMap[code.lowercased()] ?? .pending
    }

    static func interpret(httpStatus: Int, json: [String: Any]?, orderId: String?) -> ApplePayProcessOutcome {
        // Mercuryo echoes its own status/code in the body; the body is authoritative over the
        // transport status. Treat a non-2xx transport status OR a provider error code as a failure.
        let providerStatus = json?["status"] as? Int
        let providerCode = json?["code"] as? String
        let data = json?["data"] as? [String: Any]

        let transportFailed = !(200..<300).contains(httpStatus)
        let providerFailed = (providerStatus.map { !(200..<300).contains($0) } ?? false)
            || (providerCode?.isEmpty == false)

        if transportFailed || providerFailed {
            let error = MeldError(
                orderId: orderId,
                code: "PAYMENT_NOT_ACCEPTED",
                message: "The payment was not accepted. Review the existing order before starting another payment.",
                recoverable: false)
            return ApplePayProcessOutcome(events: [.error(error)], succeeded: false)
        }

        // Accepted by the provider. `paymentSubmitted` is the UX hint that the user finished the
        // flow; the normalized status drives the rest. A terminal failed/cancelled status that
        // still arrives on a 2xx is mapped through the same rules as the card adapter.
        let rawStatus = (data?["status"] as? String) ?? (data?["payment_status"] as? String)
        guard let rawStatus, statusMap[rawStatus.lowercased()] != nil
                || ["new", "pending", "created", "processing"].contains(rawStatus.lowercased()) else {
            return ApplePayProcessOutcome(events: [.error(MeldError(orderId: orderId, code: "PAYMENT_OUTCOME_UNKNOWN",
                message: "Payment outcome is unknown. Track the existing order without submitting again.",
                recoverable: false))], succeeded: false)
        }
        let status = normalize(rawStatus)
        var events: [MeldEvent] = [
            .statusChange(MeldStatusChange(
                orderId: orderId, status: status, providerStatus: statusMap[rawStatus.lowercased()] != nil ? rawStatus : nil, raw: nil)),
        ]
        switch status {
        case .failed:
            events.append(.error(MeldError(
                orderId: orderId, code: rawStatus,
                message: "The provider reported a failed payment attempt. Review the existing order.",
                recoverable: false)))
            return ApplePayProcessOutcome(events: events, succeeded: false)
        case .cancelled:
            events.append(.cancel)
            return ApplePayProcessOutcome(events: events, succeeded: false)
        default:
            events.insert(.paymentSubmitted, at: 0)
            return ApplePayProcessOutcome(events: events, succeeded: true)
        }
    }
}

/// Thin client for the session-scoped `/process` endpoint on Meld's public crypto API. Auth is the
/// order's `sessionToken` in the `X-Crypto-Session-Token` header — the SDK never holds an API key.
final class MercuryoApplePayClient {
    static let processPath = "/crypto/session/mercuryo/apple-pay/process"
    static let tokenHeader = "X-Crypto-Session-Token"

    let environment: MeldEnvironment
    let sessionToken: String
    private let urlSession: URLSession

    init(environment: MeldEnvironment, sessionToken: String) {
        self.environment = environment
        self.sessionToken = sessionToken
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        urlSession = URLSession(configuration: configuration, delegate: PaymentActionRedirectPolicy(), delegateQueue: nil)
    }

    func finish() { urlSession.finishTasksAndInvalidate() }
    deinit { urlSession.finishTasksAndInvalidate() }

    /// Public crypto API host per environment (same host integrators hit for `/crypto/order/headless`).
    static func baseURL(for environment: MeldEnvironment) -> String {
        switch environment {
        case .sandbox: return "https://api-sb.meld.io"
        case .qa: return "https://api-qa.meld.io"
        case .production: return "https://api.meld.io"
        }
    }

    /// POST the process body. On a delivered HTTP response, returns `(status, parsedJSON)`. A
    /// transport/encoding failure returns `.failure`; callers must not retry an ambiguous payment.
    func process(body: [String: Any], completion: @escaping (Result<(Int, [String: Any]?), Error>) -> Void) {
        guard let url = URL(string: Self.baseURL(for: environment) + Self.processPath) else {
            completion(.failure(MeldApplePayError.processingFailed("Invalid Apple Pay process URL")))
            return
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(sessionToken, forHTTPHeaderField: Self.tokenHeader)
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(MeldApplePayError.processingFailed("Failed to encode process body")))
            return
        }
        urlSession.dataTask(with: request) { data, response, error in
            if error != nil {
                completion(.failure(PaymentActionError.transport))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            completion(.success((status, json)))
        }.resume()
    }
}
