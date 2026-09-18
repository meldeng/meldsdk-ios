import PassKit
import UIKit
import XCTest
@testable import MeldSDK

@MainActor
final class StripeSdkRuntimeTests: XCTestCase {
    func testOneCoordinatorOwnsTheSdkUntilLogoutFinishes() async throws {
        let ownership = StripeSdkOwnership(), driver = FakeStripeSdk()
        let runtime = try await StripeSdkRuntime.open(ownership: ownership) { driver }
        var called = false
        await assertError(.busy) { _ = try await StripeSdkRuntime.open(ownership: ownership) { called = true; return FakeStripeSdk() } }
        XCTAssertFalse(called)
        await runtime.close()
        await runtime.close()
        XCTAssertEqual(driver.logoutCount, 1)
        let next = try await StripeSdkRuntime.open(ownership: ownership) { FakeStripeSdk() }
        await next.close()
    }

    func testUnmountWaitsForAnOutstandingOperationAndSuppressesItsResult() async throws {
        let ownership = StripeSdkOwnership(), driver = FakeStripeSdk()
        let runtime = try await StripeSdkRuntime.open(ownership: ownership) { driver }
        let entered = expectation(description: "lookup started")
        var resume: CheckedContinuation<Bool, Error>?
        driver.lookup = { try await withCheckedThrowingContinuation { resume = $0; entered.fulfill() } }
        let pending = Task { try await runtime.perform { try await $0.hasAccount(email: "synthetic@example.com") } }
        await fulfillment(of: [entered], timeout: 2)
        await assertError(.busy) { _ = try await runtime.perform { _ in true } }
        await runtime.close()
        XCTAssertEqual(driver.logoutCount, 0)
        await assertError(.busy) { _ = try await StripeSdkRuntime.open(ownership: ownership) { FakeStripeSdk() } }
        resume?.resume(returning: true)
        await assertError(.cancelled) { _ = try await pending.value }
        XCTAssertEqual(driver.logoutCount, 1)
        let next = try await StripeSdkRuntime.open(ownership: ownership) { FakeStripeSdk() }
        await next.close()
    }

    func testCreationFailureIsSanitizedAndDoesNotLeaveAnActiveCoordinator() async throws {
        let ownership = StripeSdkOwnership()
        await assertError(.unavailable) {
            _ = try await StripeSdkRuntime.open(ownership: ownership) { throw NSError(domain: "private-sentinel", code: 1) }
        }
        let runtime = try await StripeSdkRuntime.open(ownership: ownership) { FakeStripeSdk() }
        await runtime.close()
    }

    func testOwnershipRemainsHeldWhileLogoutIsStillPending() async throws {
        let ownership = StripeSdkOwnership(), driver = FakeStripeSdk()
        let entered = expectation(description: "logout started")
        var resume: CheckedContinuation<Void, Error>?
        driver.logout = { try await withCheckedThrowingContinuation { resume = $0; entered.fulfill() } }
        let runtime = try await StripeSdkRuntime.open(ownership: ownership) { driver }
        let closing = Task { await runtime.close() }
        await fulfillment(of: [entered], timeout: 2)
        await assertError(.busy) { _ = try await StripeSdkRuntime.open(ownership: ownership) { FakeStripeSdk() } }
        resume?.resume(returning: ())
        await closing.value
        let next = try await StripeSdkRuntime.open(ownership: ownership) { FakeStripeSdk() }
        await next.close()
    }

    func testDroppingAnIdleRuntimeStillLogsOutItsCoordinator() async throws {
        let ownership = StripeSdkOwnership(), driver = FakeStripeSdk()
        let loggedOut = expectation(description: "deinit cleanup")
        driver.logout = { loggedOut.fulfill() }
        var runtime: StripeSdkRuntime? = try await StripeSdkRuntime.open(ownership: ownership) { driver }
        weak var reference = runtime
        XCTAssertNotNil(reference)
        runtime = nil
        await fulfillment(of: [loggedOut], timeout: 2)
        XCTAssertNil(reference)
        XCTAssertEqual(driver.logoutCount, 1)
        let next = try await StripeSdkRuntime.open(ownership: ownership) { FakeStripeSdk() }
        await next.close()
    }

    func testProviderErrorsNeverEscapeAsDiagnostics() async throws {
        let driver = FakeStripeSdk()
        driver.lookup = { throw NSError(domain: "private-sentinel", code: 1, userInfo: ["email": "private@example.com"]) }
        let runtime = try await StripeSdkRuntime.open(ownership: StripeSdkOwnership()) { driver }
        await assertError(.unavailable) { _ = try await runtime.perform { try await $0.hasAccount(email: "synthetic@example.com") } }
        await runtime.close()
    }

    func testCleanupFailurePreventsAnotherCustomerFromUsingTheSameSharedState() async throws {
        let ownership = StripeSdkOwnership(), driver = FakeStripeSdk()
        driver.logoutFailure = true
        let runtime = try await StripeSdkRuntime.open(ownership: ownership) { driver }
        await runtime.close()
        await assertError(.busy) { _ = try await StripeSdkRuntime.open(ownership: ownership) { FakeStripeSdk() } }
        await assertError(.cancelled) { _ = try await runtime.perform { _ in true } }
        XCTAssertEqual(driver.logoutCount, 1)
    }

    func testEachActualCheckoutCallbackCanOwnADistinctInvocation() async throws {
        let driver = FakeStripeSdk()
        driver.checkoutHandler = { session, secret in
            _ = try await secret(session)
            _ = try await secret(session)
        }
        let runtime = try await StripeSdkRuntime.open(ownership: StripeSdkOwnership()) { driver }
        var invocations: [StripeCheckoutInvocation] = []
        try await runtime.checkout(session: "cos_synthetic", from: UIViewController()) { session in
            XCTAssertEqual(session, "cos_synthetic")
            invocations.append(StripeCheckoutInvocation())
            return "synthetic-client-secret"
        }
        XCTAssertEqual(invocations.count, 2)
        XCTAssertNotEqual(invocations[0].callbackID, invocations[1].callbackID)
        XCTAssertNotEqual(invocations[0].idempotencyKey, invocations[1].idempotencyKey)
        await runtime.close()
    }

    func testCheckoutCannotAskTheBackendToConfirmADifferentSession() async throws {
        let driver = FakeStripeSdk()
        driver.checkoutHandler = { _, secret in _ = try await secret("cos_foreign") }
        let runtime = try await StripeSdkRuntime.open(ownership: StripeSdkOwnership()) { driver }
        var calls = 0
        await assertError(.invalidResponse) {
            try await runtime.checkout(session: "cos_synthetic", from: UIViewController()) { _ in
                calls += 1; return "synthetic-client-secret"
            }
        }
        XCTAssertEqual(calls, 0)
        await runtime.close()
    }

    func testLateCheckoutCallbackAfterUnmountCannotReachTheBackend() async throws {
        let driver = FakeStripeSdk(), ownership = StripeSdkOwnership()
        let runtime = try await StripeSdkRuntime.open(ownership: ownership) { driver }
        let entered = expectation(description: "checkout started")
        var resume: CheckedContinuation<Void, Error>?
        var callback: (@MainActor (String) async throws -> String)?
        driver.checkoutHandler = { _, secret in
            callback = secret
            try await withCheckedThrowingContinuation { resume = $0; entered.fulfill() }
        }
        var calls = 0
        let pending = Task {
            try await runtime.checkout(session: "cos_synthetic", from: UIViewController()) { _ in
                calls += 1; return "synthetic-client-secret"
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        await runtime.close()
        await assertError(.cancelled) { _ = try await callback?("cos_synthetic") }
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(driver.logoutCount, 0)
        resume?.resume(returning: ())
        await assertError(.cancelled) { try await pending.value }
        XCTAssertEqual(driver.logoutCount, 1)
    }

    func testASecretReturningAfterUnmountIsNotGivenToTheSdk() async throws {
        let driver = FakeStripeSdk()
        var delivered = false
        driver.checkoutHandler = { session, secret in _ = try await secret(session); delivered = true }
        let runtime = try await StripeSdkRuntime.open(ownership: StripeSdkOwnership()) { driver }
        let entered = expectation(description: "backend callback started")
        var resume: CheckedContinuation<String, Error>?
        let pending = Task {
            try await runtime.checkout(session: "cos_synthetic", from: UIViewController()) { _ in
                try await withCheckedThrowingContinuation { resume = $0; entered.fulfill() }
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        await runtime.close()
        resume?.resume(returning: "synthetic-client-secret")
        await assertError(.cancelled) { try await pending.value }
        XCTAssertFalse(delivered)
        XCTAssertEqual(driver.logoutCount, 1)
    }

    func testConcurrentSdkCallbacksCannotStartTwoBackendConfirmations() async throws {
        let driver = FakeStripeSdk()
        let first = expectation(description: "first callback")
        var resume: CheckedContinuation<String, Error>?
        var callback: (@MainActor (String) async throws -> String)?
        driver.checkoutHandler = { session, secret in callback = secret; _ = try await secret(session) }
        let runtime = try await StripeSdkRuntime.open(ownership: StripeSdkOwnership()) { driver }
        var calls = 0
        let pending = Task {
            try await runtime.checkout(session: "cos_synthetic", from: UIViewController()) { _ in
                calls += 1
                return try await withCheckedThrowingContinuation { resume = $0; first.fulfill() }
            }
        }
        await fulfillment(of: [first], timeout: 2)
        await assertError(.invalidResponse) { _ = try await callback?("cos_synthetic") }
        XCTAssertEqual(calls, 1)
        resume?.resume(returning: "synthetic-client-secret")
        try await pending.value
        await runtime.close()
    }

    func testCancellationDuringCreationCleansUpBeforeReleasingOwnership() async throws {
        let driver = FakeStripeSdk(), ownership = StripeSdkOwnership()
        let entered = expectation(description: "creation started")
        var resume: CheckedContinuation<StripeSdkDriving, Error>?
        let pending = Task {
            try await StripeSdkRuntime.open(ownership: ownership) {
                try await withCheckedThrowingContinuation { resume = $0; entered.fulfill() }
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        pending.cancel()
        resume?.resume(returning: driver)
        await assertError(.cancelled) { _ = try await pending.value }
        XCTAssertEqual(driver.logoutCount, 1)
        let next = try await StripeSdkRuntime.open(ownership: ownership) { FakeStripeSdk() }
        await next.close()
    }

    private func assertError(_ expected: StripeNativeError,
                             _ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected native failure", file: file, line: line) }
        catch let error as StripeNativeError {
            XCTAssertEqual(String(describing: error), String(describing: expected), file: file, line: line)
        } catch { XCTFail("Unexpected error type", file: file, line: line) }
    }
}

@MainActor
private final class FakeStripeSdk: StripeSdkDriving {
    var lookup: () async throws -> Bool = { true }
    var checkoutHandler: (String, @escaping @MainActor (String) async throws -> String) async throws -> Void = { _, _ in }
    var logoutCount = 0
    var logoutFailure = false
    var logout: () async throws -> Void = {}
    func hasAccount(email: String) async throws -> Bool { try await lookup() }
    func register(email: String, name: String?, phone: String, country: String) async throws {}
    func authorize(intent: String, from presenter: UIViewController) async throws -> String { "crc_synthetic" }
    func authenticate(secret: String) async throws {}
    func attachIdentity(_ input: StripeIdentityInput) async throws {}
    func verifyIdentity(from presenter: UIViewController) async throws {}
    func confirmIdentity(address: StripeAddressInput?, from presenter: UIViewController) async throws -> StripeKycConfirmation { .confirmed }
    func registerWallet(address: String, network: String) async throws {}
    func collectPayment(request: PKPaymentRequest?, from presenter: UIViewController) async throws {}
    func createPaymentToken() async throws -> String { "cpt_synthetic" }
    func checkout(session: String, from presenter: UIViewController,
                  secret: @escaping @MainActor (String) async throws -> String) async throws {
        try await checkoutHandler(session, secret)
    }
    func logOut() async throws {
        logoutCount += 1
        try await logout()
        if logoutFailure { throw NSError(domain: "private-sentinel", code: 1) }
    }
}
