import XCTest
@testable import MeldSDK

final class WalletPaymentSessionTests: XCTestCase {
    func testAuthoritativeSubmissionAdviceReachesCallbackWithoutARecoveryRequest() throws {
        for advice in [MeldHeadlessError(category: .authenticationRequired, recovery: .authenticate),
                       .init(category: .invalidRequest, recovery: .correctRequest),
                       .init(category: .requirementRequired, recovery: .readRequirements),
                       .init(category: .orderRejected, recovery: .stop)] {
            let flow = try WalletHarness()
            defer { flow.session.unmount() }
            flow.session.start()
            flow.client.respond(0, WalletFixtures.response("NOT_STARTED"))
            flow.authorize()
            flow.client.complete(1, .failure(PaymentActionError.headless(advice)))
            XCTAssertTrue(flow.errors.isEmpty, "Wait for the wallet sheet to close")
            flow.sheetFinished?()
            XCTAssertEqual(flow.client.operations, ["READ_SUBMISSION", "SUBMIT_WALLET_PAYMENT"])
            XCTAssertEqual(flow.errors.first?.headlessError, advice)
            XCTAssertFalse(try XCTUnwrap(flow.errors.first).recoverable)
            XCTAssertTrue(flow.store.value.submissionStarted)
            XCTAssertEqual(flow.outcomes, [false])
        }
    }

    func testRecoveryReadFailurePreservesItsAuthoritativeAdvice() throws {
        let flow = try WalletHarness()
        defer { flow.session.unmount() }
        let advice = MeldHeadlessError(category: .authenticationRequired, recovery: .authenticate)
        flow.session.start()
        flow.client.respond(0, WalletFixtures.response("NOT_STARTED"))
        flow.authorize()
        flow.client.complete(1, .failure(PaymentActionError.headless(.fallback("SUBMIT_WALLET_PAYMENT"))))
        flow.client.complete(2, .failure(PaymentActionError.headless(advice)))
        flow.sheetFinished?()
        XCTAssertEqual(flow.client.operations, ["READ_SUBMISSION", "SUBMIT_WALLET_PAYMENT", "READ_SUBMISSION"])
        XCTAssertEqual(flow.errors.first?.headlessError, advice)
        XCTAssertTrue(flow.store.value.submissionStarted)
    }

    func testPreflightThenExactlyOneSubmissionWaitsForSheetDismissal() throws {
        let flow = try WalletHarness()
        defer { flow.session.unmount() }
        flow.session.start()
        flow.session.start()
        XCTAssertEqual(flow.client.operations, ["READ_SUBMISSION"])
        flow.client.respond(0, WalletFixtures.response("NOT_STARTED"))
        XCTAssertEqual(flow.sheets, 1)
        flow.authorize()
        flow.authorize()
        XCTAssertEqual(flow.client.operations, ["READ_SUBMISSION", "SUBMIT_WALLET_PAYMENT"])
        XCTAssertEqual(flow.client.requests[1].key, flow.store.value.submissionKey)
        XCTAssertTrue(flow.store.value.submissionStarted)
        flow.client.respond(1, WalletFixtures.response("SUBMITTED"))
        XCTAssertEqual(flow.outcomes, [false, true])
        XCTAssertEqual(flow.submitted, 0, "Submission UI must wait for PassKit dismissal")
        flow.sheetFinished?()
        XCTAssertEqual(flow.submitted, 1)
        XCTAssertEqual(flow.statuses.map(\.status), [.pending])
        XCTAssertNil(flow.statuses.first?.raw)
        XCTAssertEqual(flow.client.finished, 1)
    }

    func testLostOrMalformedSubmissionResponseOnlyReadsAndNeverResubmits() throws {
        for malformed in [false, true] {
            let flow = try WalletHarness()
            defer { flow.session.unmount() }
            flow.session.start()
            flow.client.respond(0, WalletFixtures.response("NOT_STARTED"))
            flow.authorize()
            if malformed { flow.client.respond(1, ["version": 1, "status": "NEW_UNKNOWN_STATE"]) }
            else { flow.client.complete(1, .failure(PaymentActionError.transport)) }
            XCTAssertEqual(flow.client.operations, ["READ_SUBMISSION", "SUBMIT_WALLET_PAYMENT", "READ_SUBMISSION"])
            flow.client.respond(2, WalletFixtures.response("NOT_STARTED"))
            flow.sheetFinished?()
            XCTAssertEqual(flow.sheets, 1)
            XCTAssertEqual(flow.errors.map(\.code), ["PAYMENT_OUTCOME_UNKNOWN"])
            XCTAssertFalse(try XCTUnwrap(flow.errors.first).recoverable)
        }
    }

    func testRemountWithDurableAttemptNeverPresentsAnotherWallet() throws {
        let store = MemoryWalletStore()
        let first = try WalletHarness(store: store)
        first.session.start()
        first.client.respond(0, WalletFixtures.response("NOT_STARTED"))
        first.authorize()
        first.session.unmount()
        let replay = try WalletHarness(identity: first.identity, store: store)
        defer { replay.session.unmount() }
        replay.session.start()
        replay.client.respond(0, WalletFixtures.response("NOT_STARTED"))
        XCTAssertEqual(replay.sheets, 0)
        XCTAssertEqual(replay.errors.map(\.code), ["PAYMENT_OUTCOME_UNKNOWN"])
        XCTAssertEqual(replay.client.operations, ["READ_SUBMISSION"])
    }

    func testEveryRecordedServerOutcomePreventsANewWalletSheet() throws {
        for state in ["SUBMITTED", "IN_PROGRESS", "UNKNOWN", "FAILED", "EXPIRED"] {
            let flow = try WalletHarness()
            defer { flow.session.unmount() }
            flow.session.start()
            flow.client.respond(0, WalletFixtures.response(state))
            XCTAssertEqual(flow.sheets, 0, state)
            XCTAssertTrue(flow.store.value.submissionStarted, state)
            XCTAssertEqual(flow.submitted, state == "SUBMITTED" ? 1 : 0, state)
            XCTAssertTrue(flow.errors.allSatisfy { !$0.recoverable })
        }
    }

    func testDuplicateMountsAreRejectedUntilOwnershipIsReleased() throws {
        let first = try WalletHarness()
        defer { first.session.unmount() }
        XCTAssertThrowsError(try WalletHarness(identity: first.identity))
        first.session.unmount()
        let second = try WalletHarness(identity: first.identity)
        second.session.unmount()
    }

    func testUnmountSuppressesLateReadAndSubmissionEventsButCompletesAuthorization() throws {
        let early = try WalletHarness()
        early.session.start()
        early.session.unmount()
        early.client.respond(0, WalletFixtures.response("NOT_STARTED"))
        XCTAssertEqual(early.sheets, 0)
        let flow = try WalletHarness()
        flow.session.start()
        flow.client.respond(0, WalletFixtures.response("NOT_STARTED"))
        flow.authorize()
        flow.session.unmount()
        flow.client.respond(1, WalletFixtures.response("VERIFICATION_REQUIRED"))
        XCTAssertEqual(flow.outcomes, [false])
        XCTAssertEqual(flow.hosted.count, 0)
        XCTAssertEqual(flow.submitted, 0)
        XCTAssertTrue(flow.errors.isEmpty)
        XCTAssertTrue(flow.statuses.isEmpty)
    }

    func testSheetDismissedDuringRequestStillResolvesTheExistingAttempt() throws {
        let flow = try WalletHarness()
        defer { flow.session.unmount() }
        flow.session.start()
        flow.client.respond(0, WalletFixtures.response("NOT_STARTED"))
        flow.authorize()
        flow.sheetFinished?()
        XCTAssertEqual(flow.client.finished, 0)
        flow.client.respond(1, WalletFixtures.response("SUBMITTED"))
        XCTAssertEqual(flow.submitted, 1)
    }

    func testBothVerificationDispositionsRequireConfirmationAndCanOpenOnlyOnce() throws {
        for disposition in ["RESUME_PAYMENT", "REPLACE_PAYMENT_IN_HOSTED_FLOW"] {
            let flow = try WalletHarness()
            defer { flow.session.unmount() }
            flow.session.start()
            flow.client.respond(0, WalletFixtures.response("VERIFICATION_REQUIRED", disposition: disposition))
            XCTAssertEqual(flow.sheets, 0)
            XCTAssertEqual(flow.hosted.first?.disposition.rawValue, disposition)
            XCTAssertFalse(flow.store.value.verificationOpened, "Receiving a link is not opening it")
            XCTAssertTrue(try XCTUnwrap(flow.openVerification)())
            XCTAssertTrue(flow.store.value.verificationOpened)
            flow.closeVerification?(true)
            XCTAssertEqual(flow.client.operations, ["READ_SUBMISSION", "READ_SUBMISSION"])
            flow.client.respond(1, WalletFixtures.response("VERIFICATION_REQUIRED", disposition: disposition))
            XCTAssertEqual(flow.hosted.count, 1)
            XCTAssertEqual(flow.errors.map(\.code), ["WAIT_FOR_PAYMENT"])
            XCTAssertEqual(flow.submitted, 0)
        }
    }

    func testVerificationAfterSubmissionWaitsUntilWalletSheetHasClosed() throws {
        let flow = try WalletHarness()
        defer { flow.session.unmount() }
        flow.session.start()
        flow.client.respond(0, WalletFixtures.response("NOT_STARTED"))
        flow.authorize()
        flow.client.respond(1, WalletFixtures.response("VERIFICATION_REQUIRED"))
        XCTAssertEqual(flow.outcomes, [true])
        XCTAssertEqual(flow.hosted.count, 0)
        flow.sheetFinished?()
        XCTAssertEqual(flow.hosted.count, 1)
        XCTAssertEqual(flow.submitted, 0)
    }

    func testCancellingVerificationDoesNotReadOrReopenIt() throws {
        let flow = try WalletHarness()
        flow.session.start()
        flow.client.respond(0, WalletFixtures.response("VERIFICATION_REQUIRED"))
        flow.closeVerification?(false)
        XCTAssertEqual(flow.cancelled, 1)
        XCTAssertEqual(flow.client.operations, ["READ_SUBMISSION"])
        XCTAssertFalse(flow.store.value.verificationOpened)
        XCTAssertEqual(flow.client.finished, 1)
        XCTAssertFalse(flow.openVerification?() ?? true)
    }

    func testExpiryIsCheckedBeforePresentationAndAgainAtTheUserGesture() throws {
        let expired = try WalletHarness()
        expired.session.start()
        expired.client.respond(0, WalletFixtures.response("VERIFICATION_REQUIRED", expires: WalletFixtures.now))
        XCTAssertEqual(expired.hosted.count, 0)
        XCTAssertEqual(expired.errors.map(\.code), ["VERIFICATION_WINDOW_EXPIRED"])
        let waiting = try WalletHarness()
        waiting.session.start()
        waiting.client.respond(0, WalletFixtures.response("VERIFICATION_REQUIRED"))
        waiting.now = WalletFixtures.now.addingTimeInterval(301)
        XCTAssertFalse(waiting.openVerification?() ?? true)
        XCTAssertFalse(waiting.store.value.verificationOpened)
        XCTAssertEqual(waiting.errors.map(\.code), ["VERIFICATION_WINDOW_EXPIRED"])
    }

    func testStorageFailureBlocksWalletAndVerificationActions() throws {
        let flow = try WalletHarness()
        flow.store.fail = true
        flow.session.start()
        flow.client.respond(0, WalletFixtures.response("NOT_STARTED"))
        XCTAssertEqual(flow.sheets, 0)
        XCTAssertEqual(flow.errors.map(\.code), ["PAYMENT_CONTINUATION_UNAVAILABLE"])
        let verification = try WalletHarness()
        verification.session.start()
        verification.client.respond(0, WalletFixtures.response("VERIFICATION_REQUIRED"))
        verification.store.fail = true
        XCTAssertFalse(verification.openVerification?() ?? true)
        XCTAssertEqual(verification.errors.map(\.code), ["VERIFICATION_UNAVAILABLE"])
    }

    func testInvalidWalletDataIsRejectedBeforeClaimOrNetworkMutation() throws {
        let flow = try WalletHarness()
        flow.session.start()
        flow.client.respond(0, WalletFixtures.response("NOT_STARTED"))
        let invalid = WalletPayment(token: "", firstName: "Test", lastName: "Customer", email: "test@example.com",
                                    billing: WalletFixtures.payment.billing)
        flow.submitWallet?(invalid, { flow.outcomes.append($0.succeeded) })
        XCTAssertEqual(flow.outcomes, [false])
        XCTAssertFalse(flow.store.value.submissionStarted)
        XCTAssertEqual(flow.client.operations, ["READ_SUBMISSION"])
        XCTAssertEqual(flow.errors.map(\.code), ["PAYMENT_NOT_SUBMITTED"])
    }

    func testReentrantUnmountFromStatusPreventsFurtherCallbacksOrSurfaces() throws {
        for state in ["SUBMITTED", "VERIFICATION_REQUIRED", "UNKNOWN"] {
            let flow = try WalletHarness()
            flow.onStatus = { [weak flow] in flow?.session.unmount() }
            flow.session.start()
            flow.client.respond(0, WalletFixtures.response(state))
            XCTAssertEqual(flow.submitted, 0)
            XCTAssertEqual(flow.hosted.count, 0)
            XCTAssertEqual(flow.errors.count, 0)
        }
    }

    func testUntrustedVerificationURLFailsWithoutOpeningASurface() throws {
        let flow = try WalletHarness()
        flow.session.start()
        var response = WalletFixtures.response("VERIFICATION_REQUIRED")
        var verification = response["verification"] as! [String: Any]
        verification["url"] = "https://attacker.example/payment?secret=synthetic"
        response["verification"] = verification
        flow.client.respond(0, response)
        XCTAssertEqual(flow.hosted.count, 0)
        XCTAssertEqual(flow.errors.map(\.code), ["INVALID_VERIFICATION"])
        XCTAssertNil(flow.errors.first?.detail)
        XCTAssertFalse(flow.errors.first?.message.contains("synthetic") ?? true)
    }
}

private final class WalletHarness {
    let identity: String
    let client = FakeActionClient()
    let store: MemoryWalletStore
    var session: WalletPaymentSession!
    var sheets = 0
    var hosted: [WalletVerification] = []
    var submitted = 0
    var cancelled = 0
    var outcomes: [Bool] = []
    var errors: [MeldError] = []
    var statuses: [MeldStatusChange] = []
    var now = WalletFixtures.now
    var onStatus: (() -> Void)?
    var submitWallet: ((WalletPayment, @escaping (ApplePayProcessOutcome) -> Void) -> Void)?
    var sheetFinished: (() -> Void)?
    var openVerification: (() -> Bool)?
    var closeVerification: ((Bool) -> Void)?

    init(identity: String = UUID().uuidString, store: MemoryWalletStore = MemoryWalletStore()) throws {
        self.identity = identity
        self.store = store
        session = try WalletPaymentSession(identity: identity, orderID: "test-order", client: client, store: store,
            handlers: MeldEventHandlers(onPaymentSubmitted: { [weak self] _ in self?.submitted += 1 },
                onStatusChange: { [weak self] in self?.statuses.append($0); self?.onStatus?() },
                onCancel: { [weak self] _ in self?.cancelled += 1 }, onError: { [weak self] in self?.errors.append($0) }),
            sheetFactory: { [weak self] submit, finished in
                self?.sheets += 1
                self?.submitWallet = submit
                self?.sheetFinished = finished
                return FakeWalletSurface()
            }, hostedFactory: { [weak self] verification, open, close in
                self?.hosted.append(verification)
                self?.openVerification = open
                self?.closeVerification = close
                return FakeWalletSurface()
            }, acceptsVerification: MercuryoApplePayAdapter.acceptsVerification, now: { [weak self] in self?.now ?? WalletFixtures.now })
    }
    func authorize() { submitWallet?(WalletFixtures.payment, { [weak self] in self?.outcomes.append($0.succeeded) }) }
}

private final class FakeWalletSurface: MeldProviderSession { func unmount() {} }
private final class FakeActionClient: PaymentActionSending {
    struct Request {
        let operation: String
        let fields: [String: Any]
        let key: UUID?
        let completion: (Result<[String: Any], Error>) -> Void
    }
    var requests: [Request] = []
    var operations: [String] { requests.map(\.operation) }
    var finished = 0
    func send(_ operation: String, fields: [String: Any], key: UUID?, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        requests.append(Request(operation: operation, fields: fields, key: key, completion: completion))
    }
    func finish() { finished += 1 }
    func respond(_ index: Int, _ json: [String: Any]) { complete(index, .success(json)) }
    func complete(_ index: Int, _ result: Result<[String: Any], Error>) { requests[index].completion(result) }
}

private final class MemoryWalletStore: WalletAttemptStoring {
    var value = WalletAttemptRecord()
    var fail = false
    func record() throws -> WalletAttemptRecord {
        guard !fail else { throw PaymentActionError.storage }
        return value
    }
    func claimSubmission() throws -> UUID {
        guard !(try record()).submissionStarted else { throw PaymentActionError.alreadyAttempted }
        value.submissionStarted = true
        return value.submissionKey
    }
    func claimVerification() throws {
        guard !(try record()).verificationOpened else { throw PaymentActionError.alreadyAttempted }
        value.submissionStarted = true
        value.verificationOpened = true
    }
    func observeSubmission() throws { _ = try record(); value.submissionStarted = true }
}
