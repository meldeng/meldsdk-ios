import PassKit
import XCTest
@testable import MeldSDK

final class PaymentMethodReadinessTests: XCTestCase {
    private final class Asked {
        var devices = 0
        var networks: [[PKPaymentNetwork]] = []
    }

    private func probe(device: Bool = true, cards: Set<PKPaymentNetwork>, asked: Asked = Asked()) -> WalletProbe {
        WalletProbe(device: { asked.devices += 1; return device },
                    wallet: { asked.networks.append($0); return !cards.isDisjoint(with: $0) })
    }

    private let neverAsked = WalletProbe(device: { XCTFail("PassKit asked"); return true },
                                         wallet: { _ in XCTFail("PassKit asked"); return true })

    func testApplePayAsksPassKitOnceAboutEveryNetworkItsPresentationsTake() {
        let asked = Asked()
        XCTAssertEqual(Meld.readiness(of: "APPLE_PAY", probe: probe(cards: [.amex], asked: asked)), .ready,
                       "Mercuryo does not take Amex, but Stripe does")
        XCTAssertEqual(asked.devices, 1)
        XCTAssertEqual(asked.networks.count, 1)
        let union = Set(MercuryoApplePayAdapter.supportedNetworks + StripeNativeOrder.applePayNetworks
                        + MeldApplePayAvailability.supportedNetworks)
        XCTAssertEqual(Set(asked.networks[0]), union)
        XCTAssertEqual(asked.networks[0].count, union.count, "each network once")

        XCTAssertEqual(Meld.readiness(of: "APPLE_PAY", probe: probe(cards: [.visa])), .ready)
        XCTAssertEqual(Meld.readiness(of: "APPLE_PAY", probe: probe(cards: [.JCB])),
                       .unavailable(code: "PAYMENT_METHOD_UNAVAILABLE", reason: "Apple Pay has no usable card on this device."))
        XCTAssertEqual(Meld.readiness(of: "APPLE_PAY", probe: probe(cards: [])),
                       .unavailable(code: "PAYMENT_METHOD_UNAVAILABLE", reason: "Apple Pay has no usable card on this device."))
        let restricted = Asked()
        XCTAssertEqual(Meld.readiness(of: "APPLE_PAY", probe: probe(device: false, cards: [.visa], asked: restricted)),
                       .unavailable(code: "PAYMENT_METHOD_UNAVAILABLE", reason: "Apple Pay is not supported on this device."))
        XCTAssertTrue(restricted.networks.isEmpty, "Wallet is not asked once the device says no")
    }

    func testTheUnionCoversOnlyPresentationsThisDeviceCanShow() throws {
        let asked = Asked()
        let mercuryoOnly = try MeldAdapterRegistry([HostedLinkApplePayAdapter(supportedOS: false), MercuryoApplePayAdapter()])
        XCTAssertEqual(mercuryoOnly.readiness(of: "APPLE_PAY", probe: probe(cards: [.amex], asked: asked)),
                       .unavailable(code: "PAYMENT_METHOD_UNAVAILABLE", reason: "Apple Pay has no usable card on this device."))
        XCTAssertEqual(asked.networks, [MercuryoApplePayAdapter.supportedNetworks])

        let providerSet = try MeldAdapterRegistry([MercuryoApplePayAdapter(), BanxaApplePayAdapter()])
        XCTAssertEqual(providerSet.readiness(of: "APPLE_PAY", probe: probe(cards: [.maestro])), .ready,
                       "a provider that sets its own networks may take any card the SDK's providers take")

        let none = try MeldAdapterRegistry([HostedLinkApplePayAdapter(supportedOS: false)])
        XCTAssertEqual(none.readiness(of: "APPLE_PAY", probe: neverAsked),
                       .unavailable(code: "PAYMENT_METHOD_UNAVAILABLE", reason: "This SDK cannot present APPLE_PAY on this device."))
    }

    func testGooglePayIsUnavailableAndMethodsWithoutADeviceCheckAreUnknown() {
        XCTAssertEqual(Meld.readiness(of: "GOOGLE_PAY", probe: neverAsked),
                       .unavailable(code: MeldErrorCode.paymentMethodUnavailable, reason: "Google Pay is not available on iOS."))
        for method in ["CREDIT_DEBIT_CARD", "SEPA", "ACH", "PIX"] {
            XCTAssertEqual(Meld.readiness(of: method, probe: neverAsked),
                           .unknown(reason: "This payment method has no device check; offer it and let the payment decide."), method)
        }
    }

    func testPublicReadinessAsksThisDevicesPassKit() async {
        let networks = Array(Set(MercuryoApplePayAdapter.supportedNetworks + StripeNativeOrder.applePayNetworks
                                 + MeldApplePayAvailability.supportedNetworks))
        let canPay = PKPaymentAuthorizationController.canMakePayments()
            && PKPaymentAuthorizationController.canMakePayments(usingNetworks: networks)
        let answer = await Meld.paymentMethodReadiness("APPLE_PAY")
        if canPay { XCTAssertEqual(answer, .ready) }
        else if case let .unavailable(code, _) = answer { XCTAssertEqual(code, "PAYMENT_METHOD_UNAVAILABLE") }
        else { XCTFail("\(answer)") }
        let card = await Meld.paymentMethodReadiness("CREDIT_DEBIT_CARD")
        XCTAssertEqual(card, .unknown(reason: "This payment method has no device check; offer it and let the payment decide."))
    }

    func testAnAnswerCanLeaveTheTaskThatAskedForIt() async {
        let answer = await Task.detached { await Meld.paymentMethodReadiness("GOOGLE_PAY") }.value
        XCTAssertEqual(answer, .unavailable(code: "PAYMENT_METHOD_UNAVAILABLE", reason: "Google Pay is not available on iOS."))
    }

    func testCompletionHandlerAnswersOnceOnTheMainQueueAfterReturning() {
        let answered = expectation(description: "answered")
        var answers: [MeldReadiness] = []
        Meld.paymentMethodReadiness("GOOGLE_PAY") { answer in
            XCTAssertTrue(Thread.isMainThread)
            answers.append(answer)
            answered.fulfill()
        }
        XCTAssertTrue(answers.isEmpty, "the answer follows the call, never inside it")
        wait(for: [answered], timeout: 1)
        XCTAssertEqual(answers, [.unavailable(code: "PAYMENT_METHOD_UNAVAILABLE", reason: "Google Pay is not available on iOS.")])
    }
}
