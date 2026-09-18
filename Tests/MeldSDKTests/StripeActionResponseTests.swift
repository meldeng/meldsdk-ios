import XCTest
@testable import MeldSDK

final class StripeActionResponseTests: XCTestCase {
    func testReadProjectionNeverConfusesProgressOrUnknownWithAReusableAttempt() throws {
        let rows: [(String, String, StripeActionResponse.Submission)] = [
            ("IN_PROGRESS", "WAIT_FOR_PROVIDER", .inProgress),
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
        let resume = try decode("READY", "REFRESH_QUOTE", sdk: ["sessionHandle": "cos_synthetic", "authenticationState": "RESTORE"])
        XCTAssertEqual(try resume.submission(), .resumeSession("cos_synthetic", .restore))
        XCTAssertThrowsError(try decode("NOT_STARTED", "NONE", sdk: ["sessionHandle": "cos_synthetic"]).submission())
    }

    func testAuthenticationRecoveryStateIsRequiredBeforeResumingAnOrder() throws {
        for state in [StripeActionResponse.Authentication.bootstrap, .restore, .reauthorize] {
            XCTAssertEqual(try decode("NOT_STARTED", "NONE", sdk: ["authenticationState": state.rawValue]).submission(), .notStarted(state))
        }
        XCTAssertEqual(try decode("READY", "REFRESH_QUOTE", sdk: ["sessionHandle": "cos_existing", "authenticationState": "REAUTHORIZE"]).submission(),
                       .resumeSession("cos_existing", .reauthorize))
        XCTAssertThrowsError(try decode("NOT_STARTED", "NONE").submission())
        XCTAssertThrowsError(try decode("READY", "REFRESH_QUOTE", sdk: ["sessionHandle": "cos_existing"]).submission())
        XCTAssertThrowsError(try decode("READY", "REFRESH_QUOTE", sdk: ["sessionHandle": "cos_existing", "authenticationState": "BOOTSTRAP"]).submission())
        XCTAssertThrowsError(try decode("SUCCEEDED", "COMPLETE", sdk: ["authenticationState": "RESTORE"]).submission())
    }

    func testInteractiveAuthorizationRequiresAnUnexpiredIntentAndCannotBeConfusedWithASecret() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = ISO8601DateFormatter().string(from: now.addingTimeInterval(60))
        let sdk = ["authorizationHandle": "lai_synthetic", "expiresAt": expiry, "authenticationState": "REAUTHORIZE"]
        let response = try decode("READY", "SDK_AUTHORIZE", sdk: sdk)
        XCTAssertEqual(try response.authorizationIntent(now: now), "lai_synthetic")
        XCTAssertThrowsError(try response.authorizationIntent(now: now.addingTimeInterval(60)))
        XCTAssertThrowsError(try response.authenticationSecret(now: now))
        XCTAssertThrowsError(try response.submission())
        XCTAssertThrowsError(try decode("READY", "SDK_AUTHORIZE", sdk: sdk.merging(["clientSecret": "synthetic-secret"]) { _, new in new }).authorizationIntent(now: now))
        XCTAssertThrowsError(try decode("READY", "SDK_AUTHORIZE", sdk: ["authorizationHandle": "lai_synthetic", "expiresAt": expiry]).authorizationIntent(now: now))
        XCTAssertFalse(response.description.contains("lai_synthetic"))
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
            ["expiresAt": 123], ["expiresAt": "invalid"], ["authorizationHandle": "lai_bad\n"],
            ["authenticationState": "UNKNOWN"], ["authorizationHandle": "cos_wrong"],
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
