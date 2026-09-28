import Foundation

/// Normalized `MeldError.code` values. The provider's own event and code travel in `detail`.
enum MeldErrorCode {
    /// No attempt exists. Offer hosted checkout or another method.
    static let applePayUnavailable = "APPLE_PAY_UNAVAILABLE"
    /// No attempt exists. The next attempt needs a new order.
    static let presentationFailed = "PRESENTATION_FAILED"
    /// Declined; nothing will settle. Offer another option.
    static let paymentRejected = "PAYMENT_REJECTED"
    /// No attempt exists. The provider no longer accepts this order.
    static let orderStateChanged = "ORDER_STATE_CHANGED"
    /// No attempt exists. The provider is reviewing the customer.
    static let verificationPending = "VERIFICATION_PENDING"
    /// An attempt may exist. Track the order and never pay it again.
    static let paymentOutcomeUnknown = "PAYMENT_OUTCOME_UNKNOWN"
    /// Reserved.
    static let providerUnavailable = "PROVIDER_UNAVAILABLE"
}
