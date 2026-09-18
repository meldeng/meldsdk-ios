import Foundation

struct WalletActionResponse {
    enum State: String {
        case notStarted = "NOT_STARTED", submitted = "SUBMITTED", verificationRequired = "VERIFICATION_REQUIRED"
        case inProgress = "IN_PROGRESS", unknown = "UNKNOWN", expired = "EXPIRED", failed = "FAILED"
    }
    let state: State
    let verification: WalletVerification?

    init(_ json: [String: Any]) throws {
        guard PaymentActionJSON.integer(json["version"]) == 1,
              let raw = json["status"] as? String, let state = State(rawValue: raw),
              let next = json["nextStep"] as? String else { throw PaymentActionError.invalidResponse }
        let expected: String
        switch state {
        case .notStarted, .failed: expected = "NONE"
        case .submitted, .expired: expected = "WAIT_FOR_PAYMENT"
        case .unknown, .inProgress: expected = "WAIT_FOR_PROVIDER"
        case .verificationRequired: expected = "OPEN_HOSTED_VERIFICATION"
        }
        guard next == expected else { throw PaymentActionError.invalidResponse }
        self.state = state
        if state == .verificationRequired {
            guard let raw = json["verification"] as? [String: Any] else { throw PaymentActionError.invalidResponse }
            self.verification = try WalletVerification(raw)
        } else {
            guard json["verification"] == nil || json["verification"] is NSNull else { throw PaymentActionError.invalidResponse }
            self.verification = nil
        }
    }
}

struct WalletVerification: CustomStringConvertible {
    enum Disposition: String {
        case resume = "RESUME_PAYMENT", replace = "REPLACE_PAYMENT_IN_HOSTED_FLOW"
    }
    let url: URL
    let disposition: Disposition
    let expiresAt: Date
    var description: String { "WalletVerification[REDACTED]" }

    init(_ json: [String: Any]) throws {
        guard let rawURL = json["url"] as? String, let url = URL(string: rawURL),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let rawDisposition = json["paymentDisposition"] as? String,
              let disposition = Disposition(rawValue: rawDisposition),
              let rawDate = json["expiresAt"] as? String else { throw PaymentActionError.invalidResponse }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = formatter.date(from: rawDate)
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = fractional ?? formatter.date(from: rawDate) else { throw PaymentActionError.invalidResponse }
        self.url = url
        self.disposition = disposition
        self.expiresAt = date
    }
}

struct WalletPayment: CustomStringConvertible {
    let token: String
    let firstName: String
    let lastName: String
    let email: String?
    let billing: ApplePayProcessBody.BillingAddress
    var description: String { "WalletPayment[REDACTED]" }

    func actionFields() throws -> [String: Any] {
        guard !token.isEmpty, token.utf8.count <= 49152, Data(base64Encoded: token)?.isEmpty == false,
              let email, valid(email, maximum: 254),
              email.range(of: "\\A[^\\s@]+@[^\\s@]+\\.[^\\s@]+\\z", options: .regularExpression) != nil,
              valid(firstName, maximum: 255), valid(lastName, maximum: 255),
              !billing.isEmpty else { throw PaymentActionError.invalidRequest }
        var address: [String: String] = [:]
        for (name, value, maximum) in [("countryCode", billing.countryCode, 2), ("streetLine1", billing.streetLine1, 255),
                                       ("streetLine2", billing.streetLine2, 255), ("stateCode", billing.stateCode, 128),
                                       ("city", billing.city, 255), ("zipCode", billing.zipCode, 32)] {
            if let value, !value.isEmpty {
                guard valid(value, maximum: maximum) else { throw PaymentActionError.invalidRequest }
                address[name] = value
            }
        }
        if let country = address["countryCode"], country.range(of: "\\A[A-Z]{2}\\z", options: .regularExpression) == nil {
            throw PaymentActionError.invalidRequest
        }
        let fields: [String: Any] = ["walletPayment": ["token": token, "email": email, "firstName": firstName,
                                                      "lastName": lastName, "billingAddress": address]]
        var body = fields
        body["version"] = 1
        body["operation"] = "SUBMIT_WALLET_PAYMENT"
        guard try JSONSerialization.data(withJSONObject: body).count <= 65536 else { throw PaymentActionError.invalidRequest }
        return fields
    }

    private func valid(_ value: String, maximum: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf16.count <= maximum
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}
