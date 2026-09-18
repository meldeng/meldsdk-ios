import PassKit
@_spi(CryptoOnrampAlpha) import StripeCryptoOnramp
@_spi(CryptoOnrampAlpha) import StripePaymentSheet
import StripePayments
import UIKit

/// The pinned Stripe API is isolated here. No global publishable key or integrator callbacks.
@MainActor
final class StripeSdkDriver: StripeSdkDriving {
    private let coordinator: CryptoOnrampCoordinator

    static func create(publicKey: String) async throws -> StripeSdkDriver {
        let client = STPAPIClient(publishableKey: publicKey)
        return try await StripeSdkDriver(coordinator: CryptoOnrampCoordinator.create(apiClient: client))
    }

    private init(coordinator: CryptoOnrampCoordinator) { self.coordinator = coordinator }

    func hasAccount(email: String) async throws -> Bool { try await coordinator.hasLinkAccount(with: email) }

    func register(email: String, name: String?, phone: String, country: String) async throws {
        _ = try await coordinator.registerLinkUser(email: email, fullName: name, phone: phone, country: country)
    }

    func authorize(intent: String, from presenter: UIViewController) async throws -> String {
        switch try await coordinator.authorize(linkAuthIntentId: intent, from: presenter) {
        case .consented(let id):
            guard StripeNativeValue.identifier(id, prefix: "crc_") != nil else { throw StripeNativeError.invalidResponse }
            return id
        case .canceled, .denied: throw StripeNativeError.cancelled
        @unknown default: throw StripeNativeError.invalidResponse
        }
    }

    func authenticate(secret: String) async throws {
        do { try await coordinator.authenticateUserWithToken(secret) }
        catch CryptoOnrampCoordinator.Error.seamlessSignInTokenInvalid {
            throw StripeNativeError.authorizationRequired
        }
    }

    func attachIdentity(_ input: StripeIdentityInput) async throws {
        let birthday: KycInfo.DateOfBirth?
        if let day = input.birthDay, let month = input.birthMonth, let year = input.birthYear {
            birthday = .init(day: day, month: month, year: year)
        } else { birthday = nil }
        try await coordinator.attachKYCInfo(info: .init(
            firstName: input.firstName, lastName: input.lastName, idNumber: input.idNumber,
            address: input.address.map(Self.address), dateOfBirth: birthday))
    }

    func verifyIdentity(from presenter: UIViewController) async throws {
        guard let reason = Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String,
              !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw StripeNativeError.unavailable }
        switch try await coordinator.verifyIdentity(from: presenter) {
        case .completed: return
        case .canceled: throw StripeNativeError.cancelled
        @unknown default: throw StripeNativeError.invalidResponse
        }
    }

    func confirmIdentity(address: StripeAddressInput?, from presenter: UIViewController) async throws -> StripeKycConfirmation {
        switch try await coordinator.verifyKYCInfo(updatedAddress: address.map(Self.address), from: presenter) {
        case .confirmed: return .confirmed
        case .updateAddress: return .updateAddress
        case .canceled: throw StripeNativeError.cancelled
        @unknown default: throw StripeNativeError.invalidResponse
        }
    }

    func registerWallet(address: String, network: String) async throws {
        guard let network = CryptoNetwork(rawValue: network) else { throw StripeNativeError.invalidOrder }
        try await coordinator.registerWalletAddress(walletAddress: address, network: network)
    }

    func collectPayment(request: PKPaymentRequest?, from presenter: UIViewController) async throws {
        let type: PaymentMethodType = request.map { .applePay(paymentRequest: $0) } ?? .card
        switch try await coordinator.collectPaymentMethod(type: type, from: presenter) {
        case .completed: return
        case .canceled: throw StripeNativeError.cancelled
        @unknown default: throw StripeNativeError.invalidResponse
        }
    }

    func createPaymentToken() async throws -> String {
        let token = try await coordinator.createCryptoPaymentToken()
        guard StripeNativeValue.identifier(token, prefix: "cpt_") != nil else { throw StripeNativeError.invalidResponse }
        return token
    }

    func checkout(session: String, from presenter: UIViewController,
                  secret: @escaping @MainActor (String) async throws -> String) async throws {
        let context = AuthenticationContext(presenter)
        switch try await coordinator.performCheckout(onrampSessionId: session, authenticationContext: context,
                                                     onrampSessionClientSecretProvider: { try await secret($0) }) {
        case .completed: return
        case .canceled: throw StripeNativeError.cancelled
        @unknown default: throw StripeNativeError.invalidResponse
        }
    }

    func logOut() async throws { try await coordinator.logOut() }

    private static func address(_ value: StripeAddressInput) -> Address {
        Address(city: value.city, country: value.country, line1: value.line1, line2: value.line2,
                postalCode: value.postalCode, state: value.state)
    }
}

private final class AuthenticationContext: NSObject, STPAuthenticationContext {
    private let presenter: UIViewController
    init(_ presenter: UIViewController) { self.presenter = presenter }
    func authenticationPresentingViewController() -> UIViewController { presenter }
}
