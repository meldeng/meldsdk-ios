import Foundation

/// Shared order lifecycle; adapters supply wallet and hosted surfaces, never financial retry policy.
/// Like the SDK's UI callbacks, all calls to this session run on the main thread.
final class WalletPaymentSession: MeldProviderSession {
    typealias SheetFactory = (@escaping (WalletPayment, @escaping (ApplePayProcessOutcome) -> Void) -> Void,
                              @escaping () -> Void) throws -> MeldProviderSession
    typealias HostedFactory = (WalletVerification, @escaping () -> Bool, @escaping (Bool) -> Void) throws -> MeldProviderSession

    private let identity: String
    private let orderID: String?
    private let client: PaymentActionSending
    private let store: WalletAttemptStoring
    private let handlers: MeldEventHandlers
    private let sheetFactory: SheetFactory
    private let hostedFactory: HostedFactory
    private let acceptsVerification: (URL) -> Bool
    private let now: () -> Date
    private var active = true
    private var started = false
    private var sheetActive = false
    private var didAuthorize = false
    private var submitting = false
    private var surface: MeldProviderSession?
    private var pending: Result<WalletActionResponse, Error>?

    init(identity: String, orderID: String?, client: PaymentActionSending, store: WalletAttemptStoring,
         handlers: MeldEventHandlers, sheetFactory: @escaping SheetFactory, hostedFactory: @escaping HostedFactory,
         acceptsVerification: @escaping (URL) -> Bool, now: @escaping () -> Date = Date.init) throws {
        guard WalletMountOwnership.acquire(identity) else { throw PaymentActionError.alreadyAttempted }
        self.identity = identity
        self.orderID = orderID
        self.client = client
        self.store = store
        self.handlers = handlers
        self.sheetFactory = sheetFactory
        self.hostedFactory = hostedFactory
        self.acceptsVerification = acceptsVerification
        self.now = now
    }

    func start() {
        guard active, !started else { return }
        started = true
        read()
    }

    func unmount() {
        guard active else { return }
        active = false
        surface?.unmount()
        surface = nil
        pending = nil
        client.finish()
        WalletMountOwnership.release(identity)
    }

    deinit { unmount() }

    private func read() {
        client.send("READ_SUBMISSION", fields: [:], key: nil) { [weak self] result in
            self?.apply(Self.decode(result))
        }
    }

    private static func decode(_ result: Result<[String: Any], Error>) -> Result<WalletActionResponse, Error> {
        result.flatMap { json in Result { try WalletActionResponse(json) } }
    }

    private func install(_ make: () throws -> MeldProviderSession) rethrows {
        let created = try make()
        if active { surface = created } else { created.unmount() }
    }

    private func apply(_ result: Result<WalletActionResponse, Error>) {
        guard active else { return }
        guard case .success(let response) = result else {
            fail("PAYMENT_STATE_UNAVAILABLE", "Payment state is unavailable. Review the existing order before trying another payment.")
            return
        }
        do {
            if response.state != .notStarted { try store.observeSubmission() }
            switch response.state {
            case .notStarted:
                guard !(try store.record()).submissionStarted else {
                    fail("PAYMENT_OUTCOME_UNKNOWN", "A payment was already attempted. Review the existing order.")
                    return
                }
                sheetActive = true
                try install {
                    try sheetFactory({ [weak self] payment, completion in
                        guard let self, self.active else { completion(ApplePayProcessOutcome(events: [], succeeded: false)); return }
                        self.submit(payment, completion: completion)
                    }, { [weak self] in self?.sheetFinished() })
                }
            case .submitted:
                pendingStatus()
                guard active else { return }
                unmount()
                handlers.onPaymentSubmitted?(orderID)
            case .verificationRequired:
                guard let verification = response.verification, acceptsVerification(verification.url) else {
                    fail("INVALID_VERIFICATION", "The verification response cannot be presented."); return
                }
                guard verification.expiresAt > now() else {
                    fail("VERIFICATION_WINDOW_EXPIRED", "The verification window expired. Review the existing order."); return
                }
                guard !(try store.record()).verificationOpened else {
                    fail("WAIT_FOR_PAYMENT", "Verification was already opened. Track the existing order's payment status."); return
                }
                pendingStatus()
                guard active else { return }
                try install {
                    try hostedFactory(verification, { [weak self] in
                        guard let self, self.active else { return false }
                        guard verification.expiresAt > self.now() else {
                            self.fail("VERIFICATION_WINDOW_EXPIRED", "The verification window expired. Review the existing order.")
                            return false
                        }
                        do { try self.store.claimVerification(); return true }
                        catch { self.fail("VERIFICATION_UNAVAILABLE", "Review the existing order before continuing."); return false }
                    }, { [weak self] opened in
                        guard let self, self.active else { return }
                        self.surface = nil
                        if opened { self.read() }
                        else {
                            self.unmount()
                            self.handlers.onCancel?(self.orderID)
                        }
                    })
                }
            case .inProgress, .unknown:
                pendingStatus()
                fail("PAYMENT_OUTCOME_UNKNOWN", "The payment is being resolved. Track the existing order without submitting again.")
            case .expired:
                pendingStatus()
                fail("VERIFICATION_WINDOW_EXPIRED", "The verification window expired. Review the existing order.")
            case .failed:
                fail("PAYMENT_REJECTED", "The payment attempt failed. Review the order before starting another payment.")
            }
        } catch {
            fail("PAYMENT_CONTINUATION_UNAVAILABLE", "The existing order cannot be continued on this device right now.")
        }
    }

    private func submit(_ payment: WalletPayment, completion: @escaping (ApplePayProcessOutcome) -> Void) {
        guard !didAuthorize else { completion(ApplePayProcessOutcome(events: [], succeeded: false)); return }
        didAuthorize = true
        let fields: [String: Any]
        let key: UUID
        do {
            fields = try payment.actionFields()
            key = try store.claimSubmission()
        } catch {
            completion(ApplePayProcessOutcome(events: [], succeeded: false))
            fail("PAYMENT_NOT_SUBMITTED", "Payment details or attempt state could not be validated. Review the existing order.")
            return
        }
        submitting = true
        client.send("SUBMIT_WALLET_PAYMENT", fields: fields, key: key) { [weak self] result in
            guard let self, self.active else { completion(ApplePayProcessOutcome(events: [], succeeded: false)); return }
            let decoded = Self.decode(result)
            if case .failure = decoded {
                // A lost or malformed response is ambiguous. Recovery is a read, never another submission.
                self.client.send("READ_SUBMISSION", fields: [:], key: nil) { [weak self] read in
                    guard let self else { completion(ApplePayProcessOutcome(events: [], succeeded: false)); return }
                    self.completeSubmission(Self.decode(read), completion: completion)
                }
            } else { self.completeSubmission(decoded, completion: completion) }
        }
    }

    private func completeSubmission(_ result: Result<WalletActionResponse, Error>,
                                    completion: @escaping (ApplePayProcessOutcome) -> Void) {
        guard active else { completion(ApplePayProcessOutcome(events: [], succeeded: false)); return }
        submitting = false
        pending = result
        let accepted: Bool
        if case .success(let response) = result {
            accepted = response.state == .submitted || response.state == .verificationRequired
        } else { accepted = false }
        completion(ApplePayProcessOutcome(events: [], succeeded: accepted))
        if !sheetActive { drain() }
    }

    private func sheetFinished() {
        guard active else { return }
        sheetActive = false
        surface = nil
        if pending != nil { drain() }
        else if !submitting { unmount() }
    }

    private func drain() {
        guard active, let result = pending else { return }
        pending = nil
        apply(result)
    }

    private func pendingStatus() {
        handlers.onStatusChange?(MeldStatusChange(orderId: orderID, status: .pending, providerStatus: nil, raw: nil))
    }

    private func fail(_ code: String, _ message: String) {
        guard active else { return }
        unmount()
        handlers.onError?(MeldError(orderId: orderID, code: code, message: message, recoverable: false))
    }
}
