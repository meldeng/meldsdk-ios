import CryptoKit
import Security
import XCTest
@testable import MeldSDK

final class WalletActionContractTests: XCTestCase {
    func testStrictResponseVersionStateAndContinuationPairs() throws {
        for state in ["NOT_STARTED", "SUBMITTED", "IN_PROGRESS", "UNKNOWN", "FAILED", "EXPIRED", "VERIFICATION_REQUIRED"] {
            let json = WalletFixtures.response(state)
            XCTAssertEqual(try WalletActionResponse(json).state.rawValue, state)
            var wrongNext = json
            wrongNext["nextStep"] = "CREATE_ANOTHER_PAYMENT"
            XCTAssertThrowsError(try WalletActionResponse(wrongNext))
            var wrongVersion = json
            wrongVersion["version"] = true
            XCTAssertThrowsError(try WalletActionResponse(wrongVersion))
        }
        XCTAssertThrowsError(try WalletActionResponse(WalletFixtures.response("NEW_PROVIDER_STATE")))
        var stray = WalletFixtures.response("SUBMITTED")
        stray["verification"] = ["url": "https://example.com"]
        XCTAssertThrowsError(try WalletActionResponse(stray))
    }

    func testVerificationRequiresHttpsDispositionAndExpiryWithoutCredentials() throws {
        let response = WalletFixtures.response("VERIFICATION_REQUIRED")
        let original = response["verification"] as! [String: Any]
        for field in ["url", "paymentDisposition", "expiresAt"] {
            var missing = original
            missing.removeValue(forKey: field)
            XCTAssertThrowsError(try WalletVerification(missing))
        }
        for url in ["http://sandbox-exchange.mrcr.io/x", "https://user:pass@sandbox-exchange.mrcr.io/x",
                    "https://sandbox-exchange.mrcr.io:8080/x", "javascript:alert(1)"] {
            var invalid = original
            invalid["url"] = url
            XCTAssertThrowsError(try WalletVerification(invalid))
        }
        var invalid = original
        invalid["paymentDisposition"] = "START_ANOTHER_NATIVE_PAYMENT"
        XCTAssertThrowsError(try WalletVerification(invalid))
        let verified = try WalletVerification(original)
        XCTAssertEqual(String(describing: verified), "WalletVerification[REDACTED]")
        XCTAssertTrue(MercuryoApplePayAdapter.acceptsVerification(verified.url))
        XCTAssertFalse(MercuryoApplePayAdapter.acceptsVerification(URL(string: "https://sandbox-exchange.mrcr.io.attacker.example/x")!))
    }

    func testWalletDataLimitsAreCheckedBeforeNetworkDispatch() throws {
        let valid = WalletFixtures.payment
        for (token, first, email) in [("not-base64", valid.firstName, valid.email),
                                      (String(repeating: "A", count: 49156), valid.firstName, valid.email),
                                      (valid.token, String(repeating: "x", count: 256), valid.email),
                                      (valid.token, "line\nbreak", valid.email),
                                      (valid.token, " ", valid.email), (valid.token, valid.firstName, nil),
                                      (valid.token, valid.firstName, "invalid-email")] {
            let payment = WalletPayment(token: token, firstName: first, lastName: valid.lastName, email: email, billing: valid.billing)
            XCTAssertThrowsError(try payment.actionFields())
        }
        for country in ["lt", "LTT", "L\n"] {
            let billing = ApplePayProcessBody.BillingAddress(countryCode: country, streetLine1: "1 Test", streetLine2: nil,
                                                             stateCode: nil, city: nil, zipCode: nil)
            XCTAssertThrowsError(try WalletPayment(token: valid.token, firstName: valid.firstName, lastName: valid.lastName,
                                                    email: valid.email, billing: billing).actionFields())
        }
    }

    func testLegacyUnknownResponsesNeverClaimSubmissionOrExposePayloads() {
        let responses: [[String: Any]?] = [nil, [:], ["data": [:]], ["data": ["status": "synthetic-private-value"]],
            ["status": 400, "message": "synthetic-private-value", "data": ["token": "synthetic-private-value"]]]
        for json in responses {
            let outcome = ApplePayResponseInterpreter.interpret(httpStatus: 200, json: json, orderId: "test-order")
            XCTAssertFalse(outcome.succeeded)
            XCTAssertEqual(outcome.events.count, 1)
            guard case .error(let error) = outcome.events[0] else { XCTFail("Expected error"); continue }
            XCTAssertFalse(error.recoverable)
            XCTAssertNil(error.detail)
            XCTAssertFalse(error.code.contains("synthetic-private-value"))
            XCTAssertFalse(error.message.contains("synthetic-private-value"))
        }
    }

    func testKeychainAttemptSurvivesANewStoreAndContainsOnlyNonsecretFences() throws {
        let identity = "wallet-unit-test-" + UUID().uuidString
        defer { deleteTestRecord(identity) }
        let first = WalletAttemptStore(identity: identity)
        XCTAssertFalse(try first.record().submissionStarted)
        let key = try first.claimSubmission()
        let replay = WalletAttemptStore(identity: identity)
        XCTAssertEqual(try replay.record().submissionKey, key)
        XCTAssertTrue(try replay.record().submissionStarted)
        XCTAssertThrowsError(try replay.claimSubmission())
        try replay.claimVerification()
        let reopened = WalletAttemptStore(identity: identity)
        XCTAssertTrue(try reopened.record().verificationOpened)
        XCTAssertThrowsError(try reopened.claimVerification())
        var query = testQuery(identity)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let data = try XCTUnwrap(result as? Data)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["submissionKey", "submissionStarted", "verificationOpened"])
    }

    func testConcurrentStoreInstancesCanClaimOnlyOneSubmission() throws {
        let identity = "wallet-unit-test-" + UUID().uuidString
        defer { deleteTestRecord(identity) }
        let lock = NSLock()
        var keys: [UUID] = []
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            if let key = try? WalletAttemptStore(identity: identity).claimSubmission() {
                lock.lock(); keys.append(key); lock.unlock()
            }
        }
        XCTAssertEqual(keys.count, 1)
        XCTAssertTrue(try WalletAttemptStore(identity: identity).record().submissionStarted)
    }

    private func testQuery(_ identity: String) -> [String: Any] {
        let account = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "io.meld.sdk.wallet-attempts.v1",
                kSecAttrAccount as String: account]
    }
    private func deleteTestRecord(_ identity: String) { SecItemDelete(testQuery(identity) as CFDictionary) }
}
