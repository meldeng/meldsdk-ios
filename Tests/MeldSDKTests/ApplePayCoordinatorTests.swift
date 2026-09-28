import Contacts
import PassKit
import XCTest
@testable import MeldSDK

final class ApplePayCoordinatorTests: XCTestCase {
    func testEmailIsRequestedAsAContactFieldAndReadFromTheShippingContact() {
        for (shipping, expected) in [("customer@example.test", "customer@example.test"), (" ", "fallback@example.test"),
                                     (nil, "fallback@example.test")] as [(String?, String)] {
            let harness = CoordinatorHarness()
            harness.coordinator.present()
            harness.drain()
            XCTAssertEqual(harness.sheet.request?.requiredBillingContactFields, [.name, .postalAddress])
            XCTAssertEqual(harness.sheet.request?.requiredShippingContactFields, [.emailAddress])
            harness.authorize(FakePayment(shippingEmail: shipping))
            XCTAssertEqual(harness.payments.first?.email, expected, String(describing: shipping))
        }
    }

    func testPassKitCompletesBeforeTheStatusAndTheSubmissionReachTheIntegrator() {
        let harness = CoordinatorHarness(gated: true)
        harness.outcome = ApplePayResponseInterpreter.interpret(httpStatus: 200, json: ["data": ["status": "new"]], orderId: "test-order")
        harness.coordinator.present()
        harness.drain()
        harness.authorize(FakePayment(shippingEmail: "customer@example.test"))
        XCTAssertEqual(harness.log, ["ready", "passkit:success", "status:pending", "submitted", "dismiss"])
        XCTAssertEqual(harness.finished, 1)
    }

    func testUnmountFromTheSubmissionCallbackFollowsThePassKitResult() {
        let harness = CoordinatorHarness(gated: true)
        harness.outcome = ApplePayResponseInterpreter.interpret(httpStatus: 200, json: ["data": ["status": "new"]], orderId: "test-order")
        harness.onSubmitted = { harness.log.append("unmount"); harness.coordinator.unmount() }
        harness.coordinator.present()
        harness.drain()
        harness.authorize(FakePayment(shippingEmail: "customer@example.test"))
        XCTAssertEqual(harness.log, ["ready", "passkit:success", "status:pending", "submitted", "unmount", "dismiss"])
        XCTAssertEqual(harness.finished, 1)
    }

    func testASheetThatNeverPresentedFinishesWithoutADismissal() {
        let harness = CoordinatorHarness(gated: true)
        harness.sheet.presented = false
        harness.sheet.completesDismissal = false
        harness.coordinator.present()
        harness.drain()
        XCTAssertEqual(harness.log, ["error:APPLE_PAY_UNAVAILABLE"])
        XCTAssertEqual(harness.finished, 1)
    }

    func testUnmountBeforeAFailedPresentationStillFinishes() {
        let harness = CoordinatorHarness(gated: true)
        harness.sheet.presented = nil
        harness.sheet.completesDismissal = false
        harness.coordinator.present()
        harness.coordinator.unmount()
        XCTAssertEqual(harness.log, ["dismiss"])
        XCTAssertEqual(harness.finished, 0)
        harness.sheet.presentCompletion?(false)
        harness.drain()
        XCTAssertEqual(harness.finished, 1)
        XCTAssertEqual(harness.log, ["dismiss"])
    }
}

private final class CoordinatorHarness {
    let sheet = FakeSheet()
    var coordinator: ApplePayCoordinator!
    var outcome = ApplePayProcessOutcome(events: [], succeeded: true)
    var payments: [WalletPayment] = []
    var log: [String] = []
    var finished = 0
    var onSubmitted: (() -> Void)?

    init(gated: Bool = false) {
        let handlers = MeldEventHandlers(onReady: { [weak self] _ in self?.log.append("ready") },
            onPaymentSubmitted: { [weak self] _ in self?.log.append("submitted"); self?.onSubmitted?() },
            onStatusChange: { [weak self] in self?.log.append("status:\($0.status.rawValue)") },
            onCancel: { [weak self] _ in self?.log.append("cancel") },
            onError: { [weak self] in self?.log.append("error:\($0.code)") })
        coordinator = ApplePayCoordinator(
            orderId: "test-order", merchantIdentifier: "merchant.example.test",
            request: MeldApplePayRequest(amount: 15, currencyCode: "EUR", email: "fallback@example.test"),
            merchantCountryCode: "LT", supportedNetworks: [.visa, .masterCard], merchantCapabilities: [.threeDSecure],
            handlers: gated ? handlers.gated() : handlers,
            process: { [weak self] payment, done in
                self?.payments.append(payment)
                done(self?.outcome ?? ApplePayProcessOutcome(events: [], succeeded: false))
            },
            onFinished: { [weak self] in self?.finished += 1 },
            makeController: { [sheet] in sheet.request = $0; return sheet })
        sheet.onDismiss = { [weak self] in self?.log.append("dismiss") }
    }

    func authorize(_ payment: PKPayment) {
        coordinator.paymentAuthorizationController(PKPaymentAuthorizationController(paymentRequest: PKPaymentRequest()),
                                                   didAuthorizePayment: payment) { [weak self] result in
            self?.log.append(result.status == .success ? "passkit:success" : "passkit:failure")
        }
        drain()
    }

    func drain() {
        let drained = XCTestExpectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        XCTWaiter().wait(for: [drained], timeout: 2)
    }
}

private final class FakeSheet: ApplePaySheetControlling {
    weak var delegate: PKPaymentAuthorizationControllerDelegate?
    var request: PKPaymentRequest?
    var presented: Bool? = true
    var presentCompletion: ((Bool) -> Void)?
    var completesDismissal = true
    var onDismiss: (() -> Void)?

    func present(completion: ((Bool) -> Void)?) {
        presentCompletion = completion
        if let presented { completion?(presented) }
    }

    func dismiss(completion: (() -> Void)?) {
        onDismiss?()
        if completesDismissal { completion?() }
    }
}

private final class FakePayment: PKPayment {
    private let fakeToken = FakeToken()
    private let billing: PKContact
    private let shipping: PKContact?

    init(shippingEmail: String?) {
        billing = PKContact()
        var name = PersonNameComponents()
        name.givenName = "Test"
        name.familyName = "Customer"
        billing.name = name
        let address = CNMutablePostalAddress()
        address.street = "1 Test Street"
        address.city = "Vilnius"
        address.postalCode = "12345"
        address.isoCountryCode = "lt"
        billing.postalAddress = address
        billing.emailAddress = "billing-contact@example.test"
        shipping = shippingEmail.map { email in
            let contact = PKContact()
            contact.emailAddress = email
            return contact
        }
        super.init()
    }

    override var token: PKPaymentToken { fakeToken }
    override var billingContact: PKContact? { billing }
    override var shippingContact: PKContact? { shipping }
}

private final class FakeToken: PKPaymentToken {
    override var paymentData: Data { Data("synthetic-wallet-token".utf8) }
}
