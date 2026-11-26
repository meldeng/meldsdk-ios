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
    /// Clears any form so a provider screen presents over the host, and returns the screen to present from.
    func handOff() async throws -> UIViewController
    func email() async throws -> String
    func registration() async throws -> StripeRegistrationInput
    func identity(fields: [String]) async throws -> StripeIdentityInput
    func address() async throws -> StripeAddressInput
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
    enum Outcome: Equatable {
        case completed, submitted, pending, verificationPending, verificationRequired, cancelled, rejected, expired, refused(Refusal)
        /// Stripe still refuses the customer after they typed every identity field; carries Stripe's reason codes.
        case kycRejected([String])
    }
    enum Refusal: String { case providerRejected = "create:PROVIDER_REJECTED", startNewOrder = "create:START_NEW_ORDER" }
    private let order: StripeNativeOrder
    private let client: PaymentActionSending
    private let store: WalletAttemptStoring
    private let forms: StripeFlowPresenting
    private let lifetime: StripeFlowLifetime
    private let factory: @MainActor () async throws -> StripeSdkRuntime
    private let pause: @MainActor () async throws -> Void
    private let now: () -> Date
    private let request: PKPaymentRequest?
    private let probe: WalletProbe
    private var runtime: StripeSdkRuntime?
    private var financialStarted = false
    private var session: String?
    private var prefill: StripePrefill?
    private var submittedPrefill: Set<String> = []
    private var attachedKeys: Set<String> = []
    /// The customer submitted the full identity form; a later rejection is Stripe's answer, not a missing field.
    private var fullFormSubmitted = false
    private var verifiedTier: String?
    private var started = false
    private var refusedBeforePayment = false
    var mayHaveFinancialAttempt: Bool {
        !refusedBeforePayment && (financialStarted || ((try? store.record())?.submissionStarted ?? true))
    }

    init(order: StripeNativeOrder, client: PaymentActionSending, store: WalletAttemptStoring,
         forms: StripeFlowPresenting, lifetime: StripeFlowLifetime, request: PKPaymentRequest?,
         factory: @escaping @MainActor () async throws -> StripeSdkRuntime,
         probe: WalletProbe = WalletProbe(),
         now: @escaping () -> Date = Date.init,
         pause: @escaping @MainActor () async throws -> Void = { try await Task.sleep(nanoseconds: 2_000_000_000) }) {
        self.order = order; self.client = client; self.store = store; self.forms = forms
        self.lifetime = lifetime; self.request = request; self.factory = factory; self.probe = probe; self.now = now; self.pause = pause
    }

    func run() async throws -> Outcome {
        guard !started else { throw StripeNativeError.busy }
        started = true
        let read = try await action("READ_SUBMISSION")
        let submission = try read.submission()
        prefill = read.prefill
        let authentication: StripeActionResponse.Authentication
        switch submission {
        case .notStarted(let auth):
            guard !(try store.record()).submissionStarted else { throw PaymentActionError.alreadyAttempted }
            try requireWallet()
            authentication = auth
        case .resumeSession(let existing, let auth):
            session = existing; financialStarted = true; try store.observeSubmission(); authentication = auth
        default: return try observe(submission)
        }
        try check()
        runtime = try await factory()
        try check()
        do {
            try await authenticate(authentication)
            guard try await verifyCustomer() else { return .verificationPending }
            if session == nil {
                if verifiedTier != "L0", verifiedTier != "NONE" { try await confirmIdentity() }
                guard try await stepUpOverLimits() else { return .verificationPending }
                try await sdk { try await $0.registerWallet(address: self.order.walletAddress, network: self.order.walletNetwork) }
                try requireWallet()
                let presenter = try await forms.handOff()
                try await sdk { try await $0.collectPayment(request: self.request, from: presenter) }
                let token = try await sdk { try await $0.createPaymentToken() }
                let key = try store.claimSubmission()
                financialStarted = true
                let result: StripeActionResponse
                var retried = false
                do {
                    result = try await action("CREATE_PAYMENT_SESSION", fields: ["paymentToken": token], key: key, retried: &retried)
                } catch PaymentActionError.action(.providerRejected) where !retried { return .refused(.providerRejected) }
                guard let created = result.session else {
                    if result.status == "REJECTED", result.next == "SDK_COLLECT_KYC" || result.next == "SDK_VERIFY_IDENTITY" {
                        refusedBeforePayment = true
                        financialStarted = false
                        return try await stepUpAfterRefusal(result.next)
                    }
                    guard result.status == "FAILED", result.next == "START_NEW_ORDER" else { throw StripeNativeError.invalidResponse }
                    return .refused(.startNewOrder)
                }
                session = created
                return try await continueSession(result)
            }
            return try await continueSession(action("REFRESH_QUOTE", key: UUID()))
        } catch let rejection as StripeKycRejected {
            return .kycRejected(rejection.errors)
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
            } catch PaymentActionError.action(.authorizationRequired) {
                // Expired Meld bearers will also reject preparation; they cannot be renewed here.
            }
        }
        let email: String
        if let known = prefill?.email { email = known } else { email = try await forms.email() }
        try check()
        let hasAccount = try await sdk { try await $0.hasAccount(email: email) }
        if !hasAccount { try await register(email: email) }
        // Preparation also reuses initial consent; its expiry is independent of the bearer lifetime.
        var prepared = try await action("PREPARE_CUSTOMER_AUTHORIZATION", key: UUID())
        if try prepared.requiresRegistration() {
            guard hasAccount, state == .bootstrap, order.flow == "REGISTER", session == nil,
                  !financialStarted else { throw StripeNativeError.invalidResponse }
            try await register(email: email)
            prepared = try await action("PREPARE_CUSTOMER_AUTHORIZATION", key: UUID())
        }
        let intent = try prepared.authorizationIntent(now: now())
        let presenter = try await forms.handOff()
        let customer = try await sdk { try await $0.authorize(intent: intent, from: presenter) }
        let linked = try await action("COMPLETE_CUSTOMER_LINK", fields: ["customerHandle": customer], key: UUID())
        try linked.validateCustomerAction(requiresDetails: false)
    }

    /// A verified phone registers without a form; if Stripe refuses it, the customer enters one instead.
    private func register(email: String) async throws {
        if let phone = prefill?.phone {
            do {
                try await sdk { try await $0.register(email: email, name: self.prefill?.fullName, phone: phone, country: "US") }
                return
            } catch StripeNativeError.cancelled {
                throw StripeNativeError.cancelled
            } catch {
                try check()
            }
        }
        let registration = try await forms.registration()
        try await sdk { try await $0.register(email: email, name: registration.name, phone: registration.phone, country: "US") }
    }

    /// Each prefilled value is submitted at most once, so a value Stripe rejected is never resent.
    private func identity(fields: [String], prefilled: Bool) async throws -> StripeIdentityInput {
        guard prefilled, let known = prefill?.identity else {
            // After a rejected prefill, ask for everything: Stripe may not list the prefilled fields as missing.
            let asked = !submittedPrefill.isEmpty && !prefilled ? [] : fields
            let input = try await forms.identity(fields: asked)
            if asked.isEmpty { fullFormSubmitted = true }
            return input
        }
        let wanted = fields.isEmpty ? Self.identityFields : fields
        let submitted = submittedPrefill
        let covered: (String) -> Bool = {
            guard !submitted.contains(Self.prefillKey($0)) else { return false }
            switch $0 {
            case "FIRST_NAME": return known.firstName != nil
            case "LAST_NAME": return known.lastName != nil
            case "DATE_OF_BIRTH": return known.birthYear != nil
            case "ID_NUMBER": return known.idNumber != nil
            default: return $0.hasPrefix("ADDRESS_") && known.address != nil
            }
        }
        let remaining = wanted.filter { !covered($0) }
        var input = remaining.isEmpty ? StripeIdentityInput() : try await forms.identity(fields: remaining)
        if wanted.contains("FIRST_NAME"), covered("FIRST_NAME") { input.firstName = known.firstName }
        if wanted.contains("LAST_NAME"), covered("LAST_NAME") { input.lastName = known.lastName }
        if wanted.contains("DATE_OF_BIRTH"), covered("DATE_OF_BIRTH") {
            input.birthDay = known.birthDay; input.birthMonth = known.birthMonth; input.birthYear = known.birthYear
        }
        if wanted.contains("ID_NUMBER"), covered("ID_NUMBER") { input.idNumber = known.idNumber }
        if let field = wanted.first(where: { $0.hasPrefix("ADDRESS_") }), covered(field) { input.address = known.address }
        submittedPrefill.formUnion(wanted.filter(covered).map(Self.prefillKey))
        return input
    }

    private static func prefillKey(_ field: String) -> String { field.hasPrefix("ADDRESS_") ? "ADDRESS" : field }

    /// About 30 s at the 2 s pause, inside Stripe's documented polling window for a submitted tier.
    private static let attachWaitReads = 15

    private func attach(_ input: StripeIdentityInput) async throws {
        try await sdk { try await $0.attachIdentity(input) }
        if input.firstName != nil { attachedKeys.insert("FIRST_NAME") }
        if input.lastName != nil { attachedKeys.insert("LAST_NAME") }
        if input.birthYear != nil { attachedKeys.insert("DATE_OF_BIRTH") }
        if input.idNumber != nil { attachedKeys.insert("ID_NUMBER") }
        if input.address != nil { attachedKeys.insert("ADDRESS") }
    }

    private static let identityFields = ["FIRST_NAME", "LAST_NAME", "DATE_OF_BIRTH", "ID_NUMBER", "ADDRESS_LINE_1",
                                         "ADDRESS_CITY", "ADDRESS_STATE", "ADDRESS_POSTAL_CODE", "ADDRESS_COUNTRY"]

    private func verifyCustomer() async throws -> Bool {
        var reads = 0, waits = 0
        while reads < 12 {
            let result = try await action("READ_CUSTOMER_STATUS")
            try result.validateCustomerAction(requiresDetails: true)
            // Stripe's answer to a rejected L0 is the L1 step-up (DOB and ID number), not the L0 fields again.
            let l0Rejected = result.tierStatuses["L0"] == "REJECTED" && (result.tierStatuses["L1"] ?? "NOT_STARTED") == "NOT_STARTED"
            let stepUp = l0Rejected && !attachedKeys.contains("ID_NUMBER") && !submittedPrefill.contains("ID_NUMBER")
                && prefill?.identity?.idNumber != nil && prefill?.identity?.birthYear != nil
            switch (result.status, result.next) {
            case ("VERIFIED", "CREATE_PAYMENT_SESSION"), ("VERIFIED", "REFRESH_QUOTE"), ("VERIFIED", "NONE"):
                verifiedTier = result.highestVerifiedTier
                return true
            case ("REJECTED", "SDK_COLLECT_KYC") where l0Rejected && attachedKeys.contains("ID_NUMBER"):
                guard waits < Self.attachWaitReads else { return false }
                waits += 1
                forms.showProgress("Checking your verification")
                try await pause(); try check()
                continue
            case ("REJECTED", "SDK_COLLECT_KYC") where stepUp:
                // L1 is the L0 fields plus DOB and ID number, so an L0 field Stripe still lacks goes with them.
                let unsent = result.missingFields.filter {
                    !attachedKeys.contains(Self.prefillKey($0)) && $0 != "DATE_OF_BIRTH" && $0 != "ID_NUMBER"
                }
                try await attach(try await identity(fields: unsent + ["DATE_OF_BIRTH", "ID_NUMBER"], prefilled: true))
                waits = 0
            // The customer already typed every field: the same empty form again would loop, so wait out a tier
            // Stripe is still checking, then end with Stripe's reasons.
            case ("REJECTED", "SDK_COLLECT_KYC") where fullFormSubmitted:
                guard result.tierStatuses.values.contains("PENDING") else { throw StripeKycRejected(errors: result.rejectionErrors) }
                guard waits < Self.attachWaitReads else { return false }
                waits += 1
                forms.showProgress("Checking your verification")
                try await pause(); try check()
                continue
            // Stripe verifies an attach asynchronously and keeps answering NOT_STARTED for data it already holds.
            case ("NOT_STARTED", "SDK_COLLECT_KYC") where Set(result.missingFields.map(Self.prefillKey)).isSubset(of: attachedKeys):
                guard waits < Self.attachWaitReads else { return false }
                waits += 1
                forms.showProgress("Checking your verification")
                try await pause(); try check()
                continue
            case ("NOT_STARTED", "SDK_COLLECT_KYC"), ("REJECTED", "SDK_COLLECT_KYC"):
                // REJECTED with fields still missing means Stripe holds none of them yet (a new Link customer), not a refusal.
                let prefilled = result.status == "NOT_STARTED" || (submittedPrefill.isEmpty && !result.missingFields.isEmpty)
                let input = try await identity(fields: result.missingFields, prefilled: prefilled)
                try await attach(input)
                waits = 0
            case ("NOT_STARTED", "SDK_VERIFY_IDENTITY"), ("REJECTED", "SDK_VERIFY_IDENTITY"):
                let presenter = try await forms.handOff()
                try await sdk { try await $0.verifyIdentity(from: presenter) }
            case ("PENDING", "RETRY"):
                forms.showProgress("Checking your verification")
                try await pause(); try check()
            default: throw StripeNativeError.invalidResponse
            }
            reads += 1
        }
        return false
    }

    /// L1 data is one-way, so a customer steps up only when the order is over their current limits.
    private func stepUpOverLimits() async throws -> Bool {
        var previous: (step: String, tier: String?)?
        for _ in 0..<3 {
            guard let limits = try? await action("READ_LIMITS") else { try check(); return true }
            if let previous, previous.step == limits.next, previous.tier == verifiedTier { return true }
            previous = (limits.next, verifiedTier)
            switch limits.next {
            case "SDK_COLLECT_KYC":
                let input = try await identity(fields: verifiedTier == "L0" ? ["DATE_OF_BIRTH", "ID_NUMBER"] : [], prefilled: true)
                try await attach(input)
            case "SDK_VERIFY_IDENTITY":
                let presenter = try await forms.handOff()
                try await sdk { try await $0.verifyIdentity(from: presenter) }
            default: return true
            }
            guard try await verifyCustomer() else { return false }
        }
        return true
    }

    /// Stripe refused the session for more KYC (e.g. a risk-rule identity challenge) before any charge; ID checks need L1 first.
    private func stepUpAfterRefusal(_ next: String) async throws -> Outcome {
        if next == "SDK_COLLECT_KYC" || verifiedTier == "L0" || verifiedTier == "NONE" {
            let input = try await identity(fields: verifiedTier == "L0" ? ["DATE_OF_BIRTH", "ID_NUMBER"] : [], prefilled: true)
            try await attach(input)
            guard try await verifyCustomer() else { return .verificationRequired }
        }
        if next == "SDK_VERIFY_IDENTITY" {
            let presenter = try await forms.handOff()
            try await sdk { try await $0.verifyIdentity(from: presenter) }
        }
        return .verificationRequired
    }

    private func confirmIdentity() async throws {
        var address: StripeAddressInput?
        for _ in 0..<3 {
            let current = address
            let presenter = try await forms.handOff()
            let result = try await sdk { try await $0.confirmIdentity(address: current, from: presenter) }
            if case .confirmed = result { return }
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
                let presenter = try await forms.handOff()
                var followUp: StripeActionResponse?
                var authorizationRequired = false
                do {
                    try await runtime.checkout(session: expected, from: presenter) { [weak self] requested in
                        guard let self else { throw StripeNativeError.cancelled }
                        guard followUp == nil, !authorizationRequired else { throw StripeNativeError.actionRequired }
                        let invocation = StripeCheckoutInvocation()
                        let response: StripeActionResponse
                        do {
                            response = try await self.action("CONFIRM_PAYMENT", fields: invocation.fields, key: invocation.idempotencyKey)
                        } catch PaymentActionError.action(.authorizationRequired) {
                            authorizationRequired = true
                            throw StripeNativeError.actionRequired
                        }
                        guard response.session == requested else { throw StripeNativeError.invalidResponse }
                        if ["SDK_COLLECT_KYC", "SDK_VERIFY_IDENTITY", "SDK_REGISTER_WALLET", "REFRESH_QUOTE"].contains(response.next) {
                            followUp = response
                            throw StripeNativeError.actionRequired
                        }
                        return try response.checkoutSecret(session: requested, now: self.now())
                    }
                } catch {
                    try check()
                    if let followUp { result = followUp; continue }
                    if authorizationRequired {
                        try await authenticate(.reauthorize)
                        result = try await action("REFRESH_QUOTE", key: UUID())
                        continue
                    }
                    throw error
                }
                // Even a provider that swallows a callback error cannot turn it into success.
                if let followUp { result = followUp; continue }
                if authorizationRequired { throw StripeNativeError.authorizationRequired }
                return try observe(await action("READ_SUBMISSION").submission())
            case ("REJECTED", "SDK_COLLECT_KYC"), ("REJECTED", "SDK_VERIFY_IDENTITY"):
                if result.next == "SDK_VERIFY_IDENTITY" {
                    let presenter = try await forms.handOff()
                try await sdk { try await $0.verifyIdentity(from: presenter) }
                } else {
                    let input = try await forms.identity(fields: [])
                    try await attach(input)
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

    /// Checked before a new Apple Pay payment is collected, never when resuming one that already exists.
    private func requireWallet() throws {
        guard let request, let reason = MeldApplePayAvailability.unavailableReason(
            requiring: request.supportedNetworks, device: probe.device, wallet: probe.wallet) else { return }
        throw PaymentMethodUnavailable(reason: reason)
    }

    private func observe(_ submission: StripeActionResponse.Submission) throws -> Outcome {
        try check()
        switch submission {
        case .notStarted: break
        case .resumeSession, .inProgress, .submitted, .completed, .failed, .expired, .unknown: financialStarted = true
        }
        try store.observeSubmission()
        switch submission {
        case .completed: return .completed
        case .submitted: return .submitted
        case .inProgress, .unknown: return .pending
        case .failed: return .rejected
        case .expired: return .expired
        case .notStarted, .resumeSession: throw PaymentActionError.alreadyAttempted
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
        var retried = false
        return try await action(operation, fields: fields, key: key, retried: &retried)
    }

    private func action(_ operation: String, fields: [String: Any], key: UUID?,
                        retried: inout Bool) async throws -> StripeActionResponse {
        // Retry only a transport failure, once, with the identical body and mutation identity.
        for attempt in 0..<2 {
            try check()
            do {
                let json: [String: Any] = try await withCheckedThrowingContinuation { continuation in
                    client.send(operation, fields: fields, key: key) { continuation.resume(with: $0) }
                }
                try check()
                return try StripeActionResponse(json)
            } catch PaymentActionError.transport where attempt == 0 { retried = true; continue }
        }
        throw PaymentActionError.transport
    }

    private func check() throws {
        guard lifetime.active, !Task.isCancelled else { throw StripeNativeError.cancelled }
    }
}

/// Stripe still rejects the customer after they submitted the full identity form.
private struct StripeKycRejected: Error { let errors: [String] }
