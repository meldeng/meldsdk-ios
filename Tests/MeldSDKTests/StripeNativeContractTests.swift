import PassKit
import XCTest
@testable import MeldSDK

final class StripeNativeContractTests: XCTestCase {
    func testValidContractUsesDeclaredProtocolAndServerBoundConfiguration() throws {
        let value = try StripeNativeOrder(order(), environment: .sandbox)
        XCTAssertEqual(value.walletNetwork, "base")
        XCTAssertEqual(value.walletAddress, "wallet-synthetic")
        XCTAssertEqual(value.amount, 20)
        XCTAssertEqual(value.merchantIdentifier, "merchant.example.stripe")
        XCTAssertEqual(value.actions.operations["READ_SUBMISSION"], false)
        XCTAssertEqual(value.description, "StripeNativeOrder[REDACTED]")
        XCTAssertFalse(value.description.contains("wallet-synthetic"))
        XCTAssertEqual(Meld.capabilities(for: try order()).surface, "native-sdk")
    }

    func testBackendsWithoutLegalActionsCannotSelectTheNativeFlow() throws {
        for missing in ["READ_LEGAL_DISCLOSURE", "RECORD_LEGAL_EVIDENCE"] {
            try rejected { root in
                var actions = root["paymentActions"] as! [String: Any]
                actions["operations"] = (actions["operations"] as! [[String: Any]]).filter { $0["operation"] as? String != missing }
                root["paymentActions"] = actions
            }
        }
    }

    func testHistoricalAndIncompleteBootstrapsCannotSelectAWorkingNativeFlow() throws {
        for field in ["sdkBootstrapType", "providerIntentId", "sdkFlow", "sdkEnvironment", "expiresAtEpochSeconds", "clientConfiguration"] {
            try rejected { root in
                var details = root["paymentMethodResponseDetails"] as! [String: Any]
                details.removeValue(forKey: field); root["paymentMethodResponseDetails"] = details
            }
        }
        try rejected { $0.removeValue(forKey: "headlessPresentation") }
        try rejected { $0.removeValue(forKey: "paymentActions") }
        try rejected { $0["headlessPresentation"] = ["surface": "NATIVE_SDK", "protocol": "STRIPE_CRYPTO_ONRAMP", "version": 2] }
        try rejected { $0["paymentMethodType"] = "ACH" }
    }

    func testPublicKeyEnvironmentMerchantAndNetworkCannotBeBorrowedOrGuessed() throws {
        for key in ["sk_test_synthetic", "pk_live_synthetic", "pk_test_bad\n", "pk_test_"] {
            try rejectedConfiguration("publicKey", key)
        }
        for merchant in ["", "merchant.", "merchant..bad", "merchant.example\n"] {
            try rejectedConfiguration("merchantIdentifier", merchant)
        }
        for network in ["BASE", "ETH", "unknown", "base\n"] { try rejectedConfiguration("walletNetwork", network) }
        XCTAssertThrowsError(try StripeNativeOrder(order(), environment: .production))
        let production = try order { root in
            var details = root["paymentMethodResponseDetails"] as! [String: Any]
            details["sdkEnvironment"] = "PRODUCTION"
            var config = details["clientConfiguration"] as! [String: Any]
            config["publicKey"] = "pk_live_synthetic"; details["clientConfiguration"] = config
            root["paymentMethodResponseDetails"] = details
        }
        XCTAssertNoThrow(try StripeNativeOrder(production, environment: .production))
    }

    func testCardDoesNotNeedApplePayMerchantAndCannotCreateAWalletRequest() throws {
        let card = try order { root in
            root["paymentMethodType"] = "CREDIT_DEBIT_CARD"
            var details = root["paymentMethodResponseDetails"] as! [String: Any]
            var config = details["clientConfiguration"] as! [String: Any]
            config.removeValue(forKey: "merchantIdentifier"); details["clientConfiguration"] = config
            root["paymentMethodResponseDetails"] = details
        }
        let value = try StripeNativeOrder(card, environment: .sandbox)
        XCTAssertNil(value.merchantIdentifier)
        XCTAssertThrowsError(try value.paymentRequest())
    }

    func testRequiredOperationAndIdempotencyDeclarationsAreValidated() throws {
        for mutation in [false, true] {
            try rejected { root in
                var actions = root["paymentActions"] as! [String: Any]
                var operations = actions["operations"] as! [[String: Any]]
                if mutation { operations[0]["idempotencyKeyRequired"] = true }
                else { operations.removeFirst() }
                actions["operations"] = operations; root["paymentActions"] = actions
            }
        }
        try rejected { root in
            var actions = root["paymentActions"] as! [String: Any]
            actions["endpoint"] = "/crypto/order/headless/onramp/TEST_PROVIDER/other-order/actions"
            root["paymentActions"] = actions
        }
        try rejected { root in
            var actions = root["paymentActions"] as! [String: Any]
            actions["operations"] = (actions["operations"] as! [[String: Any]]).filter { $0["operation"] as? String != "PREPARE_CUSTOMER_AUTHORIZATION" }
            root["paymentActions"] = actions
        }
    }

    func testWalletRequestUsesTheBoundTotalAndRejectsCallerOverrides() throws {
        let value = try StripeNativeOrder(order(), environment: .sandbox)
        let request = try value.paymentRequest(MeldApplePayRequest(amount: 20, currencyCode: "USD", summaryItemLabel: "Buy crypto"))
        XCTAssertEqual(request.merchantIdentifier, "merchant.example.stripe")
        XCTAssertEqual(request.countryCode, "US")
        XCTAssertEqual(request.currencyCode, "USD")
        XCTAssertEqual(request.paymentSummaryItems.last?.amount, NSDecimalNumber(value: 20))
        XCTAssertEqual(request.paymentSummaryItems.last?.type, .final)
        XCTAssertThrowsError(try value.paymentRequest(MeldApplePayRequest(amount: 30, currencyCode: "USD")))
        XCTAssertThrowsError(try value.paymentRequest(MeldApplePayRequest(amount: 20, currencyCode: "EUR")))
        XCTAssertThrowsError(try value.paymentRequest(MeldApplePayRequest(amount: 20, currencyCode: "USD", summaryItemLabel: "")))
    }

    func testMalformedRouteAndAmountCannotReachTheSdk() throws {
        for amount: Any in [true, 0, -1, 20.001, "20"] {
            try rejected { root in
                var payload = root["payload"] as! [String: Any]
                payload["sourceAmount"] = amount; root["payload"] = payload
            }
        }
        for field in ["sourceCurrencyCode", "countryCode", "destinationWalletAddress"] {
            try rejected { root in
                var payload = root["payload"] as! [String: Any]
                payload[field] = ""; root["payload"] = payload
            }
        }
    }

    func testCheckoutCallbackPairsAreDistinctWhileOneInvocationCanBeReused() {
        let first = StripeCheckoutInvocation(), second = StripeCheckoutInvocation()
        XCTAssertNotEqual(first.callbackID, second.callbackID)
        XCTAssertNotEqual(first.idempotencyKey, second.idempotencyKey)
        XCTAssertEqual(first.fields["callbackInvocationId"] as? String, first.callbackID.uuidString.lowercased())
        XCTAssertEqual(first.fields.count, 1)
        XCTAssertFalse(first.description.contains(first.callbackID.uuidString))
    }

    private func rejectedConfiguration(_ field: String, _ value: Any) throws {
        try rejected { root in
            var details = root["paymentMethodResponseDetails"] as! [String: Any]
            var config = details["clientConfiguration"] as! [String: Any]
            config[field] = value; details["clientConfiguration"] = config
            root["paymentMethodResponseDetails"] = details
        }
    }

    private func rejected(_ change: (inout [String: Any]) -> Void) throws {
        XCTAssertThrowsError(try StripeNativeOrder(order(change), environment: .sandbox))
    }

    private func order(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> MeldOrder {
        var value: [String: Any] = [
            "id": "test-order", "paymentMethodType": "APPLE_PAY",
            "headlessPresentation": ["surface": "NATIVE_SDK", "protocol": "STRIPE_CRYPTO_ONRAMP", "version": 1],
            "payload": ["serviceProvider": "TEST_PROVIDER", "sourceAmount": 20, "sourceCurrencyCode": "USD",
                        "countryCode": "US", "destinationWalletAddress": "wallet-synthetic"],
            "paymentMethodResponseDetails": ["sdkBootstrapType": "STRIPE_CRYPTO_ONRAMP", "providerIntentId": "lai_synthetic",
                                             "sdkFlow": "AUTHORIZE", "sdkEnvironment": "SANDBOX", "expiresAtEpochSeconds": 1_900_000_000,
                                             "continuationToken": "synthetic-bearer",
                                             "clientConfiguration": ["publicKey": "pk_test_synthetic", "walletNetwork": "base",
                                                                     "merchantIdentifier": "merchant.example.stripe"]],
            "paymentActions": ["version": 1, "endpoint": "/crypto/order/headless/onramp/TEST_PROVIDER/test-order/actions",
                               "bearerTokenPointer": "/paymentMethodResponseDetails/continuationToken",
                               "operations": ["READ_SUBMISSION", "READ_CUSTOMER_STATUS", "READ_LIMITS", "READ_LEGAL_DISCLOSURE", "RECORD_LEGAL_EVIDENCE",
                                              "COMPLETE_CUSTOMER_LINK", "CREATE_CUSTOMER_AUTH_TOKEN", "PREPARE_CUSTOMER_AUTHORIZATION", "CREATE_PAYMENT_SESSION",
                                              "CONFIRM_PAYMENT", "REFRESH_QUOTE"].map {
                                                  ["operation": $0, "idempotencyKeyRequired": !$0.hasPrefix("READ_")] as [String: Any]
                                              }],
        ]
        change(&value)
        return try MeldOrder.from(jsonData: JSONSerialization.data(withJSONObject: value))
    }
}
