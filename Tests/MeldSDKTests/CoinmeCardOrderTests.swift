import XCTest
@testable import MeldSDK

final class CoinmeCardOrderTests: XCTestCase {
    func testDeclaredOrderIsAdmittedWithItsSessionData() throws {
        let order = try CoinmeFixture.meldOrder()
        XCTAssertTrue(Meld.adapter(for: order) is CoinmeCardAdapter)
        XCTAssertEqual(Meld.capabilities(for: order).surface, "embedded")
        XCTAssertTrue(Meld.capabilities(for: order).embeddable)
        let value = try CoinmeCardOrder(order, environment: .sandbox)
        XCTAssertEqual(value.id, "test-order")
        XCTAssertFalse(value.live)
        XCTAssertEqual(value.actions.operations, ["CREATE_CUSTOMER_AUTH_TOKEN": true, "CREATE_PAYMENT_SESSION": true])
        XCTAssertEqual(value.description, "CoinmeCardOrder[REDACTED]")
        XCTAssertNoThrow(try CoinmeCardOrder(CoinmeFixture.meldOrder(savedCards: []), environment: .sandbox))
    }

    func testBothOperationsMustBeDeclaredWithIdempotency() throws {
        for operations in [
            [["operation": "CREATE_PAYMENT_SESSION", "idempotencyKeyRequired": true]],
            [["operation": "CREATE_CUSTOMER_AUTH_TOKEN", "idempotencyKeyRequired": true]],
            [["operation": "CREATE_CUSTOMER_AUTH_TOKEN", "idempotencyKeyRequired": true],
             ["operation": "CREATE_PAYMENT_SESSION", "idempotencyKeyRequired": false]],
        ] as [[[String: Any]]] {
            try assertRejected { root in
                var actions = root["paymentActions"] as! [String: Any]
                actions["operations"] = operations
                root["paymentActions"] = actions
            }
        }
        try assertRejected { $0.removeValue(forKey: "paymentActions") }
        try assertRejected { root in
            var actions = root["paymentActions"] as! [String: Any]
            actions["endpoint"] = "/crypto/order/headless/onramp/COINME/other-order/actions"
            root["paymentActions"] = actions
        }
    }

    func testOnlyTheExactPresentationAndMethodAreAdmitted() throws {
        for presentation: [String: Any] in [
            ["surface": "VENDOR_SDK", "protocol": "COINME_VAULT", "version": 2],
            ["surface": "EMBEDDED_WIDGET", "protocol": "COINME_VAULT", "version": 1],
            ["surface": "NATIVE_SDK", "protocol": "COINME_VAULT", "version": 1],
        ] {
            try assertRejected { $0["headlessPresentation"] = presentation }
        }
        try assertRejected { $0["paymentMethodType"] = "APPLE_PAY" }
        // Without a declaration the order is a legacy one, which this protocol never claims.
        let legacy = try CoinmeFixture.meldOrder { $0.removeValue(forKey: "headlessPresentation") }
        XCTAssertThrowsError(try CoinmeCardOrder(legacy, environment: .sandbox))
        XCTAssertFalse(Meld.adapter(for: legacy) is CoinmeCardAdapter)
    }

    func testMissingOrMalformedSessionDataIsRejected() throws {
        for field in ["customerId", "paymentProviderId", "riskClientId", "riskPartnerId", "environment"] {
            try assertSessionDataRejected { $0.removeValue(forKey: field) }
        }
        try assertSessionDataRejected { $0["environment"] = "production" }
        try assertSessionDataRejected { $0["customerId"] = "has space" }
        try assertSessionDataRejected { $0["savedCards"] = "1111" }
        try assertRejected { root in
            var details = root["paymentMethodResponseDetails"] as! [String: Any]
            details.removeValue(forKey: "sdkSessionToken")
            root["paymentMethodResponseDetails"] = details
        }
    }

    func testCoinmeEnvironmentMustMatchTheConfiguredMeldEnvironment() throws {
        let sandbox = try CoinmeFixture.meldOrder()
        XCTAssertNoThrow(try CoinmeCardOrder(sandbox, environment: .qa))
        XCTAssertThrowsError(try CoinmeCardOrder(sandbox, environment: .production))
        let live = try CoinmeFixture.meldOrder { root in
            var details = root["paymentMethodResponseDetails"] as! [String: Any]
            var data = details["sdkSessionData"] as! [String: Any]
            data["environment"] = "live"
            details["sdkSessionData"] = data
            root["paymentMethodResponseDetails"] = details
        }
        XCTAssertThrowsError(try CoinmeCardOrder(live, environment: .sandbox))
        XCTAssertTrue(try CoinmeCardOrder(live, environment: .production).live)
    }

    func testMountNeedsAHostView() throws {
        XCTAssertThrowsError(try CoinmeCardAdapter().mount(order: CoinmeFixture.meldOrder(),
                                                         context: MeldMountContext(host: nil, applePay: nil),
                                                         handlers: MeldEventHandlers())) {
            guard case MeldMountError.missingHost = $0 else { return XCTFail("Expected missingHost, got \($0)") }
        }
    }

    private func assertSessionDataRejected(_ change: @escaping (inout [String: Any]) -> Void,
                                           file: StaticString = #filePath, line: UInt = #line) throws {
        try assertRejected(file: file, line: line) { root in
            var details = root["paymentMethodResponseDetails"] as! [String: Any]
            var data = details["sdkSessionData"] as! [String: Any]
            change(&data)
            details["sdkSessionData"] = data
            root["paymentMethodResponseDetails"] = details
        }
    }

    private func assertRejected(file: StaticString = #filePath, line: UInt = #line,
                                _ change: (inout [String: Any]) -> Void) throws {
        let order = try CoinmeFixture.meldOrder(change)
        XCTAssertThrowsError(try CoinmeCardOrder(order, environment: .sandbox), file: file, line: line)
        XCTAssertEqual(Meld.capabilities(for: order).surface, "unsupported", file: file, line: line)
    }
}

enum CoinmeFixture {
    static let visa: [String: Any] = ["paymentMethodId": "1430243266422767616", "brand": "Visa", "bin": "411111",
                                      "last4": "1111", "expMonth": "12", "expYear": "2030"]

    static func json(savedCards: [[String: Any]] = [visa], _ change: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
        var value: [String: Any] = [
            "id": "test-order", "paymentMethodType": "CREDIT_DEBIT_CARD", "responseKind": "SESSION",
            "headlessPresentation": ["surface": "VENDOR_SDK", "protocol": "COINME_VAULT", "version": 1],
            "payload": ["serviceProvider": "COINME", "sourceAmount": 20, "sourceCurrencyCode": "USD",
                        "destinationCurrencyCode": "USDC"],
            "paymentMethodResponseDetails": [
                "renderMode": "IFRAME", "continuationToken": "synthetic-bearer", "sdkSessionToken": "synthetic-browser-token",
                "sdkSessionData": ["customerId": "1428417779958550528", "paymentProviderId": "828627387817136137",
                                   "environment": "sandbox", "riskClientId": "synthetic-risk-client",
                                   "riskPartnerId": "synthetic-partner", "savedCards": savedCards] as [String: Any],
            ] as [String: Any],
            "paymentActions": ["version": 1, "endpoint": "/crypto/order/headless/onramp/COINME/test-order/actions",
                               "bearerTokenPointer": "/paymentMethodResponseDetails/continuationToken",
                               "operations": [["operation": "CREATE_CUSTOMER_AUTH_TOKEN", "idempotencyKeyRequired": true],
                                              ["operation": "CREATE_PAYMENT_SESSION", "idempotencyKeyRequired": true]]] as [String: Any],
        ]
        change(&value)
        return value
    }

    static func meldOrder(savedCards: [[String: Any]] = [visa], _ change: (inout [String: Any]) -> Void = { _ in }) throws -> MeldOrder {
        try MeldOrder.from(jsonData: JSONSerialization.data(withJSONObject: json(savedCards: savedCards, change)))
    }
}
