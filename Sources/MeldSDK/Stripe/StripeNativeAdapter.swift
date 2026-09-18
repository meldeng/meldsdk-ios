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
    private let screen = StripeProgressViewController()
    private let navigation: UINavigationController
    private let flow: StripeFlowController
    private let orderID: String
    private let handlers: MeldEventHandlers
    private var task: Task<Void, Never>?

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
        navigation = UINavigationController(rootViewController: screen)
        navigation.modalPresentationStyle = .pageSheet; navigation.isModalInPresentation = true
        orderID = order.id; self.handlers = handlers
        let forms = StripeForms(presenter: screen, progress: { [weak screen] in screen?.message.text = $0 })
        flow = StripeFlowController(order: order, client: client ?? PaymentActionClient(descriptor: order.actions),
                                    store: store ?? WalletAttemptStore(identity: order.actions.identity), forms: forms,
                                    lifetime: lifetime, request: request,
                                    factory: factory ?? { try await StripeSdkRuntime.open { try await StripeSdkDriver.create(publicKey: order.publicKey) } })
        screen.onCancel = { [weak self] in self?.cancel() }
        // Asynchronous presentation lets mount return its lifecycle handle before any callbacks.
        DispatchQueue.main.async { [weak self, weak presenter] in
            guard let self, self.lifetime.active, let presenter else { return }
            presenter.present(self.navigation, animated: true) { [weak self] in self?.start() }
        }
    }

    private func start() {
        guard lifetime.active, task == nil else { return }
        lifetime.ifActive { handlers.onReady?(orderID) }
        guard lifetime.active else { return }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await self.flow.run()
                self.lifetime.ifActive { self.emit(outcome) }
            } catch {
                self.lifetime.ifActive {
                    self.handlers.onError?(MeldError(orderId: self.orderID, code: "PAYMENT_CONTINUATION_UNAVAILABLE",
                        message: "This payment could not be continued. Review the existing order before trying again.",
                        recoverable: false, headlessError: MeldHeadlessError.from(error)))
                }
            }
            await self.stop()
        }
    }

    private func emit(_ outcome: StripeFlowController.Outcome) {
        switch outcome {
        case .cancelled: handlers.onCancel?(orderID)
        case .completed: handlers.onStatusChange?(MeldStatusChange(orderId: orderID, status: .completed, providerStatus: nil, raw: nil))
        case .submitted:
            handlers.onStatusChange?(MeldStatusChange(orderId: orderID, status: .pending, providerStatus: nil, raw: nil))
            if lifetime.active { handlers.onPaymentSubmitted?(orderID) }
        case .pending, .verificationPending:
            handlers.onStatusChange?(MeldStatusChange(orderId: orderID, status: .pending, providerStatus: nil, raw: nil))
        }
    }

    private func cancel() {
        guard lifetime.active else { return }
        lifetime.ifActive { emit(flow.mayHaveFinancialAttempt ? .pending : .cancelled) }
        lifetime.close()
        Task { await stop() }
    }

    nonisolated func unmount() {
        lifetime.close()
        Task { @MainActor in await self.stop() }
    }

    private func stop() async {
        lifetime.close()
        navigation.dismiss(animated: false)
        await flow.close()
    }
}

@MainActor
private final class StripeProgressViewController: UIViewController {
    let message = UILabel()
    var onCancel: (() -> Void)?
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Crypto purchase"; view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        message.text = "Preparing your payment"; message.numberOfLines = 0; message.textAlignment = .center
        message.font = .preferredFont(forTextStyle: .body); message.adjustsFontForContentSizeCategory = true
        message.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(message)
        NSLayoutConstraint.activate([message.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            message.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            message.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)])
    }
    @objc private func cancel() { onCancel?() }
}
