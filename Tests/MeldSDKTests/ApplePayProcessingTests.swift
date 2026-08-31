import XCTest
@testable import MeldSDK

/// Unit tests for the deterministic Apple Pay processing logic — the `/process` request body,
/// the response-to-events mapping, and the per-environment base URL. The PassKit presentation
/// itself (sheet, delegate callbacks) needs a device and isn't unit tested here.
final class ApplePayProcessingTests: XCTestCase {

    // MARK: - Request body

    func testBodyUsesSnakeCaseAndOmitsBuyToken() {
        let body = ApplePayProcessBody.make(
            payTokenBase64: "dG9rZW4=",
            merchantTransactionId: "session-123",
            walletAddress: "0xWallet",
            clientIpAddress: "203.0.113.7",
            firstName: "Ada",
            lastName: "Lovelace",
            email: "ada@example.com",
            billing: ApplePayProcessBody.BillingAddress(
                countryCode: "US", streetLine1: "1 Infinite Loop", streetLine2: nil,
                stateCode: "CA", city: "Cupertino", zipCode: "95014"))

        XCTAssertEqual(body["pay_token"] as? String, "dG9rZW4=")
        XCTAssertEqual(body["merchant_transaction_id"] as? String, "session-123")
        XCTAssertEqual(body["address"] as? String, "0xWallet")
        XCTAssertEqual(body["ip"] as? String, "203.0.113.7")
        XCTAssertEqual(body["first_name"] as? String, "Ada")
        XCTAssertEqual(body["last_name"] as? String, "Lovelace")
        XCTAssertEqual(body["email"] as? String, "ada@example.com")
        // buy_token is filled server-side from the session — the client must never send it.
        XCTAssertNil(body["buy_token"])

        let billing = body["billing_address"] as? [String: Any]
        XCTAssertEqual(billing?["country_code"] as? String, "US")
        XCTAssertEqual(billing?["street_line_1"] as? String, "1 Infinite Loop")
        XCTAssertEqual(billing?["state_code"] as? String, "CA")
        XCTAssertEqual(billing?["city"] as? String, "Cupertino")
        XCTAssertEqual(billing?["zip_code"] as? String, "95014")
        XCTAssertNil(billing?["street_line_2"])
    }

    func testBodyOmitsEmptyEmailAndEmptyBilling() {
        let body = ApplePayProcessBody.make(
            payTokenBase64: "t",
            merchantTransactionId: "s",
            walletAddress: "w",
            clientIpAddress: "1.2.3.4",
            firstName: "A",
            lastName: "B",
            email: "",
            billing: ApplePayProcessBody.BillingAddress(
                countryCode: nil, streetLine1: nil, streetLine2: nil,
                stateCode: nil, city: nil, zipCode: nil))

        XCTAssertNil(body["email"])
        XCTAssertNil(body["billing_address"])
    }

    // MARK: - Response interpretation

    func testAcceptedResponseEmitsSubmittedAndPendingStatus() {
        let json: [String: Any] = ["data": ["id": "tx1", "status": "new"]]
        let outcome = ApplePayResponseInterpreter.interpret(httpStatus: 200, json: json, orderId: "ord1")

        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(outcome.events.count, 2)
        guard case .paymentSubmitted = outcome.events[0] else { return XCTFail("expected paymentSubmitted") }
        guard case let .statusChange(change) = outcome.events[1] else { return XCTFail("expected statusChange") }
        XCTAssertEqual(change.status, .pending)
        XCTAssertEqual(change.providerStatus, "new")
        XCTAssertEqual(change.orderId, "ord1")
    }

    func testCompletedProviderStatusNormalizes() {
        let json: [String: Any] = ["data": ["payment_status": "paid"]]
        let outcome = ApplePayResponseInterpreter.interpret(httpStatus: 200, json: json, orderId: nil)
        XCTAssertTrue(outcome.succeeded)
        guard case let .statusChange(change) = outcome.events[1] else { return XCTFail("expected statusChange") }
        XCTAssertEqual(change.status, .completed)
    }

    func testTerminalFailedStatusEmitsErrorAndFails() {
        let json: [String: Any] = ["data": ["status": "rejected"]]
        let outcome = ApplePayResponseInterpreter.interpret(httpStatus: 200, json: json, orderId: "ord1")

        XCTAssertFalse(outcome.succeeded)
        guard case .statusChange = outcome.events[1] else { return XCTFail("expected statusChange") }
        guard case let .error(error) = outcome.events.last else { return XCTFail("expected trailing error") }
        XCTAssertFalse(error.recoverable)
    }

    func testCancelledStatusEmitsCancelAndFails() {
        let json: [String: Any] = ["data": ["status": "cancelled"]]
        let outcome = ApplePayResponseInterpreter.interpret(httpStatus: 200, json: json, orderId: nil)
        XCTAssertFalse(outcome.succeeded)
        guard case .cancel = outcome.events.last else { return XCTFail("expected trailing cancel") }
    }

    func testProviderErrorCodeIsTreatedAsFailure() {
        let json: [String: Any] = ["code": "PAYMENT_DECLINED", "message": "Card declined"]
        let outcome = ApplePayResponseInterpreter.interpret(httpStatus: 200, json: json, orderId: "ord1")

        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.events.count, 1)
        guard case let .error(error) = outcome.events[0] else { return XCTFail("expected error") }
        XCTAssertEqual(error.code, "PAYMENT_DECLINED")
        XCTAssertEqual(error.message, "Card declined")
    }

    func testNon2xxTransportStatusIsFailure() {
        let outcome = ApplePayResponseInterpreter.interpret(
            httpStatus: 400, json: ["message": "bad request"], orderId: nil)
        XCTAssertFalse(outcome.succeeded)
        guard case let .error(error) = outcome.events[0] else { return XCTFail("expected error") }
        XCTAssertEqual(error.message, "bad request")
    }

    func testProviderStatusIntAbove400IsFailure() {
        let json: [String: Any] = ["status": 402, "message": "payment required"]
        let outcome = ApplePayResponseInterpreter.interpret(httpStatus: 200, json: json, orderId: nil)
        XCTAssertFalse(outcome.succeeded)
        guard case .error = outcome.events[0] else { return XCTFail("expected error") }
    }

    // MARK: - Base URL

    func testBaseURLPerEnvironment() {
        XCTAssertEqual(MercuryoApplePayClient.baseURL(for: .sandbox), "https://api-sb.meld.io")
        XCTAssertEqual(MercuryoApplePayClient.baseURL(for: .production), "https://api.meld.io")
    }
}
