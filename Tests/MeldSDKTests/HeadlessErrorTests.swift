import XCTest
@testable import MeldSDK

final class HeadlessErrorTests: XCTestCase {
    func testLegacyCallbackErrorsPreserveUncertaintyRegardlessOfRecoverability() {
        for recoverable in [false, true] {
            let error = MeldError(orderId: "synthetic", code: "unknown", message: "synthetic", recoverable: recoverable)
            XCTAssertEqual(error.headlessError?.category, .outcomeUnknown)
            XCTAssertEqual(error.headlessError?.recovery, .readState)
            XCTAssertEqual(error.headlessError?.automaticRetryAllowed, false)
            XCTAssertEqual(error.recoverable, recoverable)
        }
    }

    func testExplicitActionAdviceSurvivesCallbackConstruction() throws {
        for (category, recovery) in HeadlessErrorFixtures.pairs {
            let advice = try XCTUnwrap(MeldHeadlessError.decode(
                HeadlessErrorFixtures.json(category, recovery), operation: "READ_SUBMISSION"))
            let error = MeldError(orderId: "synthetic", code: "action", message: "synthetic",
                                  recoverable: false, headlessError: advice)
            XCTAssertEqual(error.headlessError, advice)
        }
    }

    func testEveryPublicPairIsAcceptedAndUnknownFieldsAreNotRetained() throws {
        for (category, recovery) in HeadlessErrorFixtures.pairs {
            let json = HeadlessErrorFixtures.json(category, recovery).merging(["secret": "synthetic-private"]) { $1 }
            let parsed = try XCTUnwrap(MeldHeadlessError.decode(json, operation: "READ_SUBMISSION"))
            XCTAssertEqual(parsed.category.rawValue, category)
            XCTAssertEqual(parsed.recovery.rawValue, recovery)
            XCTAssertEqual(parsed.version, 1)
            XCTAssertFalse(parsed.automaticRetryAllowed)
            XCTAssertFalse(String(describing: parsed).contains("synthetic-private"))
        }
    }

    func testUnknownVersionsPairsAndCoercedBooleansFailClosed() {
        let valid = HeadlessErrorFixtures.json("DEPENDENCY_UNAVAILABLE", "RETRY_READ")
        for (field, values): (String, [Any]) in [
            ("version", [true, "1", 1.5, 2, NSNull()]),
            ("automaticRetryAllowed", [true, 0, "false", NSNull()]),
            ("category", ["FUTURE", "OUTCOME_UNKNOWN", NSNull()]),
            ("recovery", ["FUTURE", "STOP", NSNull()])
        ] {
            for value in values {
                XCTAssertNil(MeldHeadlessError.decode(valid.merging([field: value]) { $1 }, operation: "READ_SUBMISSION"))
            }
        }
        for field in valid.keys {
            var missing = valid; missing.removeValue(forKey: field)
            XCTAssertNil(MeldHeadlessError.decode(missing, operation: "READ_SUBMISSION"))
        }
    }

    func testReadAdviceRequiresAnExplicitReadOperation() {
        let json = HeadlessErrorFixtures.json("DEPENDENCY_UNAVAILABLE", "RETRY_READ")
        for operation in ["READ_SUBMISSION", "READ_CUSTOMER_STATUS", "READ_LIMITS", "READ_LEGAL_DISCLOSURE"] {
            XCTAssertEqual(MeldHeadlessError.decode(json, operation: operation)?.recovery, .retryRead)
        }
        for operation in ["SUBMIT_WALLET_PAYMENT", "CONFIRM_PAYMENT", "RECORD_LEGAL_EVIDENCE", "READ_FUTURE", "VALIDATE_MERCHANT"] {
            XCTAssertNil(MeldHeadlessError.decode(json, operation: operation))
            XCTAssertEqual(MeldHeadlessError.fallback(operation).recovery, .readState)
        }
    }

    func testMissingMalformedOversizedAndLegacyBodiesAreConservative() throws {
        let bodies: [Data?] = [nil, Data("not-json".utf8), Data(repeating: 32, count: 65537),
            try JSONSerialization.data(withJSONObject: ["version": 1, "code": "AUTHORIZATION_REQUIRED"]),
            try JSONSerialization.data(withJSONObject: ["headlessError": HeadlessErrorFixtures.json("ACCESS_DENIED", "RETRY_READ")])]
        for body in bodies {
            for operation in ["READ_SUBMISSION", "SUBMIT_WALLET_PAYMENT"] {
                XCTAssertEqual(MeldHeadlessError.from(PaymentActionFailure.decode(body, operation: operation)), .fallback(operation))
            }
        }
    }
}

enum HeadlessErrorFixtures {
    static let pairs = [
        ("INVALID_REQUEST", "CORRECT_REQUEST"), ("AUTHENTICATION_REQUIRED", "AUTHENTICATE"),
        ("ACCESS_DENIED", "STOP"), ("NOT_FOUND", "STOP"), ("UNSUPPORTED_PROTOCOL", "READ_REQUIREMENTS"),
        ("REQUIREMENT_REQUIRED", "READ_REQUIREMENTS"), ("REQUIREMENT_PENDING", "READ_STATE"),
        ("REQUIREMENT_BLOCKED", "STOP"), ("ORDER_REJECTED", "STOP"), ("REQUEST_CONFLICT", "READ_STATE"),
        ("OPERATION_IN_FLIGHT", "READ_STATE"), ("STATE_CHANGED", "READ_STATE"),
        ("DEPENDENCY_UNAVAILABLE", "READ_STATE"), ("DEPENDENCY_UNAVAILABLE", "RETRY_READ"), ("OUTCOME_UNKNOWN", "READ_STATE")
    ]
    static func json(_ category: String, _ recovery: String) -> [String: Any] {
        ["version": 1, "category": category, "recovery": recovery, "automaticRetryAllowed": false]
    }
}
