import XCTest
@testable import MeldSDK

final class StripeActionResponseTests: XCTestCase {
    func testReadProjectionNeverConfusesProgressOrUnknownWithAReusableAttempt() throws {
        let rows: [(String, String, StripeActionResponse.Submission)] = [
            ("NOT_STARTED", "NONE", .notStarted), ("IN_PROGRESS", "WAIT_FOR_PROVIDER", .inProgress),
            ("SUBMITTED", "WAIT_FOR_PAYMENT", .submitted), ("SUCCEEDED", "COMPLETE", .completed),
            ("FAILED", "NONE", .failed), ("REJECTED", "NONE", .failed), ("EXPIRED", "NONE", .expired),
            ("UNKNOWN", "WAIT_FOR_PROVIDER", .unknown),
        ]
        for (status, next, expected) in rows {
            let response = try decode(status, next)
            XCTAssertEqual(try response.submission(), expected)
            XCTAssertThrowsError(try response.checkoutSecret(session: "cos_synthetic"))
            XCTAssertThrowsError(try decode(status, next, sdk: ["sessionHandle": "cos_synthetic"]).submission())
        }
        XCTAssertThrowsError(try decode("NOT_STARTED", "CONFIRM_PAYMENT").submission())
        XCTAssertThrowsError(try decode("READY", "REFRESH_QUOTE").submission())
        XCTAssertThrowsError(try decode("FULFILLMENT_COMPLETE", "NONE").submission())
        let resume = try decode("READY", "REFRESH_QUOTE", sdk: ["sessionHandle": "cos_synthetic"])
        XCTAssertEqual(try resume.submission(), .resumeSession("cos_synthetic"))
        XCTAssertThrowsError(try decode("NOT_STARTED", "NONE", sdk: ["sessionHandle": "cos_synthetic"]).submission())
    }

    func testCheckoutSecretMustBelongToTheSameSessionAndAction() throws {
        let sdk = ["sessionHandle": "cos_synthetic", "clientSecret": "synthetic-secret"]
        let response = try decode("REQUIRES_PAYMENT", "CONFIRM_PAYMENT", sdk: sdk)
        XCTAssertEqual(try response.checkoutSecret(session: "cos_synthetic"), "synthetic-secret")
        XCTAssertThrowsError(try response.checkoutSecret(session: "cos_other"))
        XCTAssertThrowsError(try response.submission())
        XCTAssertThrowsError(try decode("REJECTED", "SDK_COLLECT_KYC", sdk: sdk).checkoutSecret(session: "cos_synthetic"))
        XCTAssertThrowsError(try decode("REQUIRES_PAYMENT", "CONFIRM_PAYMENT").checkoutSecret(session: "cos_synthetic"))
        XCTAssertFalse(response.description.contains("synthetic-secret"))
    }

    func testSeamlessAuthenticationRequiresUnexpiredSecretAndNoSession() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = ISO8601DateFormatter().string(from: now.addingTimeInterval(60))
        let sdk = ["clientSecret": "synthetic-auth-secret", "expiresAt": expiry]
        let response = try decode("READY", "SDK_AUTHORIZE", sdk: sdk)
        XCTAssertEqual(try response.authenticationSecret(now: now), "synthetic-auth-secret")
        XCTAssertThrowsError(try response.authenticationSecret(now: now.addingTimeInterval(60)))
        XCTAssertThrowsError(try decode("READY", "SDK_AUTHORIZE", sdk: ["clientSecret": "synthetic"]).authenticationSecret(now: now))
        XCTAssertThrowsError(try decode("READY", "NONE", sdk: sdk).authenticationSecret(now: now))
    }

    func testUnknownOrMalformedValuesNeverChooseAnImplicitNextStep() throws {
        for value: [String: Any] in [
            ["version": true, "status": "READY", "nextStep": "NONE"],
            ["version": 2, "status": "READY", "nextStep": "NONE"],
            ["version": 1, "status": "FUTURE", "nextStep": "NONE"],
            ["version": 1, "status": "READY", "nextStep": "FUTURE"],
        ] { XCTAssertThrowsError(try StripeActionResponse(value)) }
        for sdk: [String: Any] in [
            ["sessionHandle": "foreign"], ["sessionHandle": "cos_bad\n"], ["clientSecret": "private\nsecret"],
            ["expiresAt": 123], ["expiresAt": "invalid"],
        ] { XCTAssertThrowsError(try decode("READY", "NONE", sdk: sdk)) }
        XCTAssertThrowsError(try StripeActionResponse(["version": 1, "status": "READY", "nextStep": "SDK_COLLECT_KYC",
                                                      "customer": ["missingFields": ["UNKNOWN_IDENTITY_FIELD"]]]))
    }

    private func decode(_ status: String, _ next: String, sdk: [String: Any]? = nil) throws -> StripeActionResponse {
        var value: [String: Any] = ["version": 1, "status": status, "nextStep": next]
        if let sdk { value["sdk"] = sdk }
        return try StripeActionResponse(value)
    }
}
