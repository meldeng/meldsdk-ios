import CoreFoundation
import Foundation

/// Provider-neutral recovery advice. Never authorizes a new order or automatic mutation replay.
public struct MeldHeadlessError: Equatable, Sendable {
    public enum Category: String, Sendable {
        case invalidRequest = "INVALID_REQUEST", authenticationRequired = "AUTHENTICATION_REQUIRED"
        case accessDenied = "ACCESS_DENIED", notFound = "NOT_FOUND", unsupportedProtocol = "UNSUPPORTED_PROTOCOL"
        case requirementRequired = "REQUIREMENT_REQUIRED", requirementPending = "REQUIREMENT_PENDING"
        case requirementBlocked = "REQUIREMENT_BLOCKED", orderRejected = "ORDER_REJECTED"
        case requestConflict = "REQUEST_CONFLICT", operationInFlight = "OPERATION_IN_FLIGHT", stateChanged = "STATE_CHANGED"
        case dependencyUnavailable = "DEPENDENCY_UNAVAILABLE", outcomeUnknown = "OUTCOME_UNKNOWN"
    }

    public enum Recovery: String, Sendable {
        case correctRequest = "CORRECT_REQUEST", authenticate = "AUTHENTICATE"
        case readRequirements = "READ_REQUIREMENTS", readState = "READ_STATE", retryRead = "RETRY_READ", stop = "STOP"
    }

    public let version = 1
    public let category: Category
    public let recovery: Recovery
    public let automaticRetryAllowed = false

    static func decode(_ value: Any?, operation: String) -> Self? {
        guard let json = value as? [String: Any], PaymentActionJSON.integer(json["version"]) == 1,
              let retry = json["automaticRetryAllowed"] as? NSNumber,
              CFGetTypeID(retry) == CFBooleanGetTypeID(), !retry.boolValue,
              let rawCategory = json["category"] as? String, let category = Category(rawValue: rawCategory),
              let rawRecovery = json["recovery"] as? String, let recovery = Recovery(rawValue: rawRecovery)
        else { return nil }
        let allowed: Bool
        switch (category, recovery) {
        case (.invalidRequest, .correctRequest), (.authenticationRequired, .authenticate),
             (.accessDenied, .stop), (.notFound, .stop), (.unsupportedProtocol, .readRequirements),
             (.requirementRequired, .readRequirements), (.requirementPending, .readState),
             (.requirementBlocked, .stop), (.orderRejected, .stop), (.requestConflict, .readState),
             (.operationInFlight, .readState), (.stateChanged, .readState),
             (.dependencyUnavailable, .readState), (.outcomeUnknown, .readState): allowed = true
        case (.dependencyUnavailable, .retryRead): allowed = isRead(operation)
        default: allowed = false
        }
        return allowed ? Self(category: category, recovery: recovery) : nil
    }

    static func fallback(_ operation: String) -> Self {
        isRead(operation) ? Self(category: .dependencyUnavailable, recovery: .retryRead)
            : Self(category: .outcomeUnknown, recovery: .readState)
    }

    private static func isRead(_ operation: String) -> Bool {
        // Idempotency-key requirements and a READ_ prefix do not establish read-only semantics.
        ["READ_SUBMISSION", "READ_CUSTOMER_STATUS", "READ_LIMITS", "READ_LEGAL_DISCLOSURE"].contains(operation)
    }

    static func from(_ error: Error) -> Self? {
        guard case PaymentActionError.headless(let advice) = error else { return nil }
        return advice
    }

    static func failure(_ error: Error, operation: String) -> PaymentActionError {
        .headless(from(error) ?? fallback(operation))
    }
}
