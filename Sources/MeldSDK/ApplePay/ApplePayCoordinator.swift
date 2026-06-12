import Contacts
import Foundation
import os.log
import PassKit

/// Drives a native Apple Pay payment for a Mercuryo Apple Pay order: builds the `PKPaymentRequest`,
/// presents the sheet, and on authorization posts the encrypted token to the order's `/process`
/// endpoint, mapping the result onto Meld events. It conforms to `MeldProviderSession` so the same
/// `MeldWidgetHandle.unmount()` tears it down (dismisses the sheet) as for widget surfaces.
///
/// The sheet is a modal native surface, not a view we mount — so this is reached via
/// `Meld.presentApplePay`, not `Meld.mount`.
final class ApplePayCoordinator: NSObject, PKPaymentAuthorizationControllerDelegate, MeldProviderSession {
    private let orderId: String?
    private let merchantIdentifier: String
    private let merchantTransactionId: String
    private let request: MeldApplePayRequest
    private let handlers: MeldEventHandlers
    private let client: MercuryoApplePayClient

    private var controller: PKPaymentAuthorizationController?
    private var didAuthorize = false
    // PassKit holds its delegate weakly and nothing else retains us for the sheet's lifetime, so we
    // keep a strong self-reference from present() until the sheet finishes or is dismissed.
    private var selfRetain: ApplePayCoordinator?

    init(orderId: String?,
         merchantIdentifier: String,
         merchantTransactionId: String,
         request: MeldApplePayRequest,
         handlers: MeldEventHandlers,
         client: MercuryoApplePayClient) {
        self.orderId = orderId
        self.merchantIdentifier = merchantIdentifier
        self.merchantTransactionId = merchantTransactionId
        self.request = request
        self.handlers = handlers
        self.client = client
    }

    func present() {
        let pkRequest = PKPaymentRequest()
        pkRequest.merchantIdentifier = merchantIdentifier
        pkRequest.merchantCapabilities = request.merchantCapabilities
        pkRequest.supportedNetworks = request.supportedNetworks
        pkRequest.countryCode = request.countryCode
        pkRequest.currencyCode = request.currencyCode
        // We need the cardholder name + billing address for the provider's /process call.
        pkRequest.requiredBillingContactFields = [.name, .postalAddress]
        pkRequest.paymentSummaryItems = [
            PKPaymentSummaryItem(
                label: request.summaryItemLabel,
                amount: NSDecimalNumber(decimal: request.amount)),
        ]

        let controller = PKPaymentAuthorizationController(paymentRequest: pkRequest)
        controller.delegate = self
        self.controller = controller
        self.selfRetain = self
        controller.present { [weak self] presented in
            guard let self else { return }
            DispatchQueue.main.async {
                if presented {
                    self.handlers.onReady?(self.orderId)
                } else {
                    self.emitError(code: "APPLE_PAY_UNAVAILABLE",
                                   message: MeldApplePayError.unavailable.errorDescription ?? "unavailable",
                                   recoverable: false)
                    self.cleanup()
                }
            }
        }
    }

    func unmount() {
        controller?.dismiss(completion: nil)
        cleanup()
    }

    // MARK: - PKPaymentAuthorizationControllerDelegate

    func paymentAuthorizationController(
        _ controller: PKPaymentAuthorizationController,
        didAuthorizePayment payment: PKPayment,
        handler completion: @escaping (PKPaymentAuthorizationResult) -> Void
    ) {
        didAuthorize = true

        guard let name = payment.billingContact?.name,
              let firstName = name.givenName, !firstName.isEmpty,
              let lastName = name.familyName, !lastName.isEmpty else {
            emitError(code: "MISSING_BILLING_NAME",
                      message: "Apple Pay did not return a cardholder name required to process the payment.",
                      recoverable: false)
            completion(PKPaymentAuthorizationResult(status: .failure, errors: nil))
            return
        }

        let postal = payment.billingContact?.postalAddress
        let billing = ApplePayProcessBody.BillingAddress(
            // CNPostalAddress.isoCountryCode is lowercase ("us"); the backend wants ISO alpha-2 caps.
            countryCode: postal?.isoCountryCode.uppercased(),
            // CNPostalAddress.street is a single (possibly multi-line) field — map it to line 1.
            streetLine1: postal?.street,
            streetLine2: nil,
            stateCode: postal?.state,
            city: postal?.city,
            zipCode: postal?.postalCode)

        let body = ApplePayProcessBody.make(
            payTokenBase64: payment.token.paymentData.base64EncodedString(),
            merchantTransactionId: merchantTransactionId,
            walletAddress: request.walletAddress,
            clientIpAddress: request.clientIpAddress,
            firstName: firstName,
            lastName: lastName,
            email: request.email,
            billing: billing)

        client.process(body: body) { [weak self] result in
            guard let self else {
                completion(PKPaymentAuthorizationResult(status: .failure, errors: nil))
                return
            }
            DispatchQueue.main.async {
                switch result {
                case let .success((status, json)):
                    let outcome = ApplePayResponseInterpreter.interpret(
                        httpStatus: status, json: json, orderId: self.orderId)
                    outcome.events.forEach(self.dispatch)
                    completion(PKPaymentAuthorizationResult(
                        status: outcome.succeeded ? .success : .failure, errors: nil))
                case let .failure(error):
                    // Transport-level failure — the payment may or may not have gone through, so
                    // it's recoverable (retry) and not a terminal decline.
                    self.emitError(code: "PROCESS_FAILED", message: error.localizedDescription, recoverable: true)
                    completion(PKPaymentAuthorizationResult(status: .failure, errors: nil))
                }
            }
        }
    }

    func paymentAuthorizationControllerDidFinish(_ controller: PKPaymentAuthorizationController) {
        controller.dismiss(completion: nil)
        // Finishing without ever authorizing means the user dismissed the sheet.
        if !didAuthorize { handlers.onCancel?(orderId) }
        cleanup()
    }

    // MARK: - Helpers

    private func dispatch(_ event: MeldEvent) {
        switch event {
        case .ready: handlers.onReady?(orderId)
        case .paymentSubmitted: handlers.onPaymentSubmitted?(orderId)
        case let .statusChange(change): handlers.onStatusChange?(change)
        case .cancel: handlers.onCancel?(orderId)
        case let .error(error): handlers.onError?(error)
        }
    }

    private func emitError(code: String, message: String, recoverable: Bool) {
        handlers.onError?(MeldError(orderId: orderId, code: code, message: message, recoverable: recoverable))
    }

    private func cleanup() {
        controller = nil
        selfRetain = nil
    }
}
