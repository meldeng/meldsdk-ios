import Contacts
import Foundation
import PassKit

/// Presents PassKit and collects wallet data. The adapter's processor owns transport and recovery.
final class ApplePayCoordinator: NSObject, PKPaymentAuthorizationControllerDelegate, MeldProviderSession {
    private let orderId: String?
    private let merchantIdentifier: String
    private let request: MeldApplePayRequest
    private let merchantCountryCode: String
    private let supportedNetworks: [PKPaymentNetwork]
    private let merchantCapabilities: PKMerchantCapability
    private let handlers: MeldEventHandlers
    private let process: (WalletPayment, @escaping (ApplePayProcessOutcome) -> Void) -> Void
    private let onFinished: () -> Void
    private var controller: PKPaymentAuthorizationController?
    private var didAuthorize = false
    private var active = true
    private var closing = false
    private var finished = false
    // PassKit holds its delegate weakly; retain until dismissal completes.
    private var selfRetain: ApplePayCoordinator?

    init(orderId: String?, merchantIdentifier: String, request: MeldApplePayRequest,
         merchantCountryCode: String, supportedNetworks: [PKPaymentNetwork],
         merchantCapabilities: PKMerchantCapability, handlers: MeldEventHandlers,
         process: @escaping (WalletPayment, @escaping (ApplePayProcessOutcome) -> Void) -> Void,
         onFinished: @escaping () -> Void) {
        self.orderId = orderId
        self.merchantIdentifier = merchantIdentifier
        self.request = request
        self.merchantCountryCode = merchantCountryCode
        self.supportedNetworks = supportedNetworks
        self.merchantCapabilities = merchantCapabilities
        self.handlers = handlers
        self.process = process
        self.onFinished = onFinished
    }

    func present() {
        guard active, controller == nil else { return }
        let pkRequest = PKPaymentRequest()
        pkRequest.merchantIdentifier = merchantIdentifier
        pkRequest.merchantCapabilities = merchantCapabilities
        pkRequest.supportedNetworks = supportedNetworks
        pkRequest.countryCode = merchantCountryCode
        pkRequest.currencyCode = request.currencyCode
        pkRequest.requiredBillingContactFields = [.name, .postalAddress, .emailAddress]
        pkRequest.paymentSummaryItems = [PKPaymentSummaryItem(label: request.summaryItemLabel,
                                                             amount: NSDecimalNumber(decimal: request.amount))]
        let controller = PKPaymentAuthorizationController(paymentRequest: pkRequest)
        controller.delegate = self
        self.controller = controller
        selfRetain = self
        controller.present { [weak self] presented in
            DispatchQueue.main.async {
                guard let self, self.active else { return }
                if presented { self.handlers.onReady?(self.orderId) }
                else {
                    self.emitError(code: "APPLE_PAY_UNAVAILABLE", message: "Apple Pay is not available on this device.")
                    self.finishSheet()
                }
            }
        }
    }

    func unmount() {
        active = false
        finishSheet()
    }

    func paymentAuthorizationController(_ controller: PKPaymentAuthorizationController,
                                        didAuthorizePayment payment: PKPayment,
                                        handler completion: @escaping (PKPaymentAuthorizationResult) -> Void) {
        guard active, !didAuthorize else {
            completion(PKPaymentAuthorizationResult(status: .failure, errors: nil)); return
        }
        didAuthorize = true
        // Simulator tokens are empty; no request is sent without a real encrypted wallet token.
        guard !payment.token.paymentData.isEmpty else {
            reject("EMPTY_APPLE_PAY_TOKEN", "Apple Pay returned an empty payment token. Test Apple Pay on a real device.", completion)
            return
        }
        guard let name = payment.billingContact?.name,
              let firstName = name.givenName, !firstName.isEmpty,
              let lastName = name.familyName, !lastName.isEmpty else {
            reject("MISSING_BILLING_NAME", "Apple Pay did not return a cardholder name required to process payment.", completion)
            return
        }
        let postal = payment.billingContact?.postalAddress
        // PassKit returns one multiline street; the action contract has two control-free lines.
        let streets = postal?.street.components(separatedBy: .newlines).filter { !$0.isEmpty } ?? []
        let billing = ApplePayProcessBody.BillingAddress(
            countryCode: postal?.isoCountryCode.uppercased(), streetLine1: streets.first,
            streetLine2: streets.count > 1 ? streets.dropFirst().joined(separator: ", ") : nil,
            stateCode: postal?.state, city: postal?.city, zipCode: postal?.postalCode)
        let wallet = WalletPayment(token: payment.token.paymentData.base64EncodedString(),
                                   firstName: firstName, lastName: lastName,
                                   email: payment.billingContact?.emailAddress?.nonBlank ?? request.email,
                                   billing: billing)
        process(wallet) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self, self.active else {
                    completion(PKPaymentAuthorizationResult(status: .failure, errors: nil)); return
                }
                for event in outcome.events where self.active { self.dispatch(event) }
                completion(PKPaymentAuthorizationResult(status: outcome.succeeded ? .success : .failure, errors: nil))
                self.finishSheet()
            }
        }
    }

    func paymentAuthorizationControllerDidFinish(_ controller: PKPaymentAuthorizationController) {
        if active, !didAuthorize { handlers.onCancel?(orderId) }
        finishSheet()
    }

    private func reject(_ code: String, _ message: String,
                        _ completion: (PKPaymentAuthorizationResult) -> Void) {
        emitError(code: code, message: message)
        completion(PKPaymentAuthorizationResult(status: .failure, errors: nil))
        finishSheet()
    }

    private func dispatch(_ event: MeldEvent) {
        switch event {
        case .ready: handlers.onReady?(orderId)
        case .paymentSubmitted: handlers.onPaymentSubmitted?(orderId)
        case let .statusChange(change): handlers.onStatusChange?(change)
        case .cancel: handlers.onCancel?(orderId)
        case let .error(error): handlers.onError?(error)
        }
    }

    private func emitError(code: String, message: String) {
        guard active else { return }
        handlers.onError?(MeldError(orderId: orderId, code: code, message: message, recoverable: false))
    }

    private func finishSheet() {
        guard !closing, !finished else { return }
        closing = true
        if let controller { controller.dismiss { [self] in cleanup() } }
        else { cleanup() }
    }

    private func cleanup() {
        guard !finished else { return }
        finished = true
        active = false
        controller = nil
        selfRetain = nil
        onFinished()
    }
}

private extension String {
    var nonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
