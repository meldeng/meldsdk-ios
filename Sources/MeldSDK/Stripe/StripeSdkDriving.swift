import Foundation
import PassKit
import UIKit

/// Transient identity input. Deliberately not Codable or part of a public callback or attempt record.
struct StripeIdentityInput: CustomStringConvertible {
    var firstName: String?
    var lastName: String?
    var idNumber: String?
    var birthDay: Int?
    var birthMonth: Int?
    var birthYear: Int?
    var address: StripeAddressInput?
    var description: String { "StripeIdentityInput[REDACTED]" }
}

struct StripeAddressInput: CustomStringConvertible {
    let line1: String
    let line2: String?
    let city: String
    let state: String
    let postalCode: String
    let country: String
    var description: String { "StripeAddressInput[REDACTED]" }
}

enum StripeKycConfirmation { case confirmed, updateAddress }

/// Provider SDK operations only. Meld HTTP, forms, attempt storage and event policy stay outside.
@MainActor
protocol StripeSdkDriving: AnyObject {
    func hasAccount(email: String) async throws -> Bool
    func register(email: String, name: String?, phone: String, country: String) async throws
    func authorize(intent: String, from presenter: UIViewController) async throws -> String
    func authenticate(secret: String) async throws
    func attachIdentity(_ input: StripeIdentityInput) async throws
    func verifyIdentity(from presenter: UIViewController) async throws
    func confirmIdentity(address: StripeAddressInput?, from presenter: UIViewController) async throws -> StripeKycConfirmation
    func registerWallet(address: String, network: String) async throws
    func collectPayment(request: PKPaymentRequest?, from presenter: UIViewController) async throws
    func createPaymentToken() async throws -> String
    func checkout(session: String, from presenter: UIViewController,
                  secret: @escaping @MainActor (String) async throws -> String) async throws
    func logOut() async throws
}
