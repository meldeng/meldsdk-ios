import Foundation

/// The adapter interprets normalized actions; shared HTTP transport does not interpret SDK secrets.
struct StripeActionResponse: CustomStringConvertible {
    let status: String
    let next: String
    let session: String?
    private let secret: String?
    private let expiresAt: Date?
    let missingFields: [String]
    var description: String { "StripeActionResponse[REDACTED]" }

    init(_ value: [String: Any]) throws {
        guard PaymentActionJSON.integer(value["version"]) == 1,
              let status = value["status"] as? String, Self.statuses.contains(status),
              let next = value["nextStep"] as? String, Self.steps.contains(next)
        else { throw StripeNativeError.invalidResponse }
        self.status = status; self.next = next
        if let raw = value["sdk"] {
            guard let sdk = raw as? [String: Any] else { throw StripeNativeError.invalidResponse }
            if let raw = sdk["sessionHandle"] {
                guard let parsed = StripeNativeValue.identifier(raw, prefix: "cos_") else { throw StripeNativeError.invalidResponse }
                session = parsed
            } else { session = nil }
            if let raw = sdk["clientSecret"] {
                guard let parsed = StripeNativeValue.text(raw, limit: 4096) else { throw StripeNativeError.invalidResponse }
                secret = parsed
            } else { secret = nil }
            if let raw = sdk["expiresAt"] {
                guard let raw = raw as? String, let date = Self.date(raw) else { throw StripeNativeError.invalidResponse }
                expiresAt = date
            } else { expiresAt = nil }
        } else { session = nil; secret = nil; expiresAt = nil }
        if let raw = value["customer"] {
            guard let customer = raw as? [String: Any], let fields = customer["missingFields"] as? [String],
                  fields.allSatisfy(Self.fields.contains), Set(fields).count == fields.count
            else { throw StripeNativeError.invalidResponse }
            missingFields = fields
        } else { missingFields = [] }
    }

    func authenticationSecret(now: Date = Date()) throws -> String {
        guard status == "READY", next == "SDK_AUTHORIZE", session == nil,
              let secret, let expiresAt, expiresAt > now else { throw StripeNativeError.invalidResponse }
        return secret
    }

    func checkoutSecret(session expected: String, now: Date = Date()) throws -> String {
        guard session == expected, let secret, expiresAt.map({ $0 > now }) ?? true,
              ["REQUIRES_PAYMENT", "QUOTE_READY", "FULFILLMENT_PROCESSING", "FULFILLMENT_COMPLETE", "SUCCEEDED"].contains(status),
              ["CONFIRM_PAYMENT", "NONE", "COMPLETE"].contains(next)
        else { throw StripeNativeError.invalidResponse }
        return secret
    }

    enum Submission: Equatable {
        case notStarted, resumeSession(String), inProgress, submitted, completed, failed, expired, unknown
    }

    func submission() throws -> Submission {
        guard secret == nil, expiresAt == nil else { throw StripeNativeError.invalidResponse }
        switch (status, next) {
        case ("READY", "REFRESH_QUOTE"):
            guard let session else { throw StripeNativeError.invalidResponse }; return .resumeSession(session)
        case ("NOT_STARTED", "NONE") where session == nil: return .notStarted
        case ("IN_PROGRESS", "WAIT_FOR_PROVIDER") where session == nil: return .inProgress
        case ("SUBMITTED", "WAIT_FOR_PAYMENT") where session == nil: return .submitted
        case ("SUCCEEDED", "COMPLETE") where session == nil: return .completed
        case ("FAILED", "NONE") where session == nil: return .failed
        case ("REJECTED", "NONE") where session == nil: return .failed
        case ("EXPIRED", "NONE") where session == nil: return .expired
        case ("UNKNOWN", "WAIT_FOR_PROVIDER") where session == nil: return .unknown
        default: throw StripeNativeError.invalidResponse
        }
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: value) { return parsed }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static let statuses: Set<String> = ["READY", "NOT_STARTED", "PENDING", "AUTHORIZED", "VERIFIED", "REJECTED",
        "NOT_AVAILABLE", "UNKNOWN", "REQUIRES_PAYMENT", "QUOTE_READY", "FULFILLMENT_PROCESSING", "FULFILLMENT_COMPLETE",
        "SUCCEEDED", "FAILED", "SUBMITTED", "IN_PROGRESS", "EXPIRED"]
    private static let steps: Set<String> = ["NONE", "SDK_AUTHORIZE", "SDK_REAUTHORIZE", "SDK_COLLECT_KYC",
        "SDK_VERIFY_IDENTITY", "SDK_REGISTER_WALLET", "SDK_COLLECT_PAYMENT_METHOD", "CREATE_PAYMENT_SESSION",
        "REFRESH_QUOTE", "CONFIRM_PAYMENT", "RETRY", "COMPLETE", "REGION_NOT_SUPPORTED", "START_NEW_ORDER",
        "WAIT_FOR_PAYMENT", "WAIT_FOR_PROVIDER", "UNKNOWN"]
    private static let fields: Set<String> = ["FIRST_NAME", "LAST_NAME", "DATE_OF_BIRTH", "ID_NUMBER", "ADDRESS_LINE_1",
        "ADDRESS_CITY", "ADDRESS_STATE", "ADDRESS_POSTAL_CODE", "ADDRESS_COUNTRY", "ID_DOCUMENT", "SELFIE"]
}
