import PassKit
import UIKit
import XCTest
@testable import MeldSDK

@MainActor
final class StripeFlowControllerTests: XCTestCase {
    func testNewPaymentOwnsFormsAndSdkFlowAndWaitsForServerSettlement() async throws {
        let h = try FlowHarness(applePay: true)
        h.driver.hasAccountResult = false
        h.client.responses = FlowHarness.bootstrap + [FlowHarness.customer(), FlowHarness.payment(), FlowHarness.payment(), FlowHarness.read("IN_PROGRESS", "WAIT_FOR_PROVIDER")]
        let outcome = try await h.flow.run()
        XCTAssertEqual(outcome, .pending)
        XCTAssertEqual(h.driver.calls, ["hasAccount", "register", "authorize", "confirmIdentity", "registerWallet", "collectPayment", "createPaymentToken", "checkout"])
        XCTAssertEqual(h.forms.calls, ["email", "registration"])
        XCTAssertTrue(h.store.value.submissionStarted)
        XCTAssertEqual(h.driver.collectedRequest?.merchantIdentifier, "merchant.example.stripe")
        XCTAssertEqual(h.driver.collectedRequest?.currencyCode, "USD")
        XCTAssertEqual(h.driver.collectedRequest?.paymentSummaryItems.last?.amount, NSDecimalNumber(value: 20))
        XCTAssertEqual(h.client.calls.map(\.operation), ["READ_SUBMISSION", "PREPARE_CUSTOMER_AUTHORIZATION", "COMPLETE_CUSTOMER_LINK", "READ_CUSTOMER_STATUS", "CREATE_PAYMENT_SESSION", "CONFIRM_PAYMENT", "READ_SUBMISSION"])
        await h.flow.close()
        XCTAssertEqual(h.driver.logouts, 1)
    }

    func testResumeRestoresAuthenticationAndUsesOnlyTheExistingSession() async throws {
        let h = try FlowHarness()
        h.client.responses = [FlowHarness.resume(), FlowHarness.authToken, FlowHarness.customer(next: "REFRESH_QUOTE"),
                              FlowHarness.payment(), FlowHarness.payment(), FlowHarness.read("SUBMITTED", "WAIT_FOR_PAYMENT")]
        let outcome = try await h.flow.run()
        XCTAssertEqual(outcome, .submitted)
        XCTAssertEqual(h.driver.calls, ["authenticate", "checkout"])
        XCTAssertFalse(h.client.calls.contains { $0.operation == "CREATE_PAYMENT_SESSION" })
        XCTAssertTrue(h.store.value.submissionStarted)
        XCTAssertTrue(h.forms.calls.isEmpty)
        await h.flow.close()
    }

    func testSeamlessFailureFallsBackToOrderBoundInteractiveConsent() async throws {
        let h = try FlowHarness()
        h.driver.failAuthentication = true
        h.client.responses = [FlowHarness.resume(), FlowHarness.authToken] + Array(FlowHarness.bootstrap.dropFirst()) +
            [FlowHarness.customer(next: "REFRESH_QUOTE"), FlowHarness.payment(), FlowHarness.payment(), FlowHarness.read("SUCCEEDED", "COMPLETE")]
        let outcome = try await h.flow.run()
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(h.driver.calls, ["authenticate", "hasAccount", "authorize", "checkout"])
        XCTAssertFalse(h.client.calls.contains { $0.fields["email"] != nil || $0.fields["sessionHandle"] != nil })
        await h.flow.close()
    }

    func testKycCollectionDocumentVerificationAndAddressConfirmationPrecedePayment() async throws {
        let h = try FlowHarness()
        h.driver.updateAddress = true
        h.client.responses = FlowHarness.bootstrap + [FlowHarness.customer("NOT_STARTED", next: "SDK_COLLECT_KYC"),
            FlowHarness.customer("PENDING", next: "RETRY"), FlowHarness.customer("REJECTED", next: "SDK_VERIFY_IDENTITY"),
            FlowHarness.customer(), FlowHarness.payment(), FlowHarness.payment(), FlowHarness.read("SUBMITTED", "WAIT_FOR_PAYMENT")]
        let outcome = try await h.flow.run()
        XCTAssertEqual(outcome, .submitted)
        XCTAssertEqual(h.forms.calls, ["email", "disclosure", "identity", "address"])
        XCTAssertEqual(h.driver.calls.filter { ["attachIdentity", "verifyIdentity", "confirmIdentity"].contains($0) },
                       ["attachIdentity", "verifyIdentity", "confirmIdentity", "confirmIdentity"])
        await h.flow.close()
    }

    func testFailedReceiptWriteNeverOpensIdentityOrPaymentAndRetriesTheSameKey() async throws {
        let h = try FlowHarness()
        h.client.legalWriteFailure = PaymentActionError.transport
        h.client.responses = FlowHarness.bootstrap + [FlowHarness.customer("NOT_STARTED", next: "SDK_COLLECT_KYC")]
        do { _ = try await h.flow.run(); XCTFail("Receipt must be durable before collection") }
        catch PaymentActionError.transport {}
        XCTAssertEqual(h.forms.calls, ["email", "disclosure"])
        XCTAssertFalse(h.driver.calls.contains("attachIdentity"))
        XCTAssertFalse(h.store.value.submissionStarted)
        let writes = h.client.calls.filter { $0.operation == "RECORD_LEGAL_EVIDENCE" }
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes.first?.key, writes.last?.key)
        await h.flow.close()
    }

    func testDeclinedDisclosureRecordsDecisionAndStopsBeforeIdentityCollection() async throws {
        let h = try FlowHarness()
        h.forms.acceptsDisclosure = false
        h.client.responses = FlowHarness.bootstrap + [FlowHarness.customer("NOT_STARTED", next: "SDK_COLLECT_KYC")]
        let outcome = try await h.flow.run()
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(h.client.legalReceipt?["result"] as? String, "DECLINED")
        XCTAssertEqual(h.forms.calls, ["email", "disclosure"])
        XCTAssertFalse(h.driver.calls.contains("attachIdentity"))
        XCTAssertFalse(h.store.value.submissionStarted)
        await h.flow.close()
    }

    func testPendingVerificationStopsBeforeCollectingOrClaimingPayment() async throws {
        let h = try FlowHarness()
        h.client.responses = FlowHarness.bootstrap + Array(repeating: FlowHarness.customer("PENDING", next: "RETRY"), count: 12)
        let outcome = try await h.flow.run()
        XCTAssertEqual(outcome, .verificationPending)
        XCTAssertFalse(h.store.value.submissionStarted)
        XCTAssertFalse(h.driver.calls.contains("collectPayment"))
        await h.flow.close()
    }

    func testSubmissionReadPreventsNativeWorkForExistingFinancialOutcomes() async throws {
        for (status, next, expected): (String, String, StripeFlowController.Outcome) in [
            ("SUCCEEDED", "COMPLETE", .completed), ("SUBMITTED", "WAIT_FOR_PAYMENT", .submitted),
            ("IN_PROGRESS", "WAIT_FOR_PROVIDER", .pending), ("UNKNOWN", "WAIT_FOR_PROVIDER", .pending)] {
            let h = try FlowHarness()
            h.client.responses = [FlowHarness.read(status, next)]
            let result = try await h.flow.run()
            XCTAssertEqual(result, expected)
            XCTAssertEqual(h.factory.value, 0)
            XCTAssertTrue(h.driver.calls.isEmpty)
            await h.flow.close()
        }
    }

    func testDeviceFenceAndUnavailableReadCannotOpenPaymentUi() async throws {
        let h = try FlowHarness()
        h.store.value.submissionStarted = true
        h.client.responses = [FlowHarness.bootstrap[0]]
        do { _ = try await h.flow.run(); XCTFail("Expected device fence") }
        catch PaymentActionError.alreadyAttempted { }
        XCTAssertEqual(h.factory.value, 0)
        await h.flow.close()
        let malformed = try FlowHarness()
        malformed.client.responses = [.success(["version": 1, "status": "NOT_STARTED", "nextStep": "NONE"])]
        do { _ = try await malformed.flow.run(); XCTFail("Expected malformed read rejection") } catch { }
        XCTAssertEqual(malformed.factory.value, 0)
        await malformed.flow.close()
    }

    func testLostCreateResponseRetriesTheSameTokenAndMutationKey() async throws {
        let h = try FlowHarness()
        h.client.responses = FlowHarness.bootstrap + [FlowHarness.customer(), .failure(PaymentActionError.transport),
            FlowHarness.payment(), FlowHarness.payment(), FlowHarness.read("SUBMITTED", "WAIT_FOR_PAYMENT")]
        _ = try await h.flow.run()
        let creates = h.client.calls.filter { $0.operation == "CREATE_PAYMENT_SESSION" }
        XCTAssertEqual(creates.count, 2)
        XCTAssertEqual(creates[0].key, creates[1].key)
        XCTAssertEqual(creates[0].fields["paymentToken"] as? String, creates[1].fields["paymentToken"] as? String)
        XCTAssertEqual(creates[0].key, h.store.value.submissionKey)
        XCTAssertEqual(h.driver.calls.filter { $0 == "createPaymentToken" }.count, 1)
        await h.flow.close()
    }

    func testActualCheckoutCallbacksGetDistinctKeysAndTransportRetriesReuseTheirPair() async throws {
        let h = try FlowHarness()
        h.driver.checkoutCallbacks = 2
        h.client.responses = FlowHarness.bootstrap + [FlowHarness.customer(), FlowHarness.payment(),
            .failure(PaymentActionError.transport), FlowHarness.payment(), FlowHarness.payment(), FlowHarness.read("SUBMITTED", "WAIT_FOR_PAYMENT")]
        _ = try await h.flow.run()
        let calls = h.client.calls.filter { $0.operation == "CONFIRM_PAYMENT" }
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[0].key, calls[1].key)
        XCTAssertEqual(calls[0].fields["callbackInvocationId"] as? String, calls[1].fields["callbackInvocationId"] as? String)
        XCTAssertNotEqual(calls[1].key, calls[2].key)
        XCTAssertNotEqual(calls[1].fields["callbackInvocationId"] as? String, calls[2].fields["callbackInvocationId"] as? String)
        await h.flow.close()
    }

    func testCheckoutKycRecoveryNeverCollectsASecondTokenOrCreatesAnotherSession() async throws {
        let h = try FlowHarness()
        h.client.responses = FlowHarness.bootstrap + [FlowHarness.customer(), FlowHarness.payment(),
            FlowHarness.payment("REJECTED", next: "SDK_VERIFY_IDENTITY", secret: false), FlowHarness.customer(next: "NONE"),
            FlowHarness.payment(), FlowHarness.payment(), FlowHarness.read("SUBMITTED", "WAIT_FOR_PAYMENT")]
        let outcome = try await h.flow.run()
        XCTAssertEqual(outcome, .submitted)
        XCTAssertEqual(h.driver.calls.filter { $0 == "createPaymentToken" }.count, 1)
        XCTAssertEqual(h.driver.calls.filter { $0 == "checkout" }.count, 2)
        XCTAssertEqual(h.driver.calls.filter { $0 == "verifyIdentity" }.count, 1)
        XCTAssertEqual(h.client.calls.filter { $0.operation == "CREATE_PAYMENT_SESSION" }.count, 1)
        XCTAssertEqual(h.client.calls.filter { $0.operation == "REFRESH_QUOTE" }.count, 1)
        await h.flow.close()
    }

    func testUnmountDuringNativeWorkSuppressesLaterBackendMutationsAndLogsOut() async throws {
        let h = try FlowHarness()
        h.driver.onHasAccount = { h.lifetime.close() }
        h.client.responses = [FlowHarness.bootstrap[0]]
        do { _ = try await h.flow.run(); XCTFail("Expected cancellation") } catch { }
        XCTAssertEqual(h.client.calls.map(\.operation), ["READ_SUBMISSION"])
        XCTAssertEqual(h.driver.calls, ["hasAccount"])
        await h.flow.close()
        XCTAssertEqual(h.driver.logouts, 1)
    }

    func testForeignCheckoutCallbackCannotReachBackend() async throws {
        let h = try FlowHarness()
        h.driver.callbackSession = "cos_other"
        h.client.responses = FlowHarness.bootstrap + [FlowHarness.customer(), FlowHarness.payment()]
        do { _ = try await h.flow.run(); XCTFail("Expected bound-session rejection") } catch { }
        XCTAssertFalse(h.client.calls.contains { $0.operation == "CONFIRM_PAYMENT" })
        await h.flow.close()
    }

    func testCancellationBeforePaymentLeavesNoFinancialClaim() async throws {
        let h = try FlowHarness()
        h.driver.cancelCollection = true
        h.client.responses = FlowHarness.bootstrap + [FlowHarness.customer()]
        let outcome = try await h.flow.run()
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(h.store.value.submissionStarted)
        XCTAssertFalse(h.client.calls.contains { $0.operation == "CREATE_PAYMENT_SESSION" })
        await h.flow.close()
    }

    func testFormValidationRejectsMalformedDatesAndContactData() {
        XCTAssertFalse(StripeFormField.birthday.valid("2001-02-29"))
        XCTAssertTrue(StripeFormField.birthday.valid("2000-02-29"))
        XCTAssertFalse(StripeFormField.birthday.valid("9999-01-01"))
        XCTAssertFalse(StripeFormField.email.valid("x\n@example.test"))
        XCTAssertFalse(StripeFormField.phone.valid("5551234"))
        XCTAssertTrue(StripeFormField.phone.valid("+12025550123"))
        XCTAssertFalse(StripeFormField.state.valid("California"))
        XCTAssertTrue(StripeFormField.postalCode.valid("00000-0000"))
    }

    func testMountedFormsAreDismissedAndCallbacksSuppressedOnUnmount() async throws {
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        let root = UIViewController(), window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let client = FlowClient(), driver = FlowDriver()
        client.responses = [FlowHarness.bootstrap[0]]
        var ready = 0, terminal = 0
        let session = try StripePaymentSession(order: FlowHarness.order(), host: root.view, request: nil,
            handlers: MeldEventHandlers(onReady: { _ in ready += 1 }, onPaymentSubmitted: { _ in terminal += 1 },
                onStatusChange: { _ in terminal += 1 }, onCancel: { _ in terminal += 1 }, onError: { _ in terminal += 1 }),
            client: client, store: FlowStore(), factory: { try await StripeSdkRuntime.open(ownership: StripeSdkOwnership()) { driver } })
        for _ in 0..<100 {
            if root.presentedViewController?.presentedViewController != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(ready, 1)
        XCTAssertNotNil(root.presentedViewController?.presentedViewController)
        session.unmount()
        for _ in 0..<100 {
            if driver.logouts == 1, root.presentedViewController == nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(root.presentedViewController)
        XCTAssertEqual(driver.logouts, 1)
        XCTAssertEqual(terminal, 0)
        XCTAssertEqual(client.calls.map(\.operation), ["READ_SUBMISSION"])
    }

    func testUnmountFromReadyHandlerPreventsStateReadAndSdkCreation() async throws {
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        let root = UIViewController(), window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let client = FlowClient(), counter = FlowCounter(), driver = FlowDriver()
        var ready = false
        var handle: MeldWidgetHandle?
        let session = try StripePaymentSession(order: FlowHarness.order(), host: root.view, request: nil,
            handlers: MeldEventHandlers(onReady: { _ in ready = true; handle?.unmount() }), client: client, store: FlowStore(),
            factory: { counter.value += 1; return try await StripeSdkRuntime.open(ownership: StripeSdkOwnership()) { driver } })
        handle = MeldWidgetHandle(mode: "native-sdk", session: session)
        for _ in 0..<100 {
            if ready, root.presentedViewController == nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(ready)
        XCTAssertTrue(client.calls.isEmpty)
        XCTAssertEqual(counter.value, 0)
        XCTAssertNil(root.presentedViewController)
    }

    func testDismissingBeforeSubmissionReadResolvesReportsPendingWithoutAssumingCancellation() async throws {
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        let root = UIViewController(), window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let client = FlowClient(), counter = FlowCounter(), driver = FlowDriver()
        client.delay = true
        var cancelled = 0, pending = 0
        let session = try StripePaymentSession(order: FlowHarness.order(), host: root.view, request: nil,
            handlers: MeldEventHandlers(onStatusChange: { status in
                XCTAssertEqual(status.status, .pending); pending += 1
            }, onCancel: { _ in cancelled += 1 }), client: client, store: FlowStore(),
            factory: { counter.value += 1; return try await StripeSdkRuntime.open(ownership: StripeSdkOwnership()) { driver } })
        for _ in 0..<100 {
            if client.delayed != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let navigation = try XCTUnwrap(root.presentedViewController as? UINavigationController)
        let cancel = try XCTUnwrap(navigation.topViewController?.navigationItem.leftBarButtonItem)
        UIApplication.shared.sendAction(try XCTUnwrap(cancel.action), to: cancel.target, from: nil, for: nil)
        client.delayed?(FlowHarness.bootstrap[0]); client.delayed = nil
        for _ in 0..<100 {
            if root.presentedViewController == nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(pending, 1)
        XCTAssertEqual(cancelled, 0)
        XCTAssertEqual(counter.value, 0)
        XCTAssertNil(root.presentedViewController)
        session.unmount()
    }
}

@MainActor
private final class FlowHarness {
    let client = FlowClient(), store = FlowStore(), driver = FlowDriver(), forms = FlowForms()
    let lifetime = StripeFlowLifetime(), factory = FlowCounter()
    let flow: StripeFlowController
    init(applePay: Bool = false) throws {
        let order = try Self.order(applePay: applePay)
        let counter = factory, driver = driver
        let request = applePay ? try order.paymentRequest() : nil
        flow = StripeFlowController(order: order, client: client, store: store, forms: forms, lifetime: lifetime, request: request,
                                   factory: {
            counter.value += 1
            return try await StripeSdkRuntime.open(ownership: StripeSdkOwnership()) { driver }
        }, pause: {})
    }
    static let bootstrap: [Result<[String: Any], Error>] = [
        .success(["version": 1, "status": "NOT_STARTED", "nextStep": "NONE", "sdk": ["authenticationState": "BOOTSTRAP"]]),
        .success(["version": 1, "status": "READY", "nextStep": "SDK_AUTHORIZE", "sdk": ["authenticationState": "REAUTHORIZE", "authorizationHandle": "lai_synthetic", "expiresAt": "2030-01-01T00:00:00Z"]]),
        .success(["version": 1, "status": "VERIFIED", "nextStep": "CREATE_PAYMENT_SESSION"])
    ]
    static let authToken: Result<[String: Any], Error> = .success(["version": 1, "status": "READY", "nextStep": "SDK_AUTHORIZE", "sdk": ["clientSecret": "latcs_synthetic", "expiresAt": "2030-01-01T00:00:00Z"]])
    static func read(_ status: String, _ next: String) -> Result<[String: Any], Error> {
        .success(["version": 1, "status": status, "nextStep": next])
    }
    static func resume() -> Result<[String: Any], Error> {
        .success(["version": 1, "status": "READY", "nextStep": "REFRESH_QUOTE", "sdk": ["authenticationState": "RESTORE", "sessionHandle": "cos_synthetic"]])
    }
    static func customer(_ status: String = "VERIFIED", next: String = "CREATE_PAYMENT_SESSION") -> Result<[String: Any], Error> {
        .success(["version": 1, "status": status, "nextStep": next, "customer": ["missingFields": [], "highestVerifiedTier": "L1", "tiers": []]])
    }
    static func payment(_ status: String = "REQUIRES_PAYMENT", next: String = "CONFIRM_PAYMENT", secret: Bool = true) -> Result<[String: Any], Error> {
        var sdk = ["sessionHandle": "cos_synthetic"]
        if secret { sdk["clientSecret"] = "cos_synthetic_secret" }
        return .success(["version": 1, "status": status, "nextStep": next, "sdk": sdk])
    }
    static func order(applePay: Bool = false) throws -> StripeNativeOrder {
        let json: [String: Any] = ["id": "synthetic-order", "paymentMethodType": applePay ? "APPLE_PAY" : "CREDIT_DEBIT_CARD",
            "headlessPresentation": ["surface": "NATIVE_SDK", "protocol": "STRIPE_CRYPTO_ONRAMP", "version": 1],
            "payload": ["serviceProvider": "TEST_PROVIDER", "sourceAmount": 20, "sourceCurrencyCode": "USD", "countryCode": "US", "destinationWalletAddress": "wallet-synthetic"],
            "paymentMethodResponseDetails": ["sdkBootstrapType": "STRIPE_CRYPTO_ONRAMP", "providerIntentId": "lai_synthetic", "sdkFlow": "AUTHORIZE", "sdkEnvironment": "SANDBOX", "expiresAtEpochSeconds": 1_900_000_000, "continuationToken": "synthetic-bearer", "clientConfiguration": ["publicKey": "pk_test_synthetic", "walletNetwork": "base", "merchantIdentifier": "merchant.example.stripe"]],
            "paymentActions": ["version": 1, "endpoint": "/crypto/order/headless/onramp/TEST_PROVIDER/synthetic-order/actions", "bearerTokenPointer": "/paymentMethodResponseDetails/continuationToken",
                "operations": ["READ_SUBMISSION", "READ_CUSTOMER_STATUS", "READ_LIMITS", "READ_LEGAL_DISCLOSURE", "RECORD_LEGAL_EVIDENCE", "COMPLETE_CUSTOMER_LINK", "CREATE_CUSTOMER_AUTH_TOKEN", "PREPARE_CUSTOMER_AUTHORIZATION", "CREATE_PAYMENT_SESSION", "CONFIRM_PAYMENT", "REFRESH_QUOTE"].map { ["operation": $0, "idempotencyKeyRequired": !$0.hasPrefix("READ_")] as [String: Any] }]]
        return try StripeNativeOrder(MeldOrder.from(jsonData: JSONSerialization.data(withJSONObject: json)), environment: .sandbox)
    }
}

private final class FlowCounter { var value = 0 }
private final class FlowClient: PaymentActionSending {
    struct Call { let operation: String; let fields: [String: Any]; let key: UUID? }
    var calls: [Call] = []
    var responses: [Result<[String: Any], Error>] = []
    var delay = false
    var delayed: ((Result<[String: Any], Error>) -> Void)?
    var legalReceipt: [String: Any]?
    var legalWriteFailure: Error?
    func send(_ operation: String, fields: [String: Any], key: UUID?, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        calls.append(Call(operation: operation, fields: fields, key: key))
        if operation == "READ_LEGAL_DISCLOSURE" {
            completion(.success(LegalConsentFixtures.read(legalReceipt))); return
        }
        if operation == "RECORD_LEGAL_EVIDENCE" {
            if let legalWriteFailure { completion(.failure(legalWriteFailure)); return }
            guard let key, let evidence = fields["legalEvidence"] as? [String: Any], let result = evidence["result"] as? String
            else { XCTFail("Missing receipt identity"); completion(.failure(PaymentActionError.invalidRequest)); return }
            legalReceipt = LegalConsentFixtures.receipt(key, result: result)
            completion(.success(LegalConsentFixtures.recorded(legalReceipt!))); return
        }
        if delay { delayed = completion; return }
        guard !responses.isEmpty else { XCTFail("Unexpected action \(operation)"); completion(.failure(PaymentActionError.invalidResponse)); return }
        completion(responses.removeFirst())
    }
    func finish() {}
}
private final class FlowStore: WalletAttemptStoring {
    var value = WalletAttemptRecord()
    func record() throws -> WalletAttemptRecord { value }
    func claimSubmission() throws -> UUID {
        guard !value.submissionStarted else { throw PaymentActionError.alreadyAttempted }
        value.submissionStarted = true; return value.submissionKey
    }
    func claimVerification() throws { value.verificationOpened = true }
    func observeSubmission() throws { value.submissionStarted = true }
}
@MainActor
private final class FlowForms: StripeFlowPresenting {
    let presenter = UIViewController()
    var calls: [String] = []
    var acceptsDisclosure = true
    func disclosure(_ value: LegalDisclosure) async throws -> Bool { calls.append("disclosure"); return acceptsDisclosure }
    func email() async throws -> String { calls.append("email"); return "customer@example.test" }
    func registration() async throws -> StripeRegistrationInput { calls.append("registration"); return StripeRegistrationInput(name: nil, phone: "+12025550123") }
    func identity(fields: [String]) async throws -> StripeIdentityInput { calls.append("identity"); return StripeIdentityInput() }
    func address() async throws -> StripeAddressInput { calls.append("address"); return StripeAddressInput(line1: "Synthetic", line2: nil, city: "Synthetic", state: "CA", postalCode: "00000", country: "US") }
    func showProgress(_ message: String) {}
    func close() {}
}
@MainActor
private final class FlowDriver: StripeSdkDriving {
    var calls: [String] = []
    var hasAccountResult = true, failAuthentication = false, updateAddress = false, cancelCollection = false
    var checkoutCallbacks = 1, logouts = 0
    var callbackSession: String?
    var onHasAccount: (() -> Void)?
    var collectedRequest: PKPaymentRequest?
    func hasAccount(email: String) async throws -> Bool { calls.append("hasAccount"); onHasAccount?(); return hasAccountResult }
    func register(email: String, name: String?, phone: String, country: String) async throws { calls.append("register") }
    func authorize(intent: String, from presenter: UIViewController) async throws -> String { calls.append("authorize"); return "crc_synthetic" }
    func authenticate(secret: String) async throws { calls.append("authenticate"); if failAuthentication { throw StripeNativeError.authorizationRequired } }
    func attachIdentity(_ input: StripeIdentityInput) async throws { calls.append("attachIdentity") }
    func verifyIdentity(from presenter: UIViewController) async throws { calls.append("verifyIdentity") }
    func confirmIdentity(address: StripeAddressInput?, from presenter: UIViewController) async throws -> StripeKycConfirmation {
        calls.append("confirmIdentity"); if updateAddress { updateAddress = false; return .updateAddress }; return .confirmed
    }
    func registerWallet(address: String, network: String) async throws { calls.append("registerWallet") }
    func collectPayment(request: PKPaymentRequest?, from presenter: UIViewController) async throws {
        collectedRequest = request
        calls.append("collectPayment"); if cancelCollection { throw StripeNativeError.cancelled }
    }
    func createPaymentToken() async throws -> String { calls.append("createPaymentToken"); return "cpt_synthetic" }
    func checkout(session: String, from presenter: UIViewController, secret: @escaping @MainActor (String) async throws -> String) async throws {
        calls.append("checkout")
        for _ in 0..<checkoutCallbacks { _ = try await secret(callbackSession ?? session) }
    }
    func logOut() async throws { logouts += 1 }
}
