import XCTest
@testable import MeldSDK

final class StripeActionResponseTests: XCTestCase {
    func testLinkCompletionUsesCustomerVerificationStatesAndStatusReadsRequireDetails() throws {
        for (status, next) in [("VERIFIED", "CREATE_PAYMENT_SESSION"), ("PENDING", "RETRY"),
                               ("NOT_STARTED", "SDK_COLLECT_KYC"), ("REJECTED", "SDK_VERIFY_IDENTITY")] {
            var json: [String: Any] = ["version": 1, "status": status, "nextStep": next]
            XCTAssertNoThrow(try StripeActionResponse(json).validateCustomerAction(requiresDetails: false))
            XCTAssertThrowsError(try StripeActionResponse(json).validateCustomerAction(requiresDetails: true))
            json["customer"] = ["missingFields": []]
            XCTAssertNoThrow(try StripeActionResponse(json).validateCustomerAction(requiresDetails: true))
            json["sdk"] = ["clientSecret": "synthetic-unexpected"]
            XCTAssertThrowsError(try StripeActionResponse(json).validateCustomerAction(requiresDetails: true))
        }
        XCTAssertThrowsError(try StripeActionResponse(["version": 1, "status": "AUTHORIZED", "nextStep": "CREATE_PAYMENT_SESSION"])
            .validateCustomerAction(requiresDetails: false))
        XCTAssertThrowsError(try StripeActionResponse(["version": 1, "status": "VERIFIED", "nextStep": "SDK_COLLECT_KYC"])
            .validateCustomerAction(requiresDetails: false))
    }

    func testSubmissionReadCarriesAWellFormedPrefill() throws {
        let read = try decode("NOT_STARTED", "NONE", sdk: ["authenticationState": "BOOTSTRAP", "prefill": [
            "email": "buyer@example.test", "phone": "+14155550123", "fullName": "Ada Lovelace",
            "identity": ["firstName": "Ada", "lastName": "Lovelace", "dateOfBirth": "1990-03-15",
                         "address": ["line1": "1 Market St", "city": "San Francisco", "state": "ca", "postalCode": "94105", "country": "US"]]]])
        XCTAssertEqual(try read.submission(), .notStarted(.bootstrap))
        let prefill = try XCTUnwrap(read.prefill)
        XCTAssertEqual(prefill.email, "buyer@example.test")
        XCTAssertEqual(prefill.phone, "+14155550123")
        XCTAssertEqual(prefill.fullName, "Ada Lovelace")
        XCTAssertEqual(prefill.identity?.firstName, "Ada")
        XCTAssertEqual(prefill.identity?.birthYear, 1990)
        XCTAssertEqual(prefill.identity?.address?.state, "CA")
        XCTAssertNil(prefill.identity?.idNumber)
        XCTAssertFalse(String(describing: prefill).contains("Ada"))
        let emailOnly = try XCTUnwrap(try decode("NOT_STARTED", "NONE", sdk: ["authenticationState": "BOOTSTRAP", "prefill": ["email": "buyer@example.test"]]).prefill)
        XCTAssertNil(emailOnly.phone); XCTAssertNil(emailOnly.identity)
        XCTAssertNil(try decode("NOT_STARTED", "NONE", sdk: ["authenticationState": "BOOTSTRAP"]).prefill)
    }

    func testTypedPhoneNumbersBecomeE164AndOtherFieldsAreOnlyTrimmed() {
        XCTAssertEqual(StripeFormField.phone.normalized("(415) 555-0123"), "+14155550123")
        XCTAssertEqual(StripeFormField.phone.normalized("1 415 555 0123"), "+14155550123")
        XCTAssertEqual(StripeFormField.phone.normalized("+44 20 7946 0958"), "+442079460958")
        XCTAssertEqual(StripeFormField.phone.normalized("555-0123"), "555-0123")
        XCTAssertFalse(StripeFormField.phone.valid(StripeFormField.phone.normalized("555-0123")))
        XCTAssertEqual(StripeFormField.state.normalized(" ca "), "CA")
        XCTAssertEqual(StripeFormField.email.normalized(" buyer@example.test "), "buyer@example.test")
    }

    func testUnusablePrefillValuesAreDroppedWithoutInvalidatingTheResponse() throws {
        func prefill(_ value: Any) throws -> StripePrefill? {
            try decode("NOT_STARTED", "NONE", sdk: ["authenticationState": "BOOTSTRAP", "prefill": value]).prefill
        }
        let address: [String: Any] = ["line1": "1 Market St", "city": "San Francisco", "state": "CA", "postalCode": "94105", "country": "US"]
        for unusable: Any in ["buyer@example.test", ["phone": "+14155550123"], ["email": "not-an-email"]] {
            XCTAssertNil(try prefill(unusable), "without a usable email the forms ask for everything")
        }
        let base: [String: Any] = ["email": "buyer@example.test"]
        XCTAssertNil(try prefill(base.merging(["phone": "4155550123"]) { $1 })?.phone)
        XCTAssertNil(try prefill(base.merging(["fullName": String(repeating: "A", count: 300)]) { $1 })?.fullName)
        XCTAssertNil(try prefill(base.merging(["identity": "Ada"]) { $1 })?.identity)
        let badDate = try XCTUnwrap(try prefill(base.merging(["identity": ["firstName": "Ada", "dateOfBirth": "15/03/1990"]]) { $1 })?.identity)
        XCTAssertEqual(badDate.firstName, "Ada"); XCTAssertNil(badDate.birthYear)
        for broken in [address.merging(["country": "GB"]) { $1 }, address.merging(["postalCode": "9410"]) { $1 },
                       address.merging(["city": "San\nFrancisco"]) { $1 }, address.merging(["line2": 7]) { $1 }] {
            let identity = try XCTUnwrap(try prefill(base.merging(["identity": ["lastName": "Lovelace", "address": broken]]) { $1 })?.identity)
            XCTAssertNil(identity.address); XCTAssertEqual(identity.lastName, "Lovelace")
        }
    }

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
