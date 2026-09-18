import XCTest
@testable import MeldSDK

final class PaymentActionClientTests: XCTestCase {
    func testDescriptorBuildsOnlyTheDeclaredOrderScopedRequest() throws {
        let descriptor = try PaymentActionDescriptor(order: WalletFixtures.order(), environment: .sandbox)
        let key = UUID()
        let request = try descriptor.request(operation: "SUBMIT_WALLET_PAYMENT",
                                             fields: WalletFixtures.payment.actionFields(), key: key)
        XCTAssertEqual(request.url?.absoluteString, "https://api-sb.meld.io/crypto/order/headless/onramp/TEST_PROVIDER/test-order/actions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-session")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Idempotency-Key"), key.uuidString.lowercased())
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["version", "operation", "walletPayment"])
        let wallet = try XCTUnwrap(body["walletPayment"] as? [String: Any])
        XCTAssertEqual(Set(wallet.keys), ["token", "email", "firstName", "lastName", "billingAddress"])
        XCTAssertEqual(String(describing: descriptor), "PaymentActionDescriptor[REDACTED]")
        XCTAssertEqual(String(describing: WalletFixtures.payment), "WalletPayment[REDACTED]")
    }

    func testRejectsCrossOriginWrongOrderProviderAndNoncanonicalEndpoints() throws {
        for endpoint in ["https://other.example/crypto/order/headless/onramp/TEST_PROVIDER/test-order/actions",
                         "http://api-sb.meld.io/crypto/order/headless/onramp/TEST_PROVIDER/test-order/actions",
                         "https://api.meld.io/crypto/order/headless/onramp/TEST_PROVIDER/test-order/actions",
                         "https://user:pass@api-sb.meld.io/crypto/order/headless/onramp/TEST_PROVIDER/test-order/actions",
                         "https://api-sb.meld.io:8443/crypto/order/headless/onramp/TEST_PROVIDER/test-order/actions",
                         "/crypto/order/headless/onramp/TEST_PROVIDER/other-order/actions",
                         "/crypto/order/headless/onramp/OTHER_PROVIDER/test-order/actions",
                         "/crypto/order/headless/onramp/TEST_PROVIDER/test-order/actions?token=synthetic",
                         "/crypto/order/headless/onramp/TEST_PROVIDER/test-order/actions#fragment",
                         "/crypto/order/headless/onramp/TEST_PROVIDER/test%2Dorder/actions"] {
            XCTAssertThrowsError(try descriptor(action: ["endpoint": endpoint]), endpoint)
        }
    }

    func testStrictVersionsOperationsAndBearerPointer() throws {
        for version: Any in [true, "1", 0, 1.5, 2] {
            XCTAssertThrowsError(try descriptor(action: ["version": version]))
        }
        for pointer in ["paymentMethodResponseDetails/sessionToken", "/missing", "/paymentMethodResponseDetails",
                        "/invalid~2pointer", "/invalid~"] {
            XCTAssertThrowsError(try descriptor(action: ["bearerTokenPointer": pointer]))
        }
        for token in ["", "has space", "line\nbreak", String(repeating: "x", count: 16385)] {
            var json = WalletFixtures.json()
            json["paymentMethodResponseDetails"] = ["sessionToken": token]
            XCTAssertThrowsError(try PaymentActionDescriptor(order: WalletFixtures.order(json), environment: .sandbox))
        }
        for operations: Any in [[], [["operation": "READ_SUBMISSION", "idempotencyKeyRequired": 0]],
                                [["operation": "READ_SUBMISSION", "idempotencyKeyRequired": false],
                                 ["operation": "READ_SUBMISSION", "idempotencyKeyRequired": false]]] {
            XCTAssertThrowsError(try descriptor(action: ["operations": operations]))
        }
    }

    func testJSONPointerEscapesAndArrayIndicesResolveWithoutGuessing() throws {
        var json = WalletFixtures.json()
        json["a/b"] = ["~key": ["synthetic-escaped"]]
        var actions = WalletFixtures.actions()
        actions["bearerTokenPointer"] = "/a~1b/~0key/0"
        json["paymentActions"] = actions
        let descriptor = try PaymentActionDescriptor(order: WalletFixtures.order(json), environment: .sandbox)
        let request = try descriptor.request(operation: "READ_SUBMISSION", fields: [:], key: nil)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-escaped")
        actions["bearerTokenPointer"] = "/a~1b/~0key/00"
        json["paymentActions"] = actions
        XCTAssertThrowsError(try PaymentActionDescriptor(order: WalletFixtures.order(json), environment: .sandbox))
    }

    func testOperationAndIdempotencyRequirementsCannotBeOverridden() throws {
        let descriptor = try self.descriptor()
        XCTAssertThrowsError(try descriptor.request(operation: "UNKNOWN", fields: [:], key: nil))
        XCTAssertThrowsError(try descriptor.request(operation: "READ_SUBMISSION", fields: [:], key: UUID()))
        XCTAssertThrowsError(try descriptor.request(operation: "SUBMIT_WALLET_PAYMENT", fields: [:], key: nil))
        for field in ["version", "operation"] {
            XCTAssertThrowsError(try descriptor.request(operation: "READ_SUBMISSION", fields: [field: "override"], key: nil))
        }
        XCTAssertThrowsError(try descriptor.request(operation: "SUBMIT_WALLET_PAYMENT",
                                                    fields: ["value": String(repeating: "x", count: 65536)], key: UUID()))
    }

    func testDefaultHttpsPortUsesTheSameDurableIdentity() throws {
        let implicit = try descriptor()
        let explicit = try descriptor(action: ["endpoint": "https://api-sb.meld.io:443" + WalletFixtures.endpoint])
        XCTAssertEqual(implicit.identity, explicit.identity)
    }

    func testMalformedOrMissingActionsNeverFallBackToLegacyForDeclaredWallet() throws {
        var json = WalletFixtures.json()
        for actions: Any? in [nil, NSNull(), ["version": 2], ["version": 1]] {
            json["paymentActions"] = actions
            let order = try WalletFixtures.order(json)
            XCTAssertNil(Meld.adapter(for: order))
            XCTAssertThrowsError(try Meld.mount(order))
        }
        var invalidFlags = WalletFixtures.actions()
        invalidFlags["operations"] = [["operation": "SUBMIT_WALLET_PAYMENT", "idempotencyKeyRequired": false],
                                      ["operation": "READ_SUBMISSION", "idempotencyKeyRequired": false]]
        json["paymentActions"] = invalidFlags
        XCTAssertNil(Meld.adapter(for: try WalletFixtures.order(json)))
        json.removeValue(forKey: "headlessPresentation")
        json["paymentActions"] = ["version": 2]
        XCTAssertThrowsError(try MercuryoApplePayAdapter().mount(order: WalletFixtures.order(json),
            context: MeldMountContext(host: nil, applePay: nil), handlers: MeldEventHandlers()))
    }

    func testRedirectsAreRejectedEvenWithinMeldOrigin() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://api-sb.meld.io/redirect")!
        let task = session.dataTask(with: url)
        let response = HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil)!
        var called = false
        PaymentActionRedirectPolicy().urlSession(session, task: task, willPerformHTTPRedirection: response,
                                                 newRequest: URLRequest(url: url)) { request in
            called = true
            XCTAssertNil(request)
        }
        XCTAssertTrue(called)
    }

    func testTransportReturnsGenericVersionedEnvelopeWithoutProviderInterpretation() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ActionURLProtocol.self]
        ActionURLProtocol.status = 200
        ActionURLProtocol.json = ["version": 1, "status": "STRIPE_TEST_STATUS", "nextStep": "STRIPE_TEST_STEP"]
        let client = PaymentActionClient(descriptor: try descriptor(), configuration: configuration)
        defer { client.finish() }
        let done = expectation(description: "response")
        client.send("READ_SUBMISSION") { result in
            XCTAssertTrue(Thread.isMainThread)
            guard case .success(let json) = result else { XCTFail("Expected generic response"); done.fulfill(); return }
            XCTAssertEqual(json["status"] as? String, "STRIPE_TEST_STATUS")
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(ActionURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-session")
        XCTAssertNil(ActionURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Idempotency-Key"))
    }

    func testTransportErrorsDoNotExposeResponseBodies() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ActionURLProtocol.self]
        ActionURLProtocol.status = 400
        ActionURLProtocol.json = ["secret": "synthetic-sensitive-response"]
        let client = PaymentActionClient(descriptor: try descriptor(), configuration: configuration)
        defer { client.finish() }
        let done = expectation(description: "error")
        client.send("READ_SUBMISSION") { result in
            guard case .failure(let error) = result else { XCTFail("Expected failure"); done.fulfill(); return }
            XCTAssertEqual(String(describing: error), "http(400)")
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
    }

    private func descriptor(action: [String: Any] = [:]) throws -> PaymentActionDescriptor {
        var json = WalletFixtures.json()
        json["paymentActions"] = WalletFixtures.actions().merging(action) { _, next in next }
        return try PaymentActionDescriptor(order: WalletFixtures.order(json), environment: .sandbox)
    }
}

private final class ActionURLProtocol: URLProtocol {
    static var status = 200
    static var json: [String: Any] = [:]
    static var lastRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: Self.json))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

// Only synthetic order, wallet and action data. No network is needed by these fixtures.
enum WalletFixtures {
    static let endpoint = "/crypto/order/headless/onramp/TEST_PROVIDER/test-order/actions"
    static let now = Date(timeIntervalSince1970: 1_900_000_000)
    static let payment = WalletPayment(token: "dG9rZW4=", firstName: "Test", lastName: "Customer", email: "test@example.com",
        billing: ApplePayProcessBody.BillingAddress(countryCode: "LT", streetLine1: "1 Test Street", streetLine2: nil,
                                                    stateCode: nil, city: "Test", zipCode: "12345"))
    static func actions() -> [String: Any] {
        ["version": 1, "endpoint": endpoint, "bearerTokenPointer": "/paymentMethodResponseDetails/sessionToken",
         "operations": [["operation": "READ_SUBMISSION", "idempotencyKeyRequired": false],
                        ["operation": "SUBMIT_WALLET_PAYMENT", "idempotencyKeyRequired": true]]]
    }
    static func json() -> [String: Any] {
        ["id": "test-order", "paymentMethodType": "APPLE_PAY", "payload": ["serviceProvider": "TEST_PROVIDER"],
         "headlessPresentation": ["version": 1, "surface": "NATIVE_TOKEN", "protocol": "MELD_WALLET_TOKEN"],
         "paymentMethodResponseDetails": ["sessionToken": "synthetic-session", "merchantTransactionId": "synthetic-id",
                                           "merchantIdentifier": "merchant.example.test"], "paymentActions": actions()]
    }
    static func order(_ json: [String: Any] = json()) throws -> MeldOrder {
        try MeldOrder.from(jsonData: JSONSerialization.data(withJSONObject: json))
    }
    static func response(_ state: String, disposition: String = "RESUME_PAYMENT", expires: Date = now.addingTimeInterval(300)) -> [String: Any] {
        let next: String
        switch state {
        case "NOT_STARTED", "FAILED": next = "NONE"
        case "SUBMITTED", "EXPIRED": next = "WAIT_FOR_PAYMENT"
        case "VERIFICATION_REQUIRED": next = "OPEN_HOSTED_VERIFICATION"
        default: next = "WAIT_FOR_PROVIDER"
        }
        var json: [String: Any] = ["version": 1, "status": state, "nextStep": next]
        if state == "VERIFICATION_REQUIRED" {
            json["verification"] = ["url": "https://sandbox-exchange.mrcr.io/verification?session=synthetic",
                                    "paymentDisposition": disposition, "expiresAt": ISO8601DateFormatter().string(from: expires)]
        }
        return json
    }
}
