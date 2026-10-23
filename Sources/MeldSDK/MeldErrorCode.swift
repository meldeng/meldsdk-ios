import Foundation

/// Normalized `MeldError.code` values. The provider's own event and code travel in `detail`.
public enum MeldErrorCode {
    /// No attempt exists. This device or customer cannot pay with the order's method; offer another.
    public static let paymentMethodUnavailable = "PAYMENT_METHOD_UNAVAILABLE"
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
    /// An attempt may exist. The provider's page did not load; with `recoverable: true` the surface stays up.
    public static let providerLoadFailed = "PROVIDER_LOAD_FAILED"
    /// Reserved.
    static let providerUnavailable = "PROVIDER_UNAVAILABLE"

    private static let noAttempt: Set<String> = [paymentMethodUnavailable, presentationFailed, paymentRejected,
                                                 orderStateChanged, verificationPending]

    /// `false` only for the codes above that say no attempt exists. Every other code, including one this
    /// build does not know, may follow a payment: track the order and never pay it again.
    public static func attemptMayExist(_ code: String) -> Bool { !noAttempt.contains(code) }
}

public extension MeldError {
    /// Whether a payment attempt may exist for this order. See `MeldErrorCode.attemptMayExist(_:)`.
    var attemptMayExist: Bool { MeldErrorCode.attemptMayExist(code) }
}

/// `MeldError.message` copy for outcomes that read the same whatever the provider, so a decline from
/// Banxa, Stripe or a hosted Apple Pay page tells the customer the same thing. Providers rarely hand the
/// client a decline reason (Banxa's Primer account reports only FAILED), so the copy names the most
/// common cause and what to do about it; the provider's own code stays in `detail`.
enum MeldErrorMessage {
    static let paymentRejected = "This payment was declined. Some banks block crypto purchases on credit cards, "
        + "so try a debit card or another payment method."
    static let paymentOutcomeUnknown = "The payment outcome is not known yet. Track the existing order without paying again."

    /// The shared copy for `code`, or nil when the adapter's own message says more.
    static func standard(for code: String) -> String? {
        switch code {
        case MeldErrorCode.paymentRejected: return paymentRejected
        case MeldErrorCode.paymentOutcomeUnknown: return paymentOutcomeUnknown
        default: return nil
        }
    }
}
