import Foundation

/// Normalized `MeldError.code` values. The provider's own event and code travel in `detail`.
public enum MeldErrorCode {
    /// No attempt exists. Offer hosted checkout or another method.
    public static let applePayUnavailable = "APPLE_PAY_UNAVAILABLE"
    /// No attempt exists. The next attempt needs a new order.
    public static let presentationFailed = "PRESENTATION_FAILED"
    /// Declined; nothing will settle. Offer another option.
    public static let paymentRejected = "PAYMENT_REJECTED"
    /// No attempt exists. The provider no longer accepts this order.
    public static let orderStateChanged = "ORDER_STATE_CHANGED"
    /// No attempt exists. The provider is reviewing the customer.
    public static let verificationPending = "VERIFICATION_PENDING"
    /// An attempt may exist. Track the order and never pay it again.
    public static let paymentOutcomeUnknown = "PAYMENT_OUTCOME_UNKNOWN"
    /// Reserved.
    static let providerUnavailable = "PROVIDER_UNAVAILABLE"

    private static let noAttempt: Set<String> = [applePayUnavailable, presentationFailed, paymentRejected,
                                                 orderStateChanged, verificationPending]

    /// `false` only for the codes above that say no attempt exists. Every other code, including one this
    /// build does not know, may follow a payment: track the order and never pay it again.
    public static func attemptMayExist(_ code: String) -> Bool { !noAttempt.contains(code) }
}

public extension MeldError {
    /// Whether a payment attempt may exist for this order. See `MeldErrorCode.attemptMayExist(_:)`.
    var attemptMayExist: Bool { MeldErrorCode.attemptMayExist(code) }
}
