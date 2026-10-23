import PassKit
import XCTest
@testable import MeldSDK

final class PresentationReadinessTests: XCTestCase {
    private let rows = [
        ("APPLE_PAY", "NATIVE_TOKEN", "MELD_WALLET_TOKEN"),
        ("APPLE_PAY", "NATIVE_SDK", "STRIPE_CRYPTO_ONRAMP"),
        ("APPLE_PAY", "PROVIDER_HOSTED", "COINBASE_APPLE_PAY"),
        ("APPLE_PAY", "VENDOR_SDK", "BANXA_CHECKOUT"),
        ("CREDIT_DEBIT_CARD", "NATIVE_SDK", "STRIPE_CRYPTO_ONRAMP"),
        ("CREDIT_DEBIT_CARD", "EMBEDDED_WIDGET", "MERCURYO_WIDGET"),
        ("CREDIT_DEBIT_CARD", "EMBEDDED_WIDGET", "UPHOLD_WIDGET"),
        ("CREDIT_DEBIT_CARD", "VENDOR_SDK", "BANXA_CHECKOUT"),
    ]

    private func presentation(_ surface: String, _ protocolName: String, version: Int = 1) throws -> MeldHeadlessPresentation {
        try XCTUnwrap(MeldHeadlessPresentation(json: ["surface": surface, "protocol": protocolName, "version": version]))
    }

    private func probe(device: Bool = true, cards: Set<PKPaymentNetwork>) -> WalletProbe {
        WalletProbe(device: { device }, wallet: { !cards.isDisjoint(with: $0) })
    }

    private func status(_ readiness: MeldReadiness) -> String {
        switch readiness {
        case .ready: return "ready"
        case let .unavailable(code, _): return "unavailable:\(code)"
        case .unknown: return "unknown"
        }
    }

    private func answers(_ probe: WalletProbe) throws -> [String] {
        try rows.map { method, surface, protocolName in
            status(Meld.readiness(for: try presentation(surface, protocolName), paymentMethodType: method, probe: probe))
        }
    }

    func testEachApplePayPresentationAsksForItsOwnNetworksAndCardsAreNotChecked() throws {
        let unavailable = "unavailable:PAYMENT_METHOD_UNAVAILABLE"
        let cards = Array(repeating: "unknown", count: 4)
        XCTAssertEqual(try answers(probe(cards: [.visa])), ["ready", "ready", "unknown", "unknown"] + cards)
        XCTAssertEqual(try answers(probe(cards: [.amex])), [unavailable, "ready", "unknown", "unknown"] + cards,
                       "Mercuryo takes only Visa and Mastercard")
        XCTAssertEqual(try answers(probe(cards: [.JCB])), Array(repeating: unavailable, count: 4) + cards)
        XCTAssertEqual(try answers(probe(cards: [])), Array(repeating: unavailable, count: 4) + cards, "an empty Wallet")
        XCTAssertEqual(try answers(probe(device: false, cards: [.visa])), Array(repeating: unavailable, count: 4) + cards)
        XCTAssertEqual(Meld.readiness(for: try presentation("NATIVE_TOKEN", "MELD_WALLET_TOKEN"), paymentMethodType: "APPLE_PAY",
                                      probe: probe(device: false, cards: [.visa])),
                       .unavailable(code: "PAYMENT_METHOD_UNAVAILABLE", reason: "Apple Pay is not supported on this device."))
    }

    func testAPresentationThisSDKDoesNotRegisterIsUnavailable() throws {
        let anything = probe(cards: [.visa])
        for (method, surface, protocolName, version) in [("APPLE_PAY", "NATIVE_TOKEN", "FUTURE_PROTOCOL", 1),
                                                         ("APPLE_PAY", "NATIVE_TOKEN", "MELD_WALLET_TOKEN", 2),
                                                         ("CREDIT_DEBIT_CARD", "NATIVE_TOKEN", "MELD_WALLET_TOKEN", 1),
                                                         ("GOOGLE_PAY", "PROVIDER_HOSTED", "COINBASE_APPLE_PAY", 1)] {
            let answer = Meld.readiness(for: try presentation(surface, protocolName, version: version),
                                        paymentMethodType: method, probe: anything)
            XCTAssertEqual(answer, .unavailable(code: MeldErrorCode.paymentMethodUnavailable,
                                                reason: "This SDK does not present \(method) via \(surface)/\(protocolName) v\(version)."))
        }
    }

    func testAPresentationThisDeviceCannotHostIsUnavailableWithoutAskingPassKit() throws {
        let registry = try MeldAdapterRegistry([HostedLinkApplePayAdapter(supportedOS: false)])
        let asked = WalletProbe(device: { XCTFail("PassKit asked"); return true }, wallet: { _ in XCTFail("PassKit asked"); return true })
        XCTAssertEqual(registry.readiness(for: try presentation("PROVIDER_HOSTED", "COINBASE_APPLE_PAY"),
                                          paymentMethodType: "APPLE_PAY", probe: asked),
                       .unavailable(code: "PAYMENT_METHOD_UNAVAILABLE", reason: "This SDK cannot present this payment method on this device."))
    }

    func testPublicReadinessAsksThisDevicesPassKit() async throws {
        let mercuryo = try presentation("NATIVE_TOKEN", "MELD_WALLET_TOKEN")
        let canPay = PKPaymentAuthorizationController.canMakePayments()
            && PKPaymentAuthorizationController.canMakePayments(usingNetworks: MercuryoApplePayAdapter.supportedNetworks)
        let answer = await Meld.presentationReadiness(mercuryo, paymentMethodType: "APPLE_PAY")
        XCTAssertEqual(status(answer), canPay ? "ready" : "unavailable:PAYMENT_METHOD_UNAVAILABLE")
        let card = await Meld.presentationReadiness(try presentation("EMBEDDED_WIDGET", "MERCURYO_WIDGET"),
                                                    paymentMethodType: "CREDIT_DEBIT_CARD")
        XCTAssertEqual(card, .unknown(reason: "This payment method has no device check; offer it and let the payment decide."))
    }

    func testCompletionHandlerAnswersOnceOnTheMainThreadAfterReturning() throws {
        let answered = expectation(description: "answered")
        var answers: [MeldReadiness] = []
        Meld.presentationReadiness(try presentation("NATIVE_TOKEN", "FUTURE_PROTOCOL"), paymentMethodType: "APPLE_PAY") { answer in
            XCTAssertTrue(Thread.isMainThread)
            answers.append(answer)
            answered.fulfill()
        }
        XCTAssertTrue(answers.isEmpty, "the answer follows the call, never inside it")
        wait(for: [answered], timeout: 1)
        XCTAssertEqual(answers.map(status), ["unavailable:PAYMENT_METHOD_UNAVAILABLE"])
    }
}
