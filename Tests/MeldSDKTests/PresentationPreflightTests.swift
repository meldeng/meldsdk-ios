import XCTest
@testable import MeldSDK

final class PresentationPreflightTests: XCTestCase {
    private func presentation(_ surface: String, _ protocolName: String, version: Any = 1) throws -> MeldHeadlessPresentation {
        try XCTUnwrap(MeldHeadlessPresentation(json: ["surface": surface, "protocol": protocolName, "version": version]))
    }

    func testEveryRegisteredPresentationCanBeInspectedWithoutProviderOrOrderCredentials() throws {
        let examples = [
            ("APPLE_PAY", "NATIVE_TOKEN", "MELD_WALLET_TOKEN", "native-applepay", false),
            ("APPLE_PAY", "PROVIDER_HOSTED", "COINBASE_APPLE_PAY", "embedded", true),
            ("APPLE_PAY", "VENDOR_SDK", "BANXA_CHECKOUT", "native-applepay", false),
            ("CREDIT_DEBIT_CARD", "EMBEDDED_WIDGET", "MERCURYO_WIDGET", "embedded", true),
            ("CREDIT_DEBIT_CARD", "VENDOR_SDK", "BANXA_CHECKOUT", "embedded", true),
            ("CREDIT_DEBIT_CARD", "EMBEDDED_WIDGET", "UPHOLD_WIDGET", "embedded", true),
        ]
        for (method, surface, protocolName, expectedSurface, embeddable) in examples {
            let caps = Meld.capabilities(for: try presentation(surface, protocolName), paymentMethodType: method)
            XCTAssertEqual(caps.surface, expectedSurface, protocolName)
            XCTAssertEqual(caps.embeddable, embeddable, protocolName)
        }
    }

    func testAdvisorySupportCannotAuthorizeAMissingOrInvalidOrderPayload() throws {
        let json: [String: Any] = ["surface": "NATIVE_TOKEN", "protocol": "MELD_WALLET_TOKEN", "version": 1]
        let declared = try XCTUnwrap(MeldHeadlessPresentation(json: json))
        XCTAssertEqual(Meld.capabilities(for: declared, paymentMethodType: "APPLE_PAY").surface, "native-applepay")
        let incomplete = try MeldOrder.from(jsonData: JSONSerialization.data(withJSONObject: [
            "id": "synthetic", "paymentMethodType": "APPLE_PAY", "headlessPresentation": json,
            "paymentMethodResponseDetails": ["sessionToken": "synthetic"],
        ]))
        XCTAssertEqual(Meld.capabilities(for: incomplete).surface, "unsupported")
        XCTAssertThrowsError(try Meld.mount(incomplete))
    }

    func testUnknownAndMismatchedDeclarationsFailClosedWithoutLegacyInference() throws {
        for (surface, protocolName, version) in [("NATIVE_TOKEN", "FUTURE_PROTOCOL", 1),
                                                ("NATIVE_TOKEN", "MELD_WALLET_TOKEN", 2),
                                                ("NATIVE_SDK", "MELD_WALLET_TOKEN", 1)] {
            XCTAssertEqual(Meld.capabilities(for: try presentation(surface, protocolName, version: version),
                                            paymentMethodType: "APPLE_PAY").surface, "unsupported")
        }
        let wallet = try presentation("NATIVE_TOKEN", "MELD_WALLET_TOKEN")
        for method in ["CREDIT_DEBIT_CARD", "apple_pay", "APPLE_PAY ", "", "FUTURE_METHOD"] {
            XCTAssertEqual(Meld.capabilities(for: wallet, paymentMethodType: method).surface, "unsupported")
        }
    }

    func testPublicDecoderRejectsMalformedDeclarationsAndPreservesUnknownValues() throws {
        for version: Any in [true, "1", 0, -1, 1.5, 2147483648, NSNull()] {
            XCTAssertNil(MeldHeadlessPresentation(json: ["surface": "NATIVE_SDK", "protocol": "TEST", "version": version]))
        }
        for invalid in ["native_sdk", "NATIVE_SDK\n", "", String(repeating: "A", count: 65)] {
            XCTAssertNil(MeldHeadlessPresentation(json: ["surface": invalid, "protocol": "TEST", "version": 1]))
            XCTAssertNil(MeldHeadlessPresentation(json: ["surface": "NATIVE_SDK", "protocol": invalid, "version": 1]))
        }
        XCTAssertNil(MeldHeadlessPresentation(json: [:]))
        XCTAssertEqual(try presentation("FUTURE_SURFACE", "FUTURE_PROTOCOL", version: 3).version, 3)
    }

    func testNewAdapterEnablesPreflightAndOrderDispatchFromOneRegistration() throws {
        let future = try presentation("FUTURE_SURFACE", "FUTURE_PROTOCOL", version: 3)
        let registry = try MeldAdapterRegistry([PreflightTestAdapter()])
        XCTAssertEqual(registry.adapter(for: future, paymentMethodType: "APPLE_PAY")?.capabilities.surface, "test")
        let order = try MeldOrder.from(jsonData: JSONSerialization.data(withJSONObject: [
            "id": "synthetic", "paymentMethodType": "APPLE_PAY", "payload": ["serviceProvider": "NEW_PROVIDER"],
            "headlessPresentation": ["surface": "FUTURE_SURFACE", "protocol": "FUTURE_PROTOCOL", "version": 3],
        ]))
        XCTAssertTrue(registry.adapter(for: order) is PreflightTestAdapter)
        XCTAssertEqual(Meld.capabilities(for: future, paymentMethodType: "APPLE_PAY").surface, "unsupported")
    }
}

private struct PreflightTestAdapter: MeldAdapter {
    let label = "Synthetic preflight adapter"
    let presentations = [MeldAdapterPresentation("APPLE_PAY", "FUTURE_SURFACE", "FUTURE_PROTOCOL", version: 3)]
    let capabilities = MeldCapabilities(embeddable: false, surface: "test", requiresUserGesture: true)
    func matches(_ order: MeldOrder) -> Bool { false }
    func acceptsDeclaredOrder(_ order: MeldOrder) -> Bool { true }
    func mount(order: MeldOrder, context: MeldMountContext, handlers: MeldEventHandlers) throws -> MeldProviderSession {
        throw MeldMountError.unsupported("Synthetic adapter")
    }
}
