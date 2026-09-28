import Foundation

/// Inputs the SDK needs to present a native Apple Pay sheet for an Apple Pay order, beyond what
/// the order itself carries. The order (`ApplePayOrder`) supplies `merchantIdentifier`,
/// `sessionToken`, and `merchantTransactionId`; everything below is what the app already knows
/// from the quote it created the order against. The SDK uses the order's action descriptor to
/// submit wallet data and continue any required hosted verification.
///
/// Provider-determined values — the merchant country, supported card networks, and merchant
/// capabilities — are NOT here: they're fixed by the provider (e.g. Mercuryo requires `LT`,
/// Visa/Mastercard, 3DS+credit+debit) and set by the adapter, not the integrator.
public struct MeldApplePayRequest {
    /// Fiat amount to charge, shown on the Apple Pay sheet (e.g. `15.00`).
    public let amount: Decimal
    /// Fiat currency, ISO 4217 (e.g. `"EUR"`). Must match the order's source currency.
    public let currencyCode: String
    /// Legacy orders only: destination crypto wallet. New actions use the server-bound address.
    public let walletAddress: String
    /// Legacy orders only: end user's public IP. New actions use the server-bound client IP.
    public let clientIpAddress: String
    /// Fallback email when PassKit omits it. A valid email must be available before submission.
    public let email: String?
    /// Line-item label rendered on the Apple Pay sheet (your merchant/product name).
    public let summaryItemLabel: String

    public init(
        amount: Decimal,
        currencyCode: String,
        walletAddress: String = "",
        clientIpAddress: String = "",
        email: String? = nil,
        summaryItemLabel: String = "Crypto purchase"
    ) {
        self.amount = amount
        self.currencyCode = currencyCode
        self.walletAddress = walletAddress
        self.clientIpAddress = clientIpAddress
        self.email = email
        self.summaryItemLabel = summaryItemLabel
    }
}

/// Failures specific to presenting native Apple Pay. Distinct from `MeldMountError` because Apple
/// Pay is a modal native sheet, not a widget mounted into a `UIView`.
public enum MeldApplePayError: LocalizedError {
    /// The device/user can't pay with Apple Pay (no card provisioned, restricted, unsupported).
    case unavailable
    /// The order isn't an Apple Pay order, or is missing a field the SDK needs from it.
    case invalidOrder(String)
    /// The Apple Pay sheet returned without the billing details the provider requires.
    case missingBillingDetails(String)
    /// The `/process` call failed at the network/transport layer (not a declined payment).
    case processingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Apple Pay is not available on this device or for this user."
        case let .invalidOrder(detail):
            return detail
        case let .missingBillingDetails(detail):
            return detail
        case let .processingFailed(detail):
            return detail
        }
    }
}
