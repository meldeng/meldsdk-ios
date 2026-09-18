import Foundation
import PassKit
import UIKit

struct StripeRegistrationInput: CustomStringConvertible {
    let name: String?
    let phone: String
    var description: String { "StripeRegistrationInput[REDACTED]" }
}

@MainActor
protocol StripeFlowPresenting: AnyObject {
    var presenter: UIViewController { get }
    func email() async throws -> String
    func registration() async throws -> StripeRegistrationInput
    func identity(fields: [String]) async throws -> StripeIdentityInput
    func address() async throws -> StripeAddressInput
    func disclosure(_ value: LegalDisclosure) async throws -> Bool
    func showProgress(_ message: String)
    func close()
}

/// Shared between main-actor work and synchronous unmount. No events or new operations after close.
final class StripeFlowLifetime: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var value = true
    var active: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func close() { lock.lock(); value = false; lock.unlock() }
    func ifActive(_ body: () -> Void) { lock.lock(); defer { lock.unlock() }; if value { body() } }
}

@MainActor
final class StripeFlowController {
    enum Outcome { case completed, submitted, pending, verificationPending, cancelled }
    private let order: StripeNativeOrder
    private let client: PaymentActionSending
    private let store: WalletAttemptStoring
    private let forms: StripeFlowPresenting
    private let lifetime: StripeFlowLifetime
    private let factory: @MainActor () async throws -> StripeSdkRuntime
    private let pause: @MainActor () async throws -> Void
    private let now: () -> Date
    private let request: PKPaymentRequest?
    private var runtime: StripeSdkRuntime?
    private var financialStarted = false
    private var unsubmittedConfirmed = false
    private var session: String?
    private var started = false
    var mayHaveFinancialAttempt: Bool { financialStarted || !unsubmittedConfirmed }

    init(order: StripeNativeOrder, client: PaymentActionSending, store: WalletAttemptStoring,
         forms: StripeFlowPresenting, lifetime: StripeFlowLifetime, request: PKPaymentRequest?,
         factory: @escaping @MainActor () async throws -> StripeSdkRuntime,
         now: @escaping () -> Date = Date.init,
         pause: @escaping @MainActor () async throws -> Void = { try await Task.sleep(nanoseconds: 2_000_000_000) }) {
        self.order = order; self.client = client; self.store = store; self.forms = forms
        self.lifetime = lifetime; self.request = request; self.factory = factory; self.now = now; self.pause = pause
    }

    func run() async throws -> Outcome {
        guard !started else { throw StripeNativeError.busy }
        started = true
        let submission = try await action("READ_SUBMISSION").submission()
        let authentication: StripeActionResponse.Authentication
        switch submission {
        case .notStarted(let auth):
            guard !(try store.record()).submissionStarted else { throw PaymentActionError.alreadyAttempted }
            unsubmittedConfirmed = true
            authentication = auth
        case .resumeSession(let existing, let auth):
            try store.observeSubmission(); session = existing; financialStarted = true; authentication = auth
        default: return try observe(submission)
        }
        try check()
        runtime = try await factory()
        try check()
        do {
            try await authenticate(authentication)
            guard try await verifyCustomer() else { return .verificationPending }
            if session == nil {
                try await confirmIdentity()
                try await sdk { try await $0.registerWallet(address: self.order.walletAddress, network: self.order.walletNetwork) }
                forms.showProgress("Choose a payment method")
                try await sdk { try await $0.collectPayment(request: self.request, from: self.forms.presenter) }
                try check()
                let key = try store.claimSubmission()
                financialStarted = true
                let token = try await sdk { try await $0.createPaymentToken() }
                let result = try await action("CREATE_PAYMENT_SESSION", fields: ["paymentToken": token], key: key)
                guard let created = result.session else { throw StripeNativeError.invalidResponse }
                session = created
                return try await continueSession(result)
            }
            return try await continueSession(action("REFRESH_QUOTE", key: UUID()))
        } catch StripeNativeError.cancelled {
            // Dismissing native checkout can race a payment. Only the server can resolve that outcome.
            guard lifetime.active else { throw StripeNativeError.cancelled }
            return financialStarted ? try observe(await action("READ_SUBMISSION").submission()) : .cancelled
        }
    }

    func close() async {
        lifetime.close()
        forms.close()
        client.finish()
        await runtime?.close()
    }

    private func authenticate(_ state: StripeActionResponse.Authentication) async throws {
        if state == .restore || (state == .bootstrap && order.flow == "SEAMLESS") {
            do {
                let result = try await action("CREATE_CUSTOMER_AUTH_TOKEN", key: UUID())
                let secret = try result.authenticationSecret(now: now())
                try await sdk { try await $0.authenticate(secret: secret) }
                return
            } catch StripeNativeError.authorizationRequired {
                // The backend still owns the customer identity and authorization scope.
                // Expired Meld bearers propagate to the caller; vendor consent cannot renew them.
            }
        }
        let email = try await forms.email()
        try check()
        let hasAccount = try await sdk { try await $0.hasAccount(email: email) }
        if !hasAccount {
            let registration = try await forms.registration()
            try await sdk { try await $0.register(email: email, name: registration.name, phone: registration.phone, country: "US") }
        }
        // Preparation also reuses initial consent; its expiry is independent of the bearer lifetime.
        let intent = try await action("PREPARE_CUSTOMER_AUTHORIZATION", key: UUID()).authorizationIntent(now: now())
        let customer = try await sdk { try await $0.authorize(intent: intent, from: self.forms.presenter) }
        let linked = try await action("COMPLETE_CUSTOMER_LINK", fields: ["customerHandle": customer], key: UUID())
        try linked.validateCustomerAction(requiresDetails: false)
    }

    private func verifyCustomer() async throws -> Bool {
        for _ in 0..<12 {
            let result = try await action("READ_CUSTOMER_STATUS")
            try result.validateCustomerAction(requiresDetails: true)
            switch (result.status, result.next) {
            case ("VERIFIED", "CREATE_PAYMENT_SESSION"), ("VERIFIED", "REFRESH_QUOTE"), ("VERIFIED", "NONE"):
                return true
            case ("NOT_STARTED", "SDK_COLLECT_KYC"), ("REJECTED", "SDK_COLLECT_KYC"):
                try await requireIdentityConsent()
                let input = try await forms.identity(fields: result.missingFields)
                try await sdk { try await $0.attachIdentity(input) }
            case ("NOT_STARTED", "SDK_VERIFY_IDENTITY"), ("REJECTED", "SDK_VERIFY_IDENTITY"):
                try await sdk { try await $0.verifyIdentity(from: self.forms.presenter) }
            case ("PENDING", "RETRY"):
                forms.showProgress("Checking your verification")
                try await pause(); try check()
            default: throw StripeNativeError.invalidResponse
            }
        }
        return false
    }

    private func confirmIdentity() async throws {
        var address: StripeAddressInput?
        for _ in 0..<3 {
            let current = address
            let result = try await sdk { try await $0.confirmIdentity(address: current, from: self.forms.presenter) }
            if case .confirmed = result { return }
            try await requireIdentityConsent()
            address = try await forms.address()
        }
        throw StripeNativeError.invalidResponse
    }

    private func continueSession(_ initial: StripeActionResponse) async throws -> Outcome {
        var result = initial
        for _ in 0..<12 {
            try check()
            guard let expected = session, result.session == expected else { throw StripeNativeError.invalidResponse }
            switch (result.status, result.next) {
            case ("QUOTE_READY", "CONFIRM_PAYMENT"), ("REQUIRES_PAYMENT", "CONFIRM_PAYMENT"):
                guard let runtime else { throw StripeNativeError.unavailable }
                forms.showProgress("Confirm your payment")
                var followUp: StripeActionResponse?
                var callbackFailure: Error?
                do {
                    try await runtime.checkout(session: expected, from: forms.presenter) { [weak self] requested in
                        guard let self else { throw StripeNativeError.cancelled }
                        if let callbackFailure { throw callbackFailure }
                        guard followUp == nil else { throw StripeNativeError.actionRequired }
                        let invocation = StripeCheckoutInvocation()
                        do {
                            let response = try await self.action("CONFIRM_PAYMENT", fields: invocation.fields, key: invocation.idempotencyKey)
                            guard response.session == requested else { throw StripeNativeError.invalidResponse }
                            if ["SDK_COLLECT_KYC", "SDK_VERIFY_IDENTITY", "SDK_REGISTER_WALLET", "REFRESH_QUOTE"].contains(response.next) {
                                followUp = response
                                throw StripeNativeError.actionRequired
                            }
                            return try response.checkoutSecret(session: requested, now: self.now())
                        } catch {
                            if followUp == nil { callbackFailure = MeldHeadlessError.failure(error, operation: "CONFIRM_PAYMENT") }
                            throw callbackFailure ?? error
                        }
                    }
                } catch {
                    try check()
                    if let callbackFailure { throw callbackFailure }
                    if let followUp { result = followUp; continue }
                    throw error
                }
                // Even a provider that swallows a callback error cannot turn it into success.
                if let callbackFailure { throw callbackFailure }
                if let followUp { result = followUp; continue }
                return try observe(await action("READ_SUBMISSION").submission())
            case ("REJECTED", "SDK_COLLECT_KYC"), ("REJECTED", "SDK_VERIFY_IDENTITY"):
                if result.next == "SDK_VERIFY_IDENTITY" {
                    try await sdk { try await $0.verifyIdentity(from: self.forms.presenter) }
                } else {
                    try await requireIdentityConsent()
                    let input = try await forms.identity(fields: [])
                    try await sdk { try await $0.attachIdentity(input) }
                }
                guard try await verifyCustomer() else { return .verificationPending }
            case ("REQUIRES_PAYMENT", "SDK_REGISTER_WALLET"):
                try await sdk { try await $0.registerWallet(address: self.order.walletAddress, network: self.order.walletNetwork) }
            case ("REQUIRES_PAYMENT", "REFRESH_QUOTE"): break
            case ("FULFILLMENT_PROCESSING", "NONE"), ("FULFILLMENT_COMPLETE", "COMPLETE"):
                return try observe(await action("READ_SUBMISSION").submission())
            default: throw StripeNativeError.invalidResponse
            }
            result = try await action("REFRESH_QUOTE", key: UUID())
        }
        throw StripeNativeError.invalidResponse
    }

    private func observe(_ submission: StripeActionResponse.Submission) throws -> Outcome {
        try check()
        try store.observeSubmission()
        switch submission {
        case .completed: return .completed
        case .submitted: return .submitted
        case .inProgress, .unknown: return .pending
        case .failed, .expired, .notStarted, .resumeSession: throw PaymentActionError.alreadyAttempted
        }
    }

    private func sdk<T>(_ operation: @MainActor (StripeSdkDriving) async throws -> T) async throws -> T {
        try check()
        guard let runtime else { throw StripeNativeError.unavailable }
        let value = try await runtime.perform(operation)
        try check()
        return value
    }

    private func action(_ operation: String, fields: [String: Any] = [:], key: UUID? = nil) async throws -> StripeActionResponse {
        do { return try StripeActionResponse(await send(operation, fields: fields, key: key)) }
        catch { throw MeldHeadlessError.failure(error, operation: operation) }
    }

    private func requireIdentityConsent() async throws {
        do {
            try await LegalConsent.require("IDENTITY_DATA_SHARING", send: { operation, fields, key in
                try await self.send(operation, fields: fields, key: key)
            }, present: { try await self.forms.disclosure($0) }, check: { try self.check() })
        } catch LegalConsentError.declined { throw StripeNativeError.cancelled }
        catch LegalConsentError.cancelled { throw StripeNativeError.cancelled }
    }

    private func send(_ operation: String, fields: [String: Any], key: UUID?) async throws -> [String: Any] {
        // A lost response remains ambiguous even with a stable key. Recovery never replays a mutation automatically.
        try check()
        do {
            let json: [String: Any] = try await withCheckedThrowingContinuation { continuation in
                client.send(operation, fields: fields, key: key) { continuation.resume(with: $0) }
            }
            try check()
            return json
        } catch {
            try check()
            throw MeldHeadlessError.failure(error, operation: operation)
        }
    }

    private func check() throws {
        guard lifetime.active, !Task.isCancelled else { throw StripeNativeError.cancelled }
    }
}
