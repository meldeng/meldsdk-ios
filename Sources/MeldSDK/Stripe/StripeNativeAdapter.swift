import UIKit
import PassKit

struct StripeNativeAdapter: MeldAdapter {
    let label = "Native crypto onramp (Apple Pay / card)"
    let capabilities = MeldCapabilities(embeddable: false, surface: "native-sdk", requiresUserGesture: true)
    let presentations = ["APPLE_PAY", "CREDIT_DEBIT_CARD"].map {
        MeldAdapterPresentation($0, "NATIVE_SDK", "STRIPE_CRYPTO_ONRAMP")
    }

    func acceptsDeclaredOrder(_ order: MeldOrder) -> Bool { (try? StripeNativeOrder(order, environment: Meld.environment)) != nil }
    func matches(_ order: MeldOrder) -> Bool { false }

    func mount(order: MeldOrder, context: MeldMountContext, handlers: MeldEventHandlers) throws -> MeldProviderSession {
        guard Thread.isMainThread else { throw StripeNativeError.unavailable }
        let native = try StripeNativeOrder(order, environment: Meld.environment)
        let request = native.method == "APPLE_PAY" ? try native.paymentRequest(context.applePay) : nil
        return try MainActor.assumeIsolated {
            try StripePaymentSession(order: native, host: context.host, request: request, handlers: handlers)
        }
    }
}

@MainActor
final class StripePaymentSession: MeldProviderSession {
    nonisolated private let lifetime = StripeFlowLifetime()
    private let flow: StripeFlowController
    /// The host's top-most screen at mount. Everything presented over it during the session is the SDK's or Stripe's.
    private weak var anchor: UIViewController?
    private let forms: StripeForms
    private let orderID: String
    private let handlers: MeldEventHandlers
    private var task: Task<Void, Never>?
    private var cancelling = false
    private var stopped = false
    private var presentationsCleared = false

    init(order: StripeNativeOrder, host: UIView?, request: PKPaymentRequest?, handlers: MeldEventHandlers,
         client: PaymentActionSending? = nil, store: WalletAttemptStoring? = nil,
         factory: (@MainActor () async throws -> StripeSdkRuntime)? = nil) throws {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap(\.windows).filter(\.isKeyWindow)
        guard let root = host?.window?.rootViewController ?? (windows.count == 1 ? windows.first?.rootViewController : nil)
        else { throw StripeNativeError.unavailable }
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        guard presenter.viewIfLoaded?.window != nil, !presenter.isBeingDismissed else { throw StripeNativeError.unavailable }
        orderID = order.id; self.handlers = handlers; anchor = presenter
        let forms = StripeForms(root: { [weak root] in root })
        self.forms = forms
        flow = StripeFlowController(order: order, client: client ?? PaymentActionClient(descriptor: order.actions),
                                    store: store ?? WalletAttemptStore(identity: order.actions.identity), forms: forms,
                                    lifetime: lifetime, request: request,
                                    factory: factory ?? { try await StripeSdkRuntime.open { try await StripeSdkDriver.create(publicKey: order.publicKey) } })
        forms.onCancelWhileBusy = { [weak self] in self?.cancel() }
        // Mount returns its lifecycle handle before any callbacks. Nothing is shown until the flow needs the customer.
        DispatchQueue.main.async { [weak self] in self?.start() }
    }

    private func start() {
        guard lifetime.active, task == nil else { return }
        lifetime.ifActive { handlers.onReady?(orderID) }
        guard lifetime.active else { return }
        task = Task { [weak self] in
            guard let self else { return }
            let result: Result<StripeFlowController.Outcome, Error>
            do { result = .success(try await self.flow.run()) } catch { result = .failure(error) }
            // Cleared first, so whatever the host presents from a terminal callback stays up.
            await self.dismissPresented()
            guard !self.cancelling else { return }
            self.lifetime.ifActive {
                switch result {
                case let .success(outcome): self.emit(outcome)
                case let .failure(error):
                    self.handlers.onError?(Self.failure(error, mayHaveFinancialAttempt: self.flow.mayHaveFinancialAttempt,
                                                        orderId: self.orderID))
                }
            }
            await self.stop()
        }
    }

    private func emit(_ outcome: StripeFlowController.Outcome) {
        let events = Self.events(for: outcome, mayHaveFinancialAttempt: flow.mayHaveFinancialAttempt, orderId: orderID)
        for event in events where lifetime.active {
            switch event {
            case .ready: handlers.onReady?(orderID)
            case .paymentSubmitted: handlers.onPaymentSubmitted?(orderID)
            case let .statusChange(change): handlers.onStatusChange?(change)
            case .cancel: handlers.onCancel?(orderID)
            case let .error(error): handlers.onError?(error)
            }
        }
    }

    static func events(for outcome: StripeFlowController.Outcome, mayHaveFinancialAttempt: Bool, orderId: String) -> [MeldEvent] {
        let pending = MeldEvent.statusChange(MeldStatusChange(orderId: orderId, status: .pending, providerStatus: nil, raw: nil))
        let declined = { (detail: String) in
            MeldEvent.error(MeldError(orderId: orderId, code: MeldErrorCode.paymentRejected,
                message: "The payment was declined. Choose another payment option.", detail: detail, recoverable: false))
        }
        switch outcome {
        case .cancelled: return [.cancel]
        case .completed: return [.statusChange(MeldStatusChange(orderId: orderId, status: .completed, providerStatus: nil, raw: nil))]
        case .submitted: return [pending, .paymentSubmitted]
        case .rejected: return [declined("submission:FAILED")]
        case let .refused(refusal): return [declined(refusal.rawValue)]
        case .expired:
            return [.error(MeldError(orderId: orderId, code: MeldErrorCode.paymentRejected,
                message: "The payment expired before it completed. Choose another payment option.", detail: "submission:EXPIRED",
                recoverable: false))]
        case .verificationRequired:
            return [.error(MeldError(orderId: orderId, code: MeldErrorCode.verificationPending,
                message: "The provider needs more verification before this purchase. No payment was attempted.",
                detail: "create:VERIFICATION_REQUIRED", recoverable: false))]
        case .verificationPending where !mayHaveFinancialAttempt:
            return [.error(MeldError(orderId: orderId, code: MeldErrorCode.verificationPending,
                message: "The provider is reviewing the customer's verification. No payment was attempted.", recoverable: false))]
        case .pending, .verificationPending:
            return [pending, .error(MeldError(orderId: orderId, code: MeldErrorCode.paymentOutcomeUnknown,
                message: "The payment outcome is not known yet. Track the existing order without paying again.", recoverable: false))]
        }
    }

    static func failure(_ error: Error, mayHaveFinancialAttempt: Bool, orderId: String) -> MeldError {
        let raw = error as NSError
        let detail: String
        switch error {
        case let PaymentActionError.action(code): detail = "action:\(code.rawValue)"
        case is StripeNativeError, is PaymentActionError: detail = String(describing: error)
        default: detail = MeldDebugError.describe(error)
        }
        guard mayHaveFinancialAttempt else {
            return MeldError(orderId: orderId, code: MeldErrorCode.presentationFailed,
                             message: "This payment could not be started. No payment was attempted.", detail: detail, recoverable: false)
        }
        return MeldError(orderId: orderId, code: MeldErrorCode.paymentOutcomeUnknown,
                         message: "This payment could not be continued. Review the existing order before trying again.",
                         detail: detail, recoverable: false)
    }

    nonisolated func unmount() {
        lifetime.close()
        Task { @MainActor in await self.stop() }
    }

    /// The customer cancelled a busy form: what the old host sheet's Cancel did, at any point in the flow.
    private func cancel() {
        guard lifetime.active, !cancelling else { return }
        cancelling = true
        let outcome: StripeFlowController.Outcome = flow.mayHaveFinancialAttempt ? .pending : .cancelled
        Task {
            await dismissPresented()
            lifetime.ifActive { emit(outcome) }
            await stop()
        }
    }

    private func stop() async {
        guard !stopped else { return }
        stopped = true
        lifetime.close()
        await dismissPresented()
        await flow.close()
        handlers.sessionEnded?(orderID)
    }

    /// Whatever the SDK or Stripe presented over the screen that was top-most at mount.
    private func dismissPresented() async {
        guard !presentationsCleared else { return }
        presentationsCleared = true
        forms.close()
        guard let anchor else { return }
        for _ in 0..<40 where anchor.presentedViewController?.isBeingDismissed == true {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard anchor.presentedViewController != nil else { return }
        await withCheckedContinuation { done in anchor.dismiss(animated: false) { done.resume() } }
    }
}
