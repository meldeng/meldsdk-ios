import Foundation
import PassKit

/// The wallet protocol uses the common action transport and lifecycle. Mercuryo-specific PassKit
/// configuration and verification origins stay inside this adapter.
struct MercuryoApplePayAdapter: MeldAdapter {
    let label = "Mercuryo Apple Pay (APPLE_PAY / native sheet)"
    let capabilities = MeldCapabilities(embeddable: false, surface: "native-applepay", requiresUserGesture: true)
    let presentations = [MeldAdapterPresentation("APPLE_PAY", "NATIVE_TOKEN", "MELD_WALLET_TOKEN")]

    func acceptsDeclaredOrder(_ order: MeldOrder) -> Bool {
        order.hasCompatibleLegacyPresentation("NATIVE_TOKEN") && hasWalletDetails(order)
            && (try? actionDescriptor(order)) != nil
    }

    func matches(_ order: MeldOrder) -> Bool {
        guard order.paymentMethodType == "APPLE_PAY" else { return false }
        switch order.presentation {
        case .providerHosted, .vendorSdk: return false
        case .nativeToken, .unrecognized, .none: return true
        }
    }

    func mount(order: MeldOrder, context: MeldMountContext, handlers: MeldEventHandlers) throws -> MeldProviderSession {
        guard hasWalletDetails(order) else {
            throw MeldApplePayError.invalidOrder("Apple Pay order needs a sessionToken, merchantTransactionId and merchantIdentifier.")
        }
        // An explicit but invalid action descriptor must never fall back to a guessed legacy URL.
        if order.raw["paymentActions"] != nil || order.headlessPresentation != nil {
            let descriptor = try actionDescriptor(order)
            let session = try WalletPaymentSession(
                identity: descriptor.identity, orderID: order.id,
                client: PaymentActionClient(descriptor: descriptor), store: WalletAttemptStore(identity: descriptor.identity),
                handlers: handlers, sheetFactory: { process, finished in
                    let coordinator = try makeSheet(order, context, handlers, process: process, finished: finished)
                    coordinator.present()
                    return coordinator
                }, hostedFactory: { verification, open, close in
                    try HostedVerificationPresenter(verification: verification, host: context.host, onOpen: open, onClose: close)
                }, acceptsVerification: Self.acceptsVerification)
            // Let Meld.mount return its handle before any lifecycle events can be delivered.
            DispatchQueue.main.async { [weak session] in session?.start() }
            return session
        }
        return try mountLegacy(order, context, handlers)
    }

    private func hasWalletDetails(_ order: MeldOrder) -> Bool {
        ["sessionToken", "merchantTransactionId", "merchantIdentifier"].allSatisfy {
            (order.paymentMethodResponseDetails?[$0] as? String)?.isEmpty == false
        }
    }

    private func actionDescriptor(_ order: MeldOrder) throws -> PaymentActionDescriptor {
        let descriptor = try PaymentActionDescriptor(order: order, environment: Meld.environment)
        guard descriptor.operations["SUBMIT_WALLET_PAYMENT"] == true,
              descriptor.operations["READ_SUBMISSION"] == false else { throw PaymentActionError.invalidDescriptor }
        return descriptor
    }

    static func acceptsVerification(_ url: URL) -> Bool {
        let hosts = Set(MercuryoCardAdapter.allowedOrigins.compactMap { URL(string: $0)?.host })
        return MeldPresentationURL.https(url.absoluteString, hosts: hosts)
    }

    private func makeSheet(_ order: MeldOrder, _ context: MeldMountContext, _ handlers: MeldEventHandlers,
                           process: @escaping (WalletPayment, @escaping (ApplePayProcessOutcome) -> Void) -> Void,
                           finished: @escaping () -> Void) throws -> ApplePayCoordinator {
        guard let request = context.applePay, request.amount > 0,
              request.currencyCode.range(of: "\\A[A-Z]{3}\\z", options: .regularExpression) != nil,
              let merchant = order.paymentMethodResponseDetails?["merchantIdentifier"] as? String else {
            throw MeldApplePayError.invalidOrder("A new wallet payment needs a MeldApplePayRequest with the order's amount and currency.")
        }
        guard Meld.canPresentApplePay() else { throw MeldApplePayError.unavailable }
        // Mercuryo's merchant is in LT and supports Visa/Mastercard with 3DS, credit and debit.
        return ApplePayCoordinator(orderId: order.id, merchantIdentifier: merchant, request: request,
                                   merchantCountryCode: "LT", supportedNetworks: [.visa, .masterCard],
                                   merchantCapabilities: [.threeDSecure, .credit, .debit], handlers: handlers,
                                   process: process, onFinished: finished)
    }

    private func mountLegacy(_ order: MeldOrder, _ context: MeldMountContext,
                             _ handlers: MeldEventHandlers) throws -> MeldProviderSession {
        guard let id = order.id, !id.isEmpty, let request = context.applePay,
              !request.walletAddress.isEmpty, !request.clientIpAddress.isEmpty else {
            throw MeldApplePayError.invalidOrder("Legacy Apple Pay needs an order id, wallet address and client IP in MeldApplePayRequest.")
        }
        let identity = PaymentActionDescriptor.baseURL(Meld.environment)
            + "/crypto/order/headless/onramp/\(order.serviceProvider ?? "MERCURYO")/\(id)/actions"
        let store = WalletAttemptStore(identity: identity)
        guard !(try store.record()).submissionStarted, WalletMountOwnership.acquire(identity) else {
            throw PaymentActionError.alreadyAttempted
        }
        let client = MercuryoApplePayClient(environment: Meld.environment,
                                            sessionToken: order.paymentMethodResponseDetails?["sessionToken"] as! String)
        do {
            let coordinator = try makeSheet(order, context, handlers, process: { payment, completion in
                do { _ = try payment.actionFields(); _ = try store.claimSubmission() }
                catch {
                    completion(ApplePayProcessOutcome(events: [.error(MeldError(orderId: id, code: "PAYMENT_NOT_SUBMITTED",
                        message: "Payment details or attempt state could not be validated. Review the existing order.",
                        recoverable: false))], succeeded: false))
                    return
                }
                let body = ApplePayProcessBody.make(payTokenBase64: payment.token,
                    merchantTransactionId: order.paymentMethodResponseDetails?["merchantTransactionId"] as! String,
                    walletAddress: request.walletAddress, clientIpAddress: request.clientIpAddress,
                    firstName: payment.firstName, lastName: payment.lastName, email: payment.email, billing: payment.billing)
                client.process(body: body) { result in
                    switch result {
                    case .success(let (status, json)):
                        completion(ApplePayResponseInterpreter.interpret(httpStatus: status, json: json, orderId: id))
                    case .failure:
                        completion(ApplePayProcessOutcome(events: [.error(MeldError(orderId: id, code: "PAYMENT_OUTCOME_UNKNOWN",
                            message: "Payment outcome is unknown. Track the existing order without submitting again.",
                            recoverable: false))], succeeded: false))
                    }
                }
            }, finished: { client.finish(); WalletMountOwnership.release(identity) })
            coordinator.present()
            return coordinator
        } catch {
            client.finish()
            WalletMountOwnership.release(identity)
            throw error
        }
    }
}
