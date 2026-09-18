import XCTest
@testable import MeldSDK

final class HeadlessPresentationTests: XCTestCase {
    private let nativeDetails: [String: Any] = [
        "sessionToken": "test-session", "merchantTransactionId": "test-session-id",
        "merchantIdentifier": "merchant.example.test",
    ]

    private func order(method: String = "APPLE_PAY", presentation: Any?,
                       details: [String: Any]? = nil, provider: String = "TEST_PROVIDER") throws -> MeldOrder {
        var json: [String: Any] = [
            "id": "test-order", "paymentMethodType": method,
            "payload": ["serviceProvider": provider], "paymentMethodResponseDetails": details ?? nativeDetails,
            "paymentActions": ["version": 1, "endpoint": "/crypto/order/headless/onramp/\(provider)/test-order/actions",
                               "bearerTokenPointer": "/paymentMethodResponseDetails/sessionToken",
                               "operations": [["operation": "READ_SUBMISSION", "idempotencyKeyRequired": false],
                                              ["operation": "SUBMIT_WALLET_PAYMENT", "idempotencyKeyRequired": true]]],
        ]
        if let presentation { json["headlessPresentation"] = presentation }
        else { json.removeValue(forKey: "paymentActions") }
        return try MeldOrder.from(jsonData: JSONSerialization.data(withJSONObject: json))
    }

    private func descriptor(_ surface: String = "SYSTEM_WALLET_TOKEN", _ protocolName: String = "MELD_WALLET_TOKEN",
                            version: Any = 1) -> [String: Any] {
        ["surface": surface, "protocol": protocolName, "version": version]
    }

    func testDeclaredNativeWalletUsesTheRegisteredProtocol() throws {
        let order = try order(presentation: descriptor())
        XCTAssertEqual(order.headlessPresentation?.protocolName, "MELD_WALLET_TOKEN")
        XCTAssertEqual(order.headlessPresentation?.version, 1)
        XCTAssertTrue(Meld.adapter(for: order) is MercuryoApplePayAdapter)
        XCTAssertEqual(Meld.capabilities(for: order).surface, "native-applepay")
        // Mount reads the canonical action state before deciding whether a new sheet is needed.
    }

    func testBanxaProtocolDoesNotNeedProviderNameOrRegistryPrecedence() throws {
        let order = try order(presentation: descriptor("VENDOR_SDK", "BANXA_CHECKOUT"),
                              details: ["sessionToken": "test-primer-token"])
        // The same sessionToken used to fingerprint as nativeToken. The new protocol takes precedence.
        XCTAssertEqual(order.presentation, .nativeToken)
        let registry = try MeldAdapterRegistry([MercuryoApplePayAdapter(), BanxaApplePayAdapter()])
        XCTAssertTrue(registry.adapter(for: order) is BanxaApplePayAdapter)
    }

    func testHostedProtocolNeedsAnAllowedHttpsLink() throws {
        let presentation = descriptor("PROVIDER_HOSTED", "COINBASE_APPLE_PAY")
        for link in ["https://pay.coinbase.com/buy/test", "https://pay-sandbox.coinbase.com/buy/test"] {
            let order = try order(presentation: presentation, details: ["paymentLinkUrl": link])
            XCTAssertTrue(Meld.adapter(for: order) is HostedLinkApplePayAdapter)
            XCTAssertTrue(Meld.capabilities(for: order).embeddable)
            XCTAssertTrue(Meld.capabilities(for: order).requiresUserGesture)
        }
        for link in ["http://pay.coinbase.com/test", "https://coinbase.com.attacker.test/x",
                     "https://user:password@pay.coinbase.com/x", "https://pay.coinbase.com:8443/x",
                     "https://other.example/x", "javascript:alert(1)"] {
            try assertUnsupported(order(presentation: presentation, details: ["paymentLinkUrl": link]))
        }
    }

    func testDeclaredCardProtocolsValidateTheirPayloadInsteadOfFallingThrough() throws {
        let examples: [(String, [String: Any], Any.Type)] = [
            ("MERCURYO_WIDGET", ["renderMode": "IFRAME", "serviceProviderWidgetUrl": "https://sandbox-exchange.mrcr.io/x"],
             MercuryoCardAdapter.self),
            ("BANXA_CHECKOUT", ["renderMode": "IFRAME", "sdkSessionToken": "test-primer-token"], BanxaCardAdapter.self),
            ("UPHOLD_WIDGET", ["renderMode": "IFRAME", "serviceProviderWidgetUrl": "https://api.enterprise.sandbox.uphold.com/x"],
             UpholdCardAdapter.self),
        ]
        for (protocolName, details, expected) in examples {
            let order = try order(method: "CREDIT_DEBIT_CARD",
                                  presentation: descriptor("EMBEDDED_WIDGET", protocolName), details: details)
            let adapter = try XCTUnwrap(Meld.adapter(for: order))
            XCTAssertEqual(String(describing: type(of: adapter)), String(describing: expected))
        }
        try assertUnsupported(order(method: "CREDIT_DEBIT_CARD",
                                    presentation: descriptor("EMBEDDED_WIDGET", "MERCURYO_WIDGET"),
                                    details: ["renderMode": "IFRAME", "serviceProviderWidgetUrl": "https://other.example/x"]))
        try assertUnsupported(order(method: "CREDIT_DEBIT_CARD",
                                    presentation: descriptor("EMBEDDED_WIDGET", "BANXA_CHECKOUT"),
                                    details: ["renderMode": "IFRAME", "serviceProviderWidgetUrl": "https://sandbox-exchange.mrcr.io/x"]))
    }

    func testUnknownProtocolVersionSurfaceAndMethodNeverUseLegacyFallback() throws {
        for declaration in [descriptor("SYSTEM_WALLET_TOKEN", "FUTURE_PROTOCOL"), descriptor(version: 2),
                            descriptor("NATIVE_SDK", "MELD_WALLET_TOKEN"),
                            descriptor("NATIVE_SDK", "STRIPE_CRYPTO_ONRAMP")] {
            let order = try order(presentation: declaration)
            XCTAssertNotNil(order.headlessPresentation, "Unknown valid metadata remains inspectable")
            try assertUnsupported(order)
        }
        try assertUnsupported(order(method: "CREDIT_DEBIT_CARD", presentation: descriptor()))
    }

    func testMalformedDeclarationsAreNotTreatedAsAbsent() throws {
        let malformed: [Any] = [NSNull(), "MELD_WALLET_TOKEN", [], [:],
                                descriptor(version: true), descriptor(version: "1"), descriptor(version: 0),
                                descriptor(version: -1), descriptor(version: 1.5), descriptor(version: 2147483648),
                                descriptor("system_wallet_token"), descriptor("SYSTEM_WALLET_TOKEN", ""),
                                descriptor("SYSTEM_WALLET_TOKEN", "MELD_WALLET_TOKEN\n")]
        for declaration in malformed {
            let order = try order(presentation: declaration)
            XCTAssertNil(order.headlessPresentation)
            try assertUnsupported(order)
        }
    }

    func testMissingRequiredNativeDataAndConflictingLegacyPresentationAreUnsupported() throws {
        var missing = nativeDetails
        missing.removeValue(forKey: "merchantIdentifier")
        try assertUnsupported(order(presentation: descriptor(), details: missing))
        var conflicting = nativeDetails
        conflicting["presentation"] = "VENDOR_SDK"
        try assertUnsupported(order(presentation: descriptor(), details: conflicting))
        conflicting["presentation"] = true
        try assertUnsupported(order(presentation: descriptor(), details: conflicting))
    }

    func testExistingStoredOrderWithoutDescriptorKeepsItsLegacyAdapter() throws {
        let order = try order(presentation: nil, provider: "MERCURYO")
        XCTAssertNil(order.headlessPresentation)
        XCTAssertTrue(Meld.adapter(for: order) is MercuryoApplePayAdapter)
        // Sparse historical payloads retain their precise mount-time validation error.
        let sparse = try self.order(presentation: nil, details: [:], provider: "MERCURYO")
        XCTAssertTrue(Meld.adapter(for: sparse) is MercuryoApplePayAdapter)
    }

    func testFutureProtocolIsImplementedByOneNewAdapterRegistration() throws {
        let order = try order(presentation: descriptor("FUTURE_SURFACE", "FUTURE_PROTOCOL", version: 3))
        let registry = try MeldAdapterRegistry([MercuryoApplePayAdapter(), FutureAdapter()])
        XCTAssertTrue(registry.adapter(for: order) is FutureAdapter)
        try assertUnsupported(order) // The shipped registry does not pretend to implement the test protocol.
    }

    func testDuplicateProtocolRegistrationsAreRejectedRegardlessOfAdapterOrder() {
        XCTAssertThrowsError(try MeldAdapterRegistry([FutureAdapter(), FutureAdapter()]))
    }

    private func assertUnsupported(_ order: MeldOrder, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertNil(Meld.adapter(for: order), file: file, line: line)
        XCTAssertEqual(Meld.capabilities(for: order).surface, "unsupported", file: file, line: line)
        XCTAssertThrowsError(try Meld.mount(order), file: file, line: line) {
            guard case MeldMountError.unsupported = $0 else { return XCTFail("Expected unsupported", file: file, line: line) }
        }
    }
}

private struct FutureAdapter: MeldAdapter {
    let label = "Test protocol"
    let presentations = [MeldAdapterPresentation("APPLE_PAY", "FUTURE_SURFACE", "FUTURE_PROTOCOL", version: 3)]
    let capabilities = MeldCapabilities(embeddable: false, surface: "test", requiresUserGesture: false)
    func matches(_ order: MeldOrder) -> Bool { false }
    func acceptsDeclaredOrder(_ order: MeldOrder) -> Bool { true }
    func mount(order: MeldOrder, context: MeldMountContext, handlers: MeldEventHandlers) throws -> MeldProviderSession {
        throw MeldMountError.unsupported("The test adapter has no payment surface")
    }
}
