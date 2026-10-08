import PassKit
import UIKit
import XCTest
@testable import MeldSDK

@MainActor
final class StripeFlowControllerTests: XCTestCase {
    func testNewPaymentOwnsFormsAndSdkFlowAndWaitsForServerSettlement() async throws {
        let h = try FlowHarness(applePay: true, registration: true)
        h.driver.hasAccountResult = false
        h.client.responses = FlowHarness.bootstrap + [FlowHarness.customer(), FlowHarness.payment(), FlowHarness.payment(), FlowHarness.read("IN_PROGRESS", "WAIT_FOR_PROVIDER")]
        let outcome = try await h.flow.run()
        XCTAssertEqual(outcome, .pending)
        XCTAssertEqual(h.driver.calls, ["hasAccount", "register", "authorize", "confirmIdentity", "registerWallet", "collectPayment", "createPaymentToken", "checkout"])
        XCTAssertEqual(h.forms.calls, ["email", "registration"])
        XCTAssertEqual(h.forms.handOffs, 4, "every provider screen first clears the forms")
        XCTAssertTrue(h.store.value.submissionStarted)
        XCTAssertEqual(h.driver.collectedRequest?.merchantIdentifier, "merchant.example.stripe")
        XCTAssertEqual(h.driver.collectedRequest?.currencyCode, "USD")
        XCTAssertEqual(h.driver.collectedRequest?.paymentSummaryItems.last?.amount, NSDecimalNumber(value: 20))
        XCTAssertEqual(h.client.calls.map(\.operation), ["READ_SUBMISSION", "PREPARE_CUSTOMER_AUTHORIZATION", "COMPLETE_CUSTOMER_LINK", "READ_CUSTOMER_STATUS", "READ_LIMITS", "CREATE_PAYMENT_SESSION", "CONFIRM_PAYMENT", "READ_SUBMISSION"])
        await h.flow.close()
        XCTAssertEqual(h.driver.logouts, 1)
    }

    func testServerEmailReplacesTheEmailFormForLookupAndRegistration() async throws {
        let h = try FlowHarness(registration: true)
        h.driver.hasAccountResult = false
        h.client.responses = [FlowHarness.bootstrap(prefill: ["email": "buyer@example.test"])] + Array(FlowHarness.bootstrap.dropFirst()) +
            [FlowHarness.customer(), FlowHarness.payment(), FlowHarness.payment(), FlowHarness.read("SUBMITTED", "WAIT_FOR_PAYMENT")]
        let outcome = try await h.flow.run()
        XCTAssertEqual(outcome, .submitted)
        XCTAssertEqual(h.forms.calls, ["registration"])
        XCTAssertEqual(h.driver.emails, ["buyer@example.test", "buyer@example.test"])
        await h.flow.close()
    }

    func testVerifiedPhoneRegistersLinkWithoutAnyForm() async throws {
        let h = try FlowHarness(registration: true)
        h.driver.hasAccountResult = false
        h.client.responses = [FlowHarness.bootstrap(prefill: ["email": "buyer@example.test", "phone": "+14155550123", "fullName": "Ada Lovelace"])] +
            Array(FlowHarness.bootstrap.dropFirst()) +
            [FlowHarness.customer(), FlowHarness.payment(), FlowHarness.payment(), FlowHarness.read("SUBMITTED", "WAIT_FOR_PAYMENT")]
        let outcome = try await h.flow.run()
        XCTAssertEqual(outcome, .submitted)
        XCTAssertTrue(h.forms.calls.isEmpty)
        XCTAssertEqual(h.driver.registrations, ["Ada Lovelace +14155550123"])
        await h.flow.close()
    }

    func testARefusedPrefilledPhoneFallsBackToTheRegistrationForm() async throws {
        let h = try FlowHarness(registration: true)
        h.driver.hasAccountResult = false
        h.driver.failRegistrations = 1
        h.client.responses = [FlowHarness.bootstrap(prefill: ["email": "buyer@example.test", "phone": "+14155550123"])] +
            Array(FlowHarness.bootstrap.dropFirst()) +
            [FlowHarness.customer(), FlowHarness.payment(), FlowHarness.payment(), FlowHarness.read("SUBMITTED", "WAIT_FOR_PAYMENT")]
        let outcome = try await h.flow.run()
        XCTAssertEqual(outcome, .submitted)
        XCTAssertEqual(h.forms.calls, ["registration"])
        XCTAssertEqual(h.driver.registrations, ["- +14155550123", "- +12025550123"])
        await h.flow.close()
    }

    func testAnUnusablePrefillFallsBackToEveryForm() async throws {
        let h = try FlowHarness(registration: true)
        h.driver.hasAccountResult = false
        h.client.responses = [FlowHarness.bootstrap(prefill: ["email": "not-an-email", "phone": "+14155550123"])] +
            Array(FlowHarness.bootstrap.dropFirst()) +
            [FlowHarness.customer(), FlowHarness.payment(), FlowHarness.payment(), FlowHarness.read("SUBMITTED", "WAIT_FOR_PAYMENT")]
        let outcome = try await h.flow.run()
        XCTAssertEqual(outcome, .submitted)
        XCTAssertEqual(h.forms.calls, ["email", "registration"])
        await h.flow.close()
    }

    func testSumsubIdentityIsSubmittedAndOnlyTheIdNumberIsAsked() async throws {
        let h = try FlowHarness()
        h.client.responses = [FlowHarness.bootstrap(prefill: FlowHarness.sumsubPrefill)] + Array(FlowHarness.bootstrap.dropFirst()) +
            [FlowHarness.customer("NOT_STARTED", next: "SDK_COLLECT_KYC", missing: FlowHarness.allIdentityFields),
             FlowHarness.customer(), FlowHarness.payment(), FlowHarness.payment(), FlowHarness.read("SUBMITTED", "WAIT_FOR_PAYMENT")]
        let outcome = try await h.flow.run()
        XCTAssertEqual(outcome, .submitted)
        XCTAssertEqual(h.forms.identityRequests, [["ID_NUMBER"]])
        let attached = try XCTUnwrap(h.driver.attached.first)
        XCTAssertEqual(attached.firstName, "Ada"); XCTAssertEqual(attached.lastName, "Lovelace")
        XCTAssertEqual(attached.birthYear, 1990); XCTAssertEqual(attached.birthMonth, 3); XCTAssertEqual(attached.birthDay, 15)
        XCTAssertEqual(attached.address?.line1, "1 Market St")
        XCTAssertEqual(attached.idNumber, "000000000")
        await h.flow.close()
    }

    func testFullyCoveredIdentityIsSubmittedWithoutAForm() async throws {
        let h = try FlowHarness()
        h.client.responses = [FlowHarness.bootstrap(prefill: FlowHarness.sumsubPrefill)] + Array(FlowHarness.bootstrap.dropFirst()) +
            [FlowHarness.customer("NOT_STARTED", next: "SDK_COLLECT_KYC", missing: ["FIRST_NAME", "DATE_OF_BIRTH", "ADDRESS_CITY"]),
             FlowHarness.customer(), FlowHarness.payment(), FlowHarness.payment(), FlowHarness.read("SUBMITTED", "WAIT_FOR_PAYMENT")]
        _ = try await h.flow.run()
        XCTAssertTrue(h.forms.identityRequests.isEmpty)
        let attached = try XCTUnwrap(h.driver.attached.first)
        XCTAssertEqual(attached.firstName, "Ada"); XCTAssertNil(attached.lastName)
        XCTAssertEqual(attached.birthYear, 1990); XCTAssertNotNil(attached.address)
        await h.flow.close()
    }

    func testRejectedPrefilledIdentityFallsBackToTheFullForm() async throws {
        let h = try FlowHarness()
        let missing = FlowHarness.allIdentityFields
        h.client.responses = [FlowHarness.bootstrap(prefill: FlowHarness.sumsubPrefill)] + Array(FlowHarness.bootstrap.dropFirst()) +
            [FlowHarness.customer("NOT_STARTED", next: "SDK_COLLECT_KYC", missing: missing),
             FlowHarness.customer("REJECTED", next: "SDK_COLLECT_KYC", missing: missing),
             FlowHarness.customer(), FlowHarness.payment(), FlowHarness.payment(), FlowHarness.read("SUBMITTED", "WAIT_FOR_PAYMENT")]
        _ = try await h.flow.run()
        XCTAssertEqual(h.forms.identityRequests, [["ID_NUMBER"], []], "after a rejection the customer sees every field")
        XCTAssertEqual(h.driver.attached.count, 2)
        XCTAssertNil(h.driver.attached.last?.firstName)
        await h.flow.close()
    }

    func testRegistrationNextStepRecoversAccountCheckDisagreementOnSameOrder() async throws {
        let h = try FlowHarness(registration: true)
        h.client.responses = [FlowHarness.bootstrap[0], FlowHarness.read("NOT_STARTED", "SDK_REGISTER_CUSTOMER")] +
            Array(FlowHarness.bootstrap.dropFirst()) + [FlowHarness.customer(), FlowHarness.payment(), FlowHarness.payment(), FlowHarness.read("SUBMITTED", "WAIT_FOR_PAYMENT")]
        let outcome = try await h.flow.run()
        XCTAssertEqual(outcome, .submitted)
        XCTAssertEqual(Array(h.driver.calls.prefix(3)), ["hasAccount", "register", "authorize"])
        let preparation = h.client.calls.filter { $0.operation == "PREPARE_CUSTOMER_AUTHORIZATION" }
        XCTAssertEqual(preparation.count, 2)
        XCTAssertNotEqual(preparation[0].key, preparation[1].key)
        XCTAssertEqual(h.driver.calls.filter { $0 == "register" }.count, 1)
        await h.flow.close()
    }

    func testRepeatedRegistrationRequirementNeverRepeatsRegistrationOrStartsPayment() async throws {
        for hasAccount in [false, true] {
            let h = try FlowHarness(registration: true)
            h.driver.hasAccountResult = hasAccount
            h.client.responses = [FlowHarness.bootstrap[0], FlowHarness.read("NOT_STARTED", "SDK_REGISTER_CUSTOMER")]
            if hasAccount { h.client.responses.append(FlowHarness.read("NOT_STARTED", "SDK_REGISTER_CUSTOMER")) }
            do { _ = try await h.flow.run(); XCTFail("Repeated registration must stop") } catch {}
            XCTAssertEqual(h.driver.calls, ["hasAccount", "register"])
            XCTAssertFalse(h.store.value.submissionStarted)
            XCTAssertFalse(h.client.calls.contains { $0.operation == "CREATE_PAYMENT_SESSION" })
            await h.flow.close()
        }
    }

    func testRegistrationInstructionCannotRestartExistingFinancialSession() async throws {
        let h = try FlowHarness(registration: true)
        h.driver.failAuthentication = true
        h.client.responses = [FlowHarness.resume(), FlowHarness.authToken,
                              FlowHarness.read("NOT_STARTED", "SDK_REGISTER_CUSTOMER")]
        do { _ = try await h.flow.run(); XCTFail("Existing session cannot restart registration") } catch {}
        XCTAssertEqual(h.driver.calls, ["authenticate", "hasAccount"])
        XCTAssertFalse(h.client.calls.contains { $0.operation == "CREATE_PAYMENT_SESSION" })
        await h.flow.close()
    }

    func testResumeRestoresAuthenticationAndUsesOnlyTheExistingSession() async throws {
        let h = try FlowHarness()
        h.client.limits = [FlowHarness.limits("SDK_COLLECT_KYC")]
        h.client.responses = [FlowHarness.resume(), FlowHarness.authToken, FlowHarness.customer(next: "REFRESH_QUOTE"),
                              FlowHarness.payment(), FlowHarness.payment(), FlowHarness.read("SUBMITTED", "WAIT_FOR_PAYMENT")]
        let outcome = try await h.flow.run()
        XCTAssertEqual(outcome, .submitted)
        XCTAssertEqual(h.driver.calls, ["authenticate", "checkout"])
        XCTAssertFalse(h.client.calls.contains { $0.operation == "CREATE_PAYMENT_SESSION" || $0.operation == "READ_LIMITS" })
        XCTAssertTrue(h.store.value.submissionStarted)
        XCTAssertTrue(h.forms.calls.isEmpty)
        await h.flow.close()
    }

    func testSeamlessFailureFallsBackToOrderBoundInteractiveConsent() async throws {
        let h = try FlowHarness()
        h.driver.failAuthentication = true
        h.client.responses = [FlowHarness.resume(), FlowHarness.authToken] + Array(FlowHarness.bootstrap.dropFirst()) +
            [FlowHarness.customer(next: "REFRESH_QUOTE"), FlowHarness.payment(), FlowHarness.payment(), FlowHarness.read("SUCCEEDED", "COMPLETE")]
        let outcome = try await h.flow.run()
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(h.driver.calls, ["authenticate", "hasAccount", "authorize", "checkout"])
        XCTAssertFalse(h.client.calls.contains { $0.fields["email"] != nil || $0.fields["sessionHandle"] != nil })
        await h.flow.close()
    }

    func testKycCollectionDocumentVerificationAndAddressConfirmationPrecedePayment() async throws {
        let h = try FlowHarness()
        h.driver.updateAddress = true
        h.client.responses = FlowHarness.bootstrap + [FlowHarness.customer("NOT_STARTED", next: "SDK_COLLECT_KYC"),
            FlowHarness.customer("PENDING", next: "RETRY"), FlowHarness.customer("REJECTED", next: "SDK_VERIFY_IDENTITY"),
            FlowHarness.customer(), FlowHarness.payment(), FlowHarness.payment(), FlowHarness.read("SUBMITTED", "WAIT_FOR_PAYMENT")]
        let outcome = try await h.flow.run()
        XCTAssertEqual(outcome, .submitted)
        XCTAssertEqual(h.forms.calls, ["email", "identity", "address"])
        XCTAssertEqual(h.driver.calls.filter { ["attachIdentity", "verifyIdentity", "confirmIdentity"].contains($0) },
                       ["attachIdentity", "verifyIdentity", "confirmIdentity", "confirmIdentity"])
        await h.flow.close()
    }

    func testOnlyACustomerWithKycDataOnFileIsAskedToConfirmIt() async throws {
        for (tier, confirms): (String?, Bool) in [("L0", false), ("NONE", false), ("L1", true), ("L2", true), (nil, true)] {
            let h = try FlowHarness()
            h.client.responses = FlowHarness.bootstrap + [FlowHarness.customer(tier: tier), FlowHarness.payment(), FlowHarness.payment(),
                                                          FlowHarness.read("SUBMITTED", "WAIT_FOR_PAYMENT")]
            let outcome = try await h.flow.run()
            XCTAssertEqual(outcome, .submitted, tier ?? "absent")
            XCTAssertEqual(h.driver.calls, ["hasAccount", "authorize"] + (confirms ? ["confirmIdentity"] : []) +
                           ["registerWallet", "collectPayment", "createPaymentToken", "checkout"], tier ?? "absent")
            XCTAssertTrue(h.driver.attached.isEmpty, tier ?? "absent")
            await h.flow.close()
        }
    }

    func testAnOrderOverAnL0CustomersLimitsAddsOnlyTheirDateOfBirthAndTypedIdNumber() async throws {
        let h = try FlowHarness()
        h.client.responses = [FlowHarness.bootstrap(prefill: FlowHarness.sumsubPrefill)] + Array(FlowHarness.bootstrap.dropFirst()) +
            [FlowHarness.customer(tier: "L0"), FlowHarness.customer(), FlowHarness.payment(), FlowHarness.payment(),
             FlowHarness.read("SUBMITTED", "WAIT_FOR_PAYMENT")]
        h.client.limits = [FlowHarness.limits("SDK_COLLECT_KYC")]
        let outcome = try await h.flow.run()
        XCTAssertEqual(outcome, .submitted)
        XCTAssertEqual(h.forms.identityRequests, [["ID_NUMBER"]])
        XCTAssertEqual(h.driver.attached.count, 1)
        let attached = try XCTUnwrap(h.driver.attached.first)
        XCTAssertEqual(attached.birthYear, 1990); XCTAssertEqual(attached.birthMonth, 3); XCTAssertEqual(attached.birthDay, 15)
        XCTAssertEqual(attached.idNumber, "000000000")
        XCTAssertNil(attached.firstName); XCTAssertNil(attached.lastName); XCTAssertNil(attached.address)
        XCTAssertEqual(h.driver.calls, ["hasAccount", "authorize", "attachIdentity", "registerWallet", "collectPayment", "createPaymentToken", "checkout"])
        XCTAssertEqual(h.client.calls.map(\.operation), ["READ_SUBMISSION", "PREPARE_CUSTOMER_AUTHORIZATION", "COMPLETE_CUSTOMER_LINK",
            "READ_CUSTOMER_STATUS", "READ_LIMITS", "READ_CUSTOMER_STATUS", "READ_LIMITS", "CREATE_PAYMENT_SESSION", "CONFIRM_PAYMENT", "READ_SUBMISSION"])
        XCTAssertTrue(h.client.calls.filter { $0.operation == "READ_LIMITS" }.allSatisfy { $0.key == nil && $0.fields.isEmpty })
        await h.flow.close()
    }

    func testStepUpWithoutL0DataAsksForEveryL1FieldAndSendsEachPrefilledValueOnce() async throws {
        let unverified = try FlowHarness()
        unverified.client.responses = [FlowHarness.bootstrap(prefill: FlowHarness.sumsubPrefill)] + Array(FlowHarness.bootstrap.dropFirst()) +
            [FlowHarness.customer(tier: "NONE"), FlowHarness.customer(), FlowHarness.payment(), FlowHarness.payment(),
             FlowHarness.read("SUBMITTED", "WAIT_FOR_PAYMENT")]
        unverified.client.limits = [FlowHarness.limits("SDK_COLLECT_KYC")]
        _ = try await unverified.flow.run()
        XCTAssertEqual(unverified.forms.identityRequests, [["ID_NUMBER"]])
        XCTAssertEqual(unverified.driver.attached.first?.firstName, "Ada")
        XCTAssertNotNil(unverified.driver.attached.first?.address)
        await unverified.flow.close()
        let prefilled = try FlowHarness()
        prefilled.client.responses = [FlowHarness.bootstrap(prefill: FlowHarness.sumsubPrefill)] + Array(FlowHarness.bootstrap.dropFirst()) +
            [FlowHarness.customer("NOT_STARTED", next: "SDK_COLLECT_KYC", missing: ["FIRST_NAME", "LAST_NAME", "ADDRESS_LINE_1"]),
             FlowHarness.customer(tier: "L0"), FlowHarness.customer(), FlowHarness.payment(), FlowHarness.payment(),
             FlowHarness.read("SUBMITTED", "WAIT_FOR_PAYMENT")]
        prefilled.client.limits = [FlowHarness.limits("SDK_COLLECT_KYC")]
        _ = try await prefilled.flow.run()
        XCTAssertEqual(prefilled.forms.identityRequests, [["ID_NUMBER"]])
        XCTAssertEqual(prefilled.driver.attached.count, 2)
        XCTAssertEqual(prefilled.driver.attached.first?.firstName, "Ada")
        XCTAssertNil(prefilled.driver.attached.first?.birthYear)
        let stepUp = try XCTUnwrap(prefilled.driver.attached.last)
        XCTAssertEqual(stepUp.birthYear, 1990); XCTAssertEqual(stepUp.birthMonth, 3); XCTAssertEqual(stepUp.birthDay, 15)
        XCTAssertEqual(stepUp.idNumber, "000000000")
        XCTAssertNil(stepUp.firstName); XCTAssertNil(stepUp.lastName); XCTAssertNil(stepUp.address)
        await prefilled.flow.close()
    }

    func testARejectedStepUpAsksForEveryFieldAndNeverResendsThePrefilledDateOfBirth() async throws {
        let h = try FlowHarness()
        h.client.responses = [FlowHarness.bootstrap(prefill: FlowHarness.sumsubPrefill)] + Array(FlowHarness.bootstrap.dropFirst()) +
            [FlowHarness.customer(tier: "L0"), FlowHarness.customer("REJECTED", next: "SDK_COLLECT_KYC", missing: ["DATE_OF_BIRTH", "ID_NUMBER"]),
             FlowHarness.customer(), FlowHarness.payment(), FlowHarness.payment(), FlowHarness.read("SUBMITTED", "WAIT_FOR_PAYMENT")]
        h.client.limits = [FlowHarness.limits("SDK_COLLECT_KYC")]
        let outcome = try await h.flow.run()
        XCTAssertEqual(outcome, .submitted)
        XCTAssertEqual(h.forms.identityRequests, [["ID_NUMBER"], []])
        XCTAssertEqual(h.driver.attached.count, 2)
        XCTAssertEqual(h.driver.attached.first?.birthYear, 1990)
        XCTAssertNil(h.driver.attached.last?.birthYear)
        await h.flow.close()
    }

    func testStepUpsThatKeepAdvancingTheTierStopAfterThreeLimitReads() async throws {
        let h = try FlowHarness()
        h.client.responses = FlowHarness.bootstrap + [FlowHarness.customer(tier: "NONE"), FlowHarness.customer(tier: "L0"),
            FlowHarness.customer(tier: "L1"), FlowHarness.customer(tier: "L2"), FlowHarness.payment(), FlowHarness.payment(),
            FlowHarness.read("SUBMITTED", "WAIT_FOR_PAYMENT")]
        h.client.limits = [FlowHarness.limits("SDK_COLLECT_KYC"), FlowHarness.limits("SDK_COLLECT_KYC"),
                           FlowHarness.limits("SDK_VERIFY_IDENTITY"), FlowHarness.limits("SDK_VERIFY_IDENTITY")]
        let outcome = try await h.flow.run()
        XCTAssertEqual(outcome, .submitted)
        XCTAssertEqual(h.client.calls.filter { $0.operation == "READ_LIMITS" }.count, 3)
        XCTAssertEqual(h.client.limits.count, 1)
        XCTAssertEqual(h.forms.identityRequests, [[], ["DATE_OF_BIRTH", "ID_NUMBER"]])
        XCTAssertEqual(h.driver.calls, ["hasAccount", "authorize", "attachIdentity", "attachIdentity", "verifyIdentity", "registerWallet",
                                        "collectPayment", "createPaymentToken", "checkout"])
        await h.flow.close()
    }

    func testARepeatedStepUpThatDidNotAdvanceTheTierProceedsToPaymentWithoutAskingAgain() async throws {
        for (tier, step, prompt) in [("L0", "SDK_COLLECT_KYC", "attachIdentity"), ("L1", "SDK_VERIFY_IDENTITY", "verifyIdentity")] {
            let h = try FlowHarness()
            h.client.responses = FlowHarness.bootstrap + [FlowHarness.customer(tier: tier), FlowHarness.customer(tier: tier),
                FlowHarness.payment(), FlowHarness.payment(), FlowHarness.read("SUBMITTED", "WAIT_FOR_PAYMENT")]
            h.client.limits = Array(repeating: FlowHarness.limits(step), count: 3)
            let outcome = try await h.flow.run()
            XCTAssertEqual(outcome, .submitted, tier)
            XCTAssertEqual(h.client.calls.filter { $0.operation == "READ_LIMITS" }.count, 2, tier)
            XCTAssertEqual(h.forms.identityRequests, tier == "L0" ? [["DATE_OF_BIRTH", "ID_NUMBER"]] : [], tier)
            XCTAssertEqual(h.driver.calls.filter { ["attachIdentity", "verifyIdentity"].contains($0) }, [prompt], tier)
            XCTAssertEqual(h.client.calls.filter { $0.operation == "CREATE_PAYMENT_SESSION" }.count, 1, tier)
            await h.flow.close()
        }
    }

    func testAnOrderOverAnL1CustomersLimitsVerifiesTheirIdentityBeforePaying() async throws {
        let h = try FlowHarness()
        h.client.responses = FlowHarness.bootstrap + [FlowHarness.customer(), FlowHarness.customer(tier: "L2"), FlowHarness.payment(),
                                                      FlowHarness.payment(), FlowHarness.read("SUBMITTED", "WAIT_FOR_PAYMENT")]
        h.client.limits = [FlowHarness.limits("SDK_VERIFY_IDENTITY")]
        let outcome = try await h.flow.run()
        XCTAssertEqual(outcome, .submitted)
        XCTAssertEqual(h.driver.calls, ["hasAccount", "authorize", "confirmIdentity", "verifyIdentity", "registerWallet", "collectPayment",
                                        "createPaymentToken", "checkout"])
        XCTAssertEqual(h.forms.handOffs, 5)
        XCTAssertTrue(h.forms.identityRequests.isEmpty)
        XCTAssertEqual(h.client.calls.filter { $0.operation == "READ_LIMITS" }.count, 2)
        await h.flow.close()
    }

    func testPendingVerificationAfterAStepUpStopsBeforeCollectingOrClaimingPayment() async throws {
        let h = try FlowHarness()
        h.client.responses = FlowHarness.bootstrap + [FlowHarness.customer(tier: "L0")] +
            Array(repeating: FlowHarness.customer("PENDING", next: "RETRY"), count: 12)
        h.client.limits = [FlowHarness.limits("SDK_COLLECT_KYC")]
        let outcome = try await h.flow.run()
        XCTAssertEqual(outcome, .verificationPending)
        XCTAssertEqual(h.forms.identityRequests, [["DATE_OF_BIRTH", "ID_NUMBER"]])
        XCTAssertFalse(h.store.value.submissionStarted)
        XCTAssertFalse(h.driver.calls.contains("registerWallet"))
        XCTAssertFalse(h.client.calls.contains { $0.operation == "CREATE_PAYMENT_SESSION" })
        await h.flow.close()
    }

    func testLimitsThatCannotBeReadNeverBlockThePurchase() async throws {
        let failures: [(String, [Result<[String: Any], Error>])] = [
            ("transport", [.failure(PaymentActionError.transport), .failure(PaymentActionError.transport)]),
            ("server", [.failure(PaymentActionError.action(.providerUnavailable))]),
            ("malformed", [.success(["version": 1, "status": "READY"])])]
        for tier in ["L0", "L1"] {
            for (failure, limits) in failures {
                let name = "\(tier) \(failure)"
                let h = try FlowHarness()
                h.client.responses = FlowHarness.bootstrap + [FlowHarness.customer(tier: tier), FlowHarness.payment(), FlowHarness.payment(),
                                                              FlowHarness.read("SUBMITTED", "WAIT_FOR_PAYMENT")]
                h.client.limits = limits
                let outcome = try await h.flow.run()
                XCTAssertEqual(outcome, .submitted, name)
                XCTAssertTrue(h.client.limits.isEmpty, name)
                XCTAssertEqual(h.driver.calls, ["hasAccount", "authorize"] + (tier == "L1" ? ["confirmIdentity"] : []) +
                               ["registerWallet", "collectPayment", "createPaymentToken", "checkout"], name)
                XCTAssertEqual(h.client.calls.filter { $0.operation == "CREATE_PAYMENT_SESSION" }.count, 1, name)
                await h.flow.close()
            }
        }
    }

    func testAnIdentityChallengeAtL0CollectsL1ThenRunsTheIdCheckWithoutPaying() async throws {
        let h = try FlowHarness()
        h.client.responses = [FlowHarness.bootstrap(prefill: FlowHarness.sumsubPrefill)] + Array(FlowHarness.bootstrap.dropFirst()) +
            [FlowHarness.customer(tier: "L0"), FlowHarness.read("REJECTED", "SDK_VERIFY_IDENTITY"), FlowHarness.customer(tier: "L1")]
        let outcome = try await h.flow.run()
        XCTAssertEqual(outcome, .verificationRequired)
        XCTAssertFalse(h.flow.mayHaveFinancialAttempt)
        XCTAssertEqual(h.forms.identityRequests, [["ID_NUMBER"]])
        let attached = try XCTUnwrap(h.driver.attached.first)
        XCTAssertEqual(attached.birthYear, 1990); XCTAssertEqual(attached.idNumber, "000000000")
        XCTAssertEqual(h.driver.calls, ["hasAccount", "authorize", "registerWallet", "collectPayment", "createPaymentToken",
                                        "attachIdentity", "verifyIdentity"])
        XCTAssertEqual(h.client.calls.map(\.operation), ["READ_SUBMISSION", "PREPARE_CUSTOMER_AUTHORIZATION", "COMPLETE_CUSTOMER_LINK",
            "READ_CUSTOMER_STATUS", "READ_LIMITS", "CREATE_PAYMENT_SESSION", "READ_CUSTOMER_STATUS"])
        await h.flow.close()
    }

    func testAnIdentityChallengeAtL1RunsOnlyTheIdCheck() async throws {
        let h = try FlowHarness()
        h.client.responses = FlowHarness.bootstrap + [FlowHarness.customer(), FlowHarness.read("REJECTED", "SDK_VERIFY_IDENTITY")]
        let outcome = try await h.flow.run()
        XCTAssertEqual(outcome, .verificationRequired)
        XCTAssertFalse(h.flow.mayHaveFinancialAttempt)
        XCTAssertTrue(h.driver.attached.isEmpty)
        XCTAssertEqual(h.driver.calls.suffix(2), ["createPaymentToken", "verifyIdentity"])
        await h.flow.close()
    }

    func testAKycRefusalAtSessionCreateCollectsL1WithoutTheIdCheck() async throws {
        let h = try FlowHarness()
        h.client.responses = [FlowHarness.bootstrap(prefill: FlowHarness.sumsubPrefill)] + Array(FlowHarness.bootstrap.dropFirst()) +
            [FlowHarness.customer(tier: "L0"), FlowHarness.read("REJECTED", "SDK_COLLECT_KYC"), FlowHarness.customer(tier: "L1")]
        let outcome = try await h.flow.run()
        XCTAssertEqual(outcome, .verificationRequired)
        XCTAssertEqual(h.forms.identityRequests, [["ID_NUMBER"]])
        XCTAssertFalse(h.driver.calls.contains("verifyIdentity"))
        XCTAssertEqual(h.driver.calls.last, "attachIdentity")
        await h.flow.close()
    }

    func testPendingVerificationStopsBeforeCollectingOrClaimingPayment() async throws {
        let h = try FlowHarness()
        h.client.responses = FlowHarness.bootstrap + Array(repeating: FlowHarness.customer("PENDING", next: "RETRY"), count: 12)
        let outcome = try await h.flow.run()
        XCTAssertEqual(outcome, .verificationPending)
        XCTAssertFalse(h.flow.mayHaveFinancialAttempt)
        XCTAssertFalse(h.store.value.submissionStarted)
        XCTAssertFalse(h.driver.calls.contains("collectPayment"))
        await h.flow.close()
    }

    func testSubmissionReadPreventsNativeWorkForExistingFinancialOutcomes() async throws {
        for (status, next, expected): (String, String, StripeFlowController.Outcome) in [
            ("SUCCEEDED", "COMPLETE", .completed), ("SUBMITTED", "WAIT_FOR_PAYMENT", .submitted),
            ("IN_PROGRESS", "WAIT_FOR_PROVIDER", .pending), ("UNKNOWN", "WAIT_FOR_PROVIDER", .pending),
            ("FAILED", "NONE", .rejected), ("REJECTED", "NONE", .rejected), ("EXPIRED", "NONE", .expired)] {
            let h = try FlowHarness()
            h.client.responses = [FlowHarness.read(status, next)]
            let result = try await h.flow.run()
            XCTAssertEqual(result, expected)
            XCTAssertEqual(h.factory.value, 0)
            XCTAssertTrue(h.driver.calls.isEmpty)
            await h.flow.close()
        }
    }

    func testDefiniteDeclineOrExpiryAfterCheckoutIsARejectionNotAnUnknownOutcome() async throws {
        for (status, expected): (String, StripeFlowController.Outcome) in [
            ("FAILED", .rejected), ("REJECTED", .rejected), ("EXPIRED", .expired)] {
            let h = try FlowHarness()
            h.client.responses = FlowHarness.bootstrap + [FlowHarness.customer(), FlowHarness.payment(), FlowHarness.payment(),
                                                          FlowHarness.read(status, "NONE")]
            let outcome = try await h.flow.run()
            XCTAssertEqual(outcome, expected, status)
            XCTAssertTrue(h.flow.mayHaveFinancialAttempt)
            await h.flow.close()
        }
    }

    func testRefusedSessionCreateIsARejectionButEveryOtherFailureAfterTheClaimStaysUnknown() async throws {
        let refused: [([Result<[String: Any], Error>], StripeFlowController.Refusal)] = [
            ([.failure(PaymentActionError.action(.providerRejected))], .providerRejected),
            ([FlowHarness.read("FAILED", "START_NEW_ORDER")], .startNewOrder),
            ([.failure(PaymentActionError.transport), FlowHarness.read("FAILED", "START_NEW_ORDER")], .startNewOrder)]
        for (responses, refusal) in refused {
            let h = try FlowHarness()
            h.client.responses = FlowHarness.bootstrap + [FlowHarness.customer()] + responses
            let outcome = try await h.flow.run()
            XCTAssertEqual(outcome, .refused(refusal))
            XCTAssertTrue(h.store.value.submissionStarted)
            XCTAssertFalse(h.driver.calls.contains("checkout"))
            XCTAssertEqual(h.client.calls.last?.operation, "CREATE_PAYMENT_SESSION")
            await h.flow.close()
        }
        let unknown: [(String, [Result<[String: Any], Error>])] = [
            ("create transport", [.failure(PaymentActionError.transport), .failure(PaymentActionError.transport)]),
            ("create refused on the transport retry", [.failure(PaymentActionError.transport),
                                                      .failure(PaymentActionError.action(.providerRejected))]),
            ("create invalid provider response", [.failure(PaymentActionError.action(.invalidProviderResponse))]),
            ("create outcome unknown", [.failure(PaymentActionError.action(.outcomeUnknown))]),
            ("create failed without new order", [FlowHarness.read("FAILED", "NONE")]),
            ("create without session", [FlowHarness.read("REQUIRES_PAYMENT", "CONFIRM_PAYMENT")]),
            ("checkout refused", [FlowHarness.payment(), .failure(PaymentActionError.action(.providerRejected))]),
            ("refresh refused", [FlowHarness.payment("REQUIRES_PAYMENT", next: "REFRESH_QUOTE", secret: false),
                                 .failure(PaymentActionError.action(.providerRejected))])]
        for (name, responses) in unknown {
            let h = try FlowHarness()
            h.client.responses = FlowHarness.bootstrap + [FlowHarness.customer()] + responses
            do { _ = try await h.flow.run(); XCTFail("\(name): expected a failure") } catch {
                XCTAssertEqual(StripePaymentSession.failure(error, mayHaveFinancialAttempt: h.flow.mayHaveFinancialAttempt,
                                                            orderId: "synthetic-order").code, "PAYMENT_OUTCOME_UNKNOWN", name)
            }
            await h.flow.close()
        }
    }

    func testA422ProviderRejectedBodyIsARejectionOnlyWhenItAnswersTheFirstCreateAttempt() async throws {
        let rejected = FlowWire.Reply.http(422, ["version": 1, "code": "PROVIDER_REJECTED"])
        for (create, code, detail) in [([rejected], "PAYMENT_REJECTED", "create:PROVIDER_REJECTED"),
                                       ([FlowWire.Reply.lost, rejected], "PAYMENT_OUTCOME_UNKNOWN", "action:PROVIDER_REJECTED")] {
            let wire = URLSessionConfiguration.ephemeral
            wire.protocolClasses = [FlowWire.self]
            let h = try FlowHarness(wire: wire)
            FlowWire.sent = []
            FlowWire.replies = try (FlowHarness.bootstrap + [FlowHarness.customer(), FlowHarness.limits()]).map { FlowWire.Reply.http(200, try $0.get()) } + create
            let reported: MeldError?
            do {
                reported = StripePaymentSession.events(for: try await h.flow.run(), mayHaveFinancialAttempt: h.flow.mayHaveFinancialAttempt,
                                                    orderId: "synthetic-order").compactMap { if case let .error(e) = $0 { return e }; return nil }.first
            } catch {
                reported = StripePaymentSession.failure(error, mayHaveFinancialAttempt: h.flow.mayHaveFinancialAttempt, orderId: "synthetic-order")
            }
            XCTAssertEqual(reported?.code, code)
            XCTAssertEqual(reported?.detail, detail)
            XCTAssertEqual(FlowWire.sent.filter { $0.operation == "READ_LIMITS" }.map(\.key), [nil])
            let creates = FlowWire.sent.filter { $0.operation == "CREATE_PAYMENT_SESSION" }
            XCTAssertEqual(creates.count, create.count)
            XCTAssertEqual(creates.map(\.key), Array(repeating: h.store.value.submissionKey.uuidString.lowercased(), count: create.count))
            XCTAssertEqual(FlowWire.sent.last?.operation, "CREATE_PAYMENT_SESSION")
            XCTAssertTrue(FlowWire.replies.isEmpty)
            XCTAssertFalse(h.driver.calls.contains("checkout"))
            await h.flow.close()
        }
    }

    func testFailureBeforeTheFirstReadMayHaveAPaymentOnlyWhenThisDeviceClaimedOneOrCannotTell() async throws {
        for (claimed, unreadable, expected) in [(false, false, false), (true, false, true), (false, true, true)] {
            let h = try FlowHarness()
            h.store.value.submissionStarted = claimed
            h.store.unreadable = unreadable
            h.client.responses = [.failure(PaymentActionError.transport), .failure(PaymentActionError.transport)]
            do { _ = try await h.flow.run(); XCTFail("Expected an unavailable read") } catch PaymentActionError.transport { }
            XCTAssertEqual(h.flow.mayHaveFinancialAttempt, expected, "claimed: \(claimed), unreadable: \(unreadable)")
            XCTAssertEqual(h.factory.value, 0)
            await h.flow.close()
        }
    }

    func testServerReportedSessionOrSubmissionMayHaveAPaymentWhenTheFenceCannotBeWritten() async throws {
        for (name, response) in [("IN_PROGRESS", FlowHarness.read("IN_PROGRESS", "WAIT_FOR_PROVIDER")),
                                 ("UNKNOWN", FlowHarness.read("UNKNOWN", "WAIT_FOR_PROVIDER")),
                                 ("SUBMITTED", FlowHarness.read("SUBMITTED", "WAIT_FOR_PAYMENT")),
                                 ("SUCCEEDED", FlowHarness.read("SUCCEEDED", "COMPLETE")),
                                 ("FAILED", FlowHarness.read("FAILED", "NONE")), ("EXPIRED", FlowHarness.read("EXPIRED", "NONE")),
                                 ("RESUME", FlowHarness.resume())] {
            let h = try FlowHarness()
            h.store.unwritable = true
            h.client.responses = [response]
            do { _ = try await h.flow.run(); XCTFail("\(name): expected the fence write to fail") }
            catch PaymentActionError.storage { }
            XCTAssertFalse(h.store.value.submissionStarted, name)
            XCTAssertTrue(h.flow.mayHaveFinancialAttempt, name)
            XCTAssertEqual(h.factory.value, 0, name)
            await h.flow.close()
        }
    }

    func testDeviceFenceAndUnavailableReadCannotOpenPaymentUi() async throws {
        let h = try FlowHarness()
        h.store.value.submissionStarted = true
        h.client.responses = [FlowHarness.bootstrap[0]]
        do { _ = try await h.flow.run(); XCTFail("Expected device fence") }
        catch PaymentActionError.alreadyAttempted { }
        XCTAssertEqual(h.factory.value, 0)
        await h.flow.close()
        let malformed = try FlowHarness()
        malformed.client.responses = [.success(["version": 1, "status": "NOT_STARTED", "nextStep": "NONE"])]
        do { _ = try await malformed.flow.run(); XCTFail("Expected malformed read rejection") } catch { }
        XCTAssertEqual(malformed.factory.value, 0)
        await malformed.flow.close()
    }

    func testLostCreateResponseRetriesTheSameTokenAndMutationKey() async throws {
        let h = try FlowHarness()
        h.client.responses = FlowHarness.bootstrap + [FlowHarness.customer(), .failure(PaymentActionError.transport),
            FlowHarness.payment(), FlowHarness.payment(), FlowHarness.read("SUBMITTED", "WAIT_FOR_PAYMENT")]
        _ = try await h.flow.run()
        let creates = h.client.calls.filter { $0.operation == "CREATE_PAYMENT_SESSION" }
        XCTAssertEqual(creates.count, 2)
        XCTAssertEqual(creates[0].key, creates[1].key)
        XCTAssertEqual(creates[0].fields["paymentToken"] as? String, creates[1].fields["paymentToken"] as? String)
        XCTAssertEqual(creates[0].key, h.store.value.submissionKey)
        XCTAssertEqual(h.driver.calls.filter { $0 == "createPaymentToken" }.count, 1)
        await h.flow.close()
    }

    func testActualCheckoutCallbacksGetDistinctKeysAndTransportRetriesReuseTheirPair() async throws {
        let h = try FlowHarness()
        h.driver.checkoutCallbacks = 2
        h.client.responses = FlowHarness.bootstrap + [FlowHarness.customer(), FlowHarness.payment(),
            .failure(PaymentActionError.transport), FlowHarness.payment(), FlowHarness.payment(), FlowHarness.read("SUBMITTED", "WAIT_FOR_PAYMENT")]
        _ = try await h.flow.run()
        let calls = h.client.calls.filter { $0.operation == "CONFIRM_PAYMENT" }
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[0].key, calls[1].key)
        XCTAssertEqual(calls[0].fields["callbackInvocationId"] as? String, calls[1].fields["callbackInvocationId"] as? String)
        XCTAssertNotEqual(calls[1].key, calls[2].key)
        XCTAssertNotEqual(calls[1].fields["callbackInvocationId"] as? String, calls[2].fields["callbackInvocationId"] as? String)
        await h.flow.close()
    }

    func testCheckoutKycRecoveryNeverCollectsASecondTokenOrCreatesAnotherSession() async throws {
        let h = try FlowHarness()
        h.client.responses = FlowHarness.bootstrap + [FlowHarness.customer(), FlowHarness.payment(),
            FlowHarness.payment("REJECTED", next: "SDK_VERIFY_IDENTITY", secret: false), FlowHarness.customer(next: "NONE"),
            FlowHarness.payment(), FlowHarness.payment(), FlowHarness.read("SUBMITTED", "WAIT_FOR_PAYMENT")]
        let outcome = try await h.flow.run()
        XCTAssertEqual(outcome, .submitted)
        XCTAssertEqual(h.driver.calls.filter { $0 == "createPaymentToken" }.count, 1)
        XCTAssertEqual(h.driver.calls.filter { $0 == "checkout" }.count, 2)
        XCTAssertEqual(h.driver.calls.filter { $0 == "verifyIdentity" }.count, 1)
        XCTAssertEqual(h.client.calls.filter { $0.operation == "CREATE_PAYMENT_SESSION" }.count, 1)
        XCTAssertEqual(h.client.calls.filter { $0.operation == "REFRESH_QUOTE" }.count, 1)
        await h.flow.close()
    }

    func testTokenFailureClaimsNothingSoTheOrderCanStillBePaid() async throws {
        for cancelled in [false, true] {
            let h = try FlowHarness()
            h.driver.failToken = cancelled ? StripeNativeError.cancelled : StripeNativeError.unavailable
            h.driver.onToken = { XCTAssertFalse(h.store.value.submissionStarted, "The fence is claimed after the token exists") }
            h.client.responses = FlowHarness.bootstrap + [FlowHarness.customer()]
            do {
                let outcome = try await h.flow.run()
                XCTAssertTrue(cancelled)
                XCTAssertEqual(outcome, .cancelled)
            } catch {
                XCTAssertFalse(cancelled)
                XCTAssertEqual(StripePaymentSession.failure(error, mayHaveFinancialAttempt: h.flow.mayHaveFinancialAttempt,
                                                            orderId: "synthetic-order").code, "PRESENTATION_FAILED")
            }
            XCTAssertFalse(h.store.value.submissionStarted)
            XCTAssertFalse(h.flow.mayHaveFinancialAttempt)
            XCTAssertFalse(h.client.calls.contains { $0.operation == "CREATE_PAYMENT_SESSION" })
            await h.flow.close()
            let retry = try FlowHarness(store: h.store)
            retry.client.responses = FlowHarness.bootstrap + [FlowHarness.customer(), FlowHarness.payment(), FlowHarness.payment(),
                                                              FlowHarness.read("SUBMITTED", "WAIT_FOR_PAYMENT")]
            let outcome = try await retry.flow.run()
            XCTAssertEqual(outcome, .submitted)
            XCTAssertEqual(retry.client.calls.filter { $0.operation == "CREATE_PAYMENT_SESSION" }.first?.key, h.store.value.submissionKey)
            await retry.flow.close()
        }
    }

    func testUnmountDuringNativeWorkSuppressesLaterBackendMutationsAndLogsOut() async throws {
        let h = try FlowHarness()
        h.driver.onHasAccount = { h.lifetime.close() }
        h.client.responses = [FlowHarness.bootstrap[0]]
        do { _ = try await h.flow.run(); XCTFail("Expected cancellation") } catch { }
        XCTAssertEqual(h.client.calls.map(\.operation), ["READ_SUBMISSION"])
        XCTAssertEqual(h.driver.calls, ["hasAccount"])
        await h.flow.close()
        XCTAssertEqual(h.driver.logouts, 1)
    }

    func testForeignCheckoutCallbackCannotReachBackend() async throws {
        let h = try FlowHarness()
        h.driver.callbackSession = "cos_other"
        h.client.responses = FlowHarness.bootstrap + [FlowHarness.customer(), FlowHarness.payment()]
        do { _ = try await h.flow.run(); XCTFail("Expected bound-session rejection") } catch { }
        XCTAssertFalse(h.client.calls.contains { $0.operation == "CONFIRM_PAYMENT" })
        await h.flow.close()
    }

    func testCancellationBeforePaymentLeavesNoFinancialClaim() async throws {
        let h = try FlowHarness()
        h.driver.cancelCollection = true
        h.client.responses = FlowHarness.bootstrap + [FlowHarness.customer()]
        let outcome = try await h.flow.run()
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(h.flow.mayHaveFinancialAttempt)
        XCTAssertFalse(h.store.value.submissionStarted)
        XCTAssertFalse(h.client.calls.contains { $0.operation == "CREATE_PAYMENT_SESSION" })
        await h.flow.close()
    }

    func testFormValidationRejectsMalformedDatesAndContactData() {
        XCTAssertFalse(StripeFormField.birthday.valid("2001-02-29"))
        XCTAssertTrue(StripeFormField.birthday.valid("2000-02-29"))
        XCTAssertFalse(StripeFormField.birthday.valid("9999-01-01"))
        XCTAssertFalse(StripeFormField.email.valid("x\n@example.test"))
        XCTAssertFalse(StripeFormField.phone.valid("5551234"))
        XCTAssertTrue(StripeFormField.phone.valid("+12025550123"))
        XCTAssertFalse(StripeFormField.state.valid("California"))
        XCTAssertTrue(StripeFormField.postalCode.valid("00000-0000"))
    }

    func testMountedFormsAreDismissedAndCallbacksSuppressedOnUnmount() async throws {
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        let root = UIViewController(), window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let client = FlowClient(), driver = FlowDriver()
        client.responses = [FlowHarness.bootstrap[0]]
        var ready = 0, terminal = 0
        let session = try StripePaymentSession(order: FlowHarness.order(), host: root.view, request: nil,
            handlers: MeldEventHandlers(onReady: { _ in ready += 1 }, onPaymentSubmitted: { _ in terminal += 1 },
                onStatusChange: { _ in terminal += 1 }, onCancel: { _ in terminal += 1 }, onError: { _ in terminal += 1 }),
            client: client, store: FlowStore(), factory: { try await StripeSdkRuntime.open(ownership: StripeSdkOwnership()) { driver } })
        for _ in 0..<100 {
            if root.presentedViewController is UINavigationController { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(ready, 1)
        XCTAssertTrue(root.presentedViewController is UINavigationController, "the first form presents over the host itself")
        session.unmount()
        for _ in 0..<100 {
            if driver.logouts == 1, root.presentedViewController == nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(root.presentedViewController)
        XCTAssertEqual(driver.logouts, 1)
        XCTAssertEqual(terminal, 0)
        XCTAssertEqual(client.calls.map(\.operation), ["READ_SUBMISSION"])
    }

    func testUnmountFromReadyHandlerPreventsStateReadAndSdkCreation() async throws {
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        let root = UIViewController(), window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let client = FlowClient(), counter = FlowCounter(), driver = FlowDriver()
        var ready = false
        var handle: MeldWidgetHandle?
        let session = try StripePaymentSession(order: FlowHarness.order(), host: root.view, request: nil,
            handlers: MeldEventHandlers(onReady: { _ in ready = true; handle?.unmount() }), client: client, store: FlowStore(),
            factory: { counter.value += 1; return try await StripeSdkRuntime.open(ownership: StripeSdkOwnership()) { driver } })
        handle = MeldWidgetHandle(mode: "native-sdk", session: session, gate: TerminalGate())
        for _ in 0..<100 {
            if ready, root.presentedViewController == nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(ready)
        XCTAssertTrue(client.calls.isEmpty)
        XCTAssertEqual(counter.value, 0)
        XCTAssertNil(root.presentedViewController)
    }

    func testNothingIsPresentedUntilTheCustomerIsNeededAndCancellingTheFirstFormIsACancel() async throws {
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        let root = UIViewController(), window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let client = FlowClient(), driver = FlowDriver()
        client.delay = true
        var cancelled = 0
        var errors: [String] = []
        let session = try StripePaymentSession(order: FlowHarness.order(), host: root.view, request: nil,
            handlers: MeldEventHandlers(onCancel: { _ in cancelled += 1 }, onError: { errors.append($0.code) }), client: client,
            store: FlowStore(), factory: { try await StripeSdkRuntime.open(ownership: StripeSdkOwnership()) { driver } })
        for _ in 0..<100 {
            if client.delayed != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(root.presentedViewController, "no screen while Meld is still answering")
        client.delayed?(FlowHarness.bootstrap[0]); client.delayed = nil
        for _ in 0..<100 {
            if root.presentedViewController is UINavigationController { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let navigation = try XCTUnwrap(root.presentedViewController as? UINavigationController)
        let cancel = try XCTUnwrap(navigation.topViewController?.navigationItem.leftBarButtonItem)
        UIApplication.shared.sendAction(try XCTUnwrap(cancel.action), to: cancel.target, from: nil, for: nil)
        for _ in 0..<100 {
            if cancelled == 1, root.presentedViewController == nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(cancelled, 1)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertNil(root.presentedViewController)
        XCTAssertFalse(client.calls.contains { $0.operation == "CREATE_PAYMENT_SESSION" })
        session.unmount()
    }

    func testCancellingABusyFormIsACancelUnlessThisDeviceMayHavePaid() async throws {
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        let root = UIViewController(), window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for claimed in [false, true] {
            let client = FlowClient(), driver = FlowDriver()
            driver.failAuthentication = claimed
            client.responses = claimed ? [FlowHarness.resume(), FlowHarness.authToken] : [FlowHarness.bootstrap[0]]
            var cancelled = 0, pending = 0
            var errors: [String] = []
            let session = try StripePaymentSession(order: FlowHarness.order(), host: root.view, request: nil,
                handlers: MeldEventHandlers(onStatusChange: { _ in pending += 1 }, onCancel: { _ in cancelled += 1 },
                                            onError: { errors.append($0.code) }),
                client: client, store: FlowStore(),
                factory: { try await StripeSdkRuntime.open(ownership: StripeSdkOwnership()) { driver } })
            for _ in 0..<100 {
                if root.presentedViewController is UINavigationController { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let navigation = try XCTUnwrap(root.presentedViewController as? UINavigationController, "claimed: \(claimed)")
            let form = try XCTUnwrap(navigation.topViewController)
            try XCTUnwrap(Self.views(UITextField.self, in: form.view).first).text = "buyer@example.test"
            client.delay = true
            try XCTUnwrap(Self.views(UIButton.self, in: form.view).first).sendActions(for: .touchUpInside)
            for _ in 0..<100 {
                if client.delayed != nil { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertTrue(root.presentedViewController === navigation, "the busy form stays up while Meld answers")
            let cancel = try XCTUnwrap(form.navigationItem.leftBarButtonItem)
            UIApplication.shared.sendAction(try XCTUnwrap(cancel.action), to: cancel.target, from: nil, for: nil)
            for _ in 0..<100 {
                if cancelled + errors.count > 0, root.presentedViewController == nil { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertNil(root.presentedViewController, "claimed: \(claimed)")
            XCTAssertEqual(cancelled, claimed ? 0 : 1, "claimed: \(claimed)")
            XCTAssertEqual(pending, claimed ? 1 : 0, "claimed: \(claimed)")
            XCTAssertEqual(errors, claimed ? ["PAYMENT_OUTCOME_UNKNOWN"] : [], "claimed: \(claimed)")
            client.delayed?(.failure(PaymentActionError.invalidResponse)); client.delayed = nil
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertEqual(cancelled + errors.count, 1, "a late flow failure adds no second terminal callback")
            session.unmount()
        }
    }

    func testWhatTheHostPresentsFromATerminalCallbackStaysUp() async throws {
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        let root = UIViewController(), window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let client = FlowClient(), alert = UIViewController()
        client.responses = [FlowHarness.bootstrap[0]]
        var ended = false
        var handlers = MeldEventHandlers(onCancel: { _ in root.present(alert, animated: false) }).gated()
        let backstop = handlers.sessionEnded
        handlers.sessionEnded = { ended = true; backstop?($0) }
        let session = try StripePaymentSession(order: FlowHarness.order(), host: root.view, request: nil, handlers: handlers,
            client: client, store: FlowStore(),
            factory: { try await StripeSdkRuntime.open(ownership: StripeSdkOwnership()) { FlowDriver() } })
        for _ in 0..<100 {
            if root.presentedViewController is UINavigationController { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let form = try XCTUnwrap((root.presentedViewController as? UINavigationController)?.topViewController)
        let cancel = try XCTUnwrap(form.navigationItem.leftBarButtonItem)
        UIApplication.shared.sendAction(try XCTUnwrap(cancel.action), to: cancel.target, from: nil, for: nil)
        for _ in 0..<100 {
            if ended { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(ended)
        XCTAssertTrue(root.presentedViewController === alert, "the SDK cleared its own screens before the callback")
        root.dismiss(animated: false)
        session.unmount()
    }

    private static func views<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        view.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + views(type, in: $0) }
    }

    func testEveryOutcomeEndsInOneTerminalEventThatSaysWhetherAPaymentMayExist() {
        func names(_ outcome: StripeFlowController.Outcome, attempt: Bool) -> [String] {
            StripePaymentSession.events(for: outcome, mayHaveFinancialAttempt: attempt, orderId: "synthetic-order").map {
                switch $0 {
                case .ready: return "ready"
                case .paymentSubmitted: return "submitted"
                case let .statusChange(change): return "status:\(change.status.rawValue)"
                case .cancel: return "cancel"
                case let .error(error): return error.recoverable ? "error" : "error:\(error.code)"
                }
            }
        }
        XCTAssertEqual(names(.pending, attempt: true), ["status:pending", "error:PAYMENT_OUTCOME_UNKNOWN"])
        XCTAssertEqual(names(.verificationPending, attempt: true), ["status:pending", "error:PAYMENT_OUTCOME_UNKNOWN"])
        XCTAssertEqual(names(.verificationPending, attempt: false), ["error:VERIFICATION_PENDING"])
        XCTAssertEqual(names(.verificationRequired, attempt: true), ["error:VERIFICATION_PENDING"])
        XCTAssertEqual(names(.submitted, attempt: true), ["status:pending", "submitted"])
        XCTAssertEqual(names(.completed, attempt: true), ["status:completed"])
        XCTAssertEqual(names(.cancelled, attempt: false), ["cancel"])
        XCTAssertEqual(names(.rejected, attempt: true), ["error:PAYMENT_REJECTED"])
        XCTAssertEqual(names(.refused(.providerRejected), attempt: true), ["error:PAYMENT_REJECTED"])
        XCTAssertEqual(names(.refused(.startNewOrder), attempt: true), ["error:PAYMENT_REJECTED"])
        XCTAssertEqual(names(.expired, attempt: true), ["error:PAYMENT_REJECTED"])
        let details = [StripeFlowController.Outcome.rejected, .refused(.providerRejected), .refused(.startNewOrder), .expired].flatMap {
            StripePaymentSession.events(for: $0, mayHaveFinancialAttempt: true, orderId: "synthetic-order")
        }.compactMap { event -> String? in if case let .error(error) = event { return error.detail }; return nil }
        XCTAssertEqual(details, ["submission:FAILED", "create:PROVIDER_REJECTED", "create:START_NEW_ORDER", "submission:EXPIRED"])
    }

    func testFailureCodeSaysWhetherAPaymentMayExistAndKeepsOnlyTheErrorIdentity() {
        let attempted = StripePaymentSession.failure(PaymentActionError.transport, mayHaveFinancialAttempt: true, orderId: "synthetic-order")
        XCTAssertEqual(attempted.code, "PAYMENT_OUTCOME_UNKNOWN")
        XCTAssertEqual(attempted.detail, "transport")
        XCTAssertFalse(attempted.recoverable)
        let refused = StripePaymentSession.failure(PaymentActionError.action(.providerRejected), mayHaveFinancialAttempt: true,
                                                   orderId: "synthetic-order")
        XCTAssertEqual(refused.detail, "action:PROVIDER_REJECTED")
        let unattempted = StripePaymentSession.failure(StripeNativeError.invalidResponse, mayHaveFinancialAttempt: false, orderId: "synthetic-order")
        XCTAssertEqual(unattempted.code, "PRESENTATION_FAILED")
        XCTAssertEqual(unattempted.detail, "invalidResponse")
        XCTAssertFalse(unattempted.recoverable)
        let foreign = StripePaymentSession.failure(NSError(domain: "SyntheticProvider", code: 7,
            userInfo: [NSLocalizedDescriptionKey: "customer@example.test"]), mayHaveFinancialAttempt: false, orderId: "synthetic-order")
        XCTAssertEqual(foreign.detail, "SyntheticProvider #7")
    }

    func testFailedFlowReportsOneTerminalErrorBeforeTeardown() async throws {
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        let root = UIViewController(), window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let unavailable: [Result<[String: Any], Error>] = [.failure(PaymentActionError.transport), .failure(PaymentActionError.transport)]
        let cases: [([Result<[String: Any], Error>], Bool, Bool, Bool, String)] = [
            (unavailable, false, false, false, "PRESENTATION_FAILED"),
            (unavailable, true, false, false, "PAYMENT_OUTCOME_UNKNOWN"),
            ([FlowHarness.read("FAILED", "NONE")], false, false, false, "PAYMENT_REJECTED"),
            ([FlowHarness.read("IN_PROGRESS", "WAIT_FOR_PROVIDER")], false, false, true, "PAYMENT_OUTCOME_UNKNOWN"),
            ([FlowHarness.read("SUCCEEDED", "COMPLETE")], false, false, true, "PAYMENT_OUTCOME_UNKNOWN"),
            ([FlowHarness.resume()], false, false, true, "PAYMENT_OUTCOME_UNKNOWN"),
            ([FlowHarness.bootstrap[0]], false, true, false, "PRESENTATION_FAILED")]
        for (responses, claimed, factoryFails, unwritable, expected) in cases {
            let client = FlowClient(), store = FlowStore()
            client.responses = responses
            store.value.submissionStarted = claimed
            store.unwritable = unwritable
            var events: [String] = []
            var handlers = MeldEventHandlers(onError: { events.append("error:\($0.code)") }).gated()
            let backstop = handlers.sessionEnded
            handlers.sessionEnded = { events.append("ended"); backstop?($0) }
            let session = try StripePaymentSession(order: FlowHarness.order(), host: root.view, request: nil, handlers: handlers,
                client: client, store: store, factory: {
                    if factoryFails { throw StripeNativeError.unavailable }
                    return try await StripeSdkRuntime.open(ownership: StripeSdkOwnership()) { FlowDriver() }
                })
            for _ in 0..<100 {
                if events.contains("ended"), root.presentedViewController == nil { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertEqual(events, ["error:\(expected)", "ended"], expected)
            XCTAssertNil(root.presentedViewController)
            session.unmount()
        }
    }

    func testFormsPresentOverTheHostsOwnSheetAndUnmountLeavesThatSheetInPlace() async throws {
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        let root = UIViewController(), window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let other = UIViewController()
        root.present(other, animated: false)
        for _ in 0..<100 {
            if other.viewIfLoaded?.window != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let client = FlowClient()
        client.responses = [FlowHarness.bootstrap[0]]
        var events: [String] = []
        let session = try StripePaymentSession(order: FlowHarness.order(), host: root.view, request: nil,
            handlers: MeldEventHandlers(onReady: { _ in events.append("ready") }, onError: { events.append("error:\($0.code)") }),
            client: client, store: FlowStore(),
            factory: { try await StripeSdkRuntime.open(ownership: StripeSdkOwnership()) { FlowDriver() } })
        for _ in 0..<100 {
            if other.presentedViewController is UINavigationController { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(events, ["ready"])
        XCTAssertTrue(other.presentedViewController is UINavigationController)
        session.unmount()
        for _ in 0..<100 {
            if other.presentedViewController == nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(other.presentedViewController)
        XCTAssertTrue(root.presentedViewController === other)
        root.dismiss(animated: false)
    }

    func testUnmountDismissesProviderSheetsAndAlwaysReleasesTheSdk() async throws {
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        let root = UIViewController(), window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for reportsDismissal in [true, false] {
            let client = FlowClient(), driver = FlowDriver(), ownership = StripeSdkOwnership()
            client.responses = [FlowHarness.resume(), FlowHarness.authToken]
            var pending: CheckedContinuation<Void, Error>?
            driver.onAuthenticate = {
                try await withCheckedThrowingContinuation { continuation in
                    let sheet = FlowProviderSheet()
                    if reportsDismissal { sheet.onDisappear = { continuation.resume(throwing: StripeNativeError.cancelled) } }
                    else { pending = continuation }
                    root.present(sheet, animated: false)
                }
            }
            let session = try StripePaymentSession(order: FlowHarness.order(), host: root.view, request: nil,
                handlers: MeldEventHandlers(), client: client, store: FlowStore(),
                factory: { try await StripeSdkRuntime.open(ownership: ownership, abandonAfter: 0.5) { driver } })
            for _ in 0..<100 {
                if root.presentedViewController is FlowProviderSheet { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertTrue(root.presentedViewController is FlowProviderSheet)
            session.unmount()
            for _ in 0..<100 {
                if root.presentedViewController == nil, driver.logouts == (reportsDismissal ? 1 : 0) { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertNil(root.presentedViewController, "reportsDismissal: \(reportsDismissal)")
            XCTAssertEqual(driver.logouts, reportsDismissal ? 1 : 0)
            if pending != nil {
                do { _ = try await StripeSdkRuntime.open(ownership: ownership) { FlowDriver() }; XCTFail("A pending call keeps the SDK") }
                catch StripeNativeError.busy { }
                for _ in 0..<100 {
                    if driver.logouts == 1 { break }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                XCTAssertEqual(driver.logouts, 1, "A call Stripe never resumes still ends in logout")
            }
            let next = try await StripeSdkRuntime.open(ownership: ownership) { FlowDriver() }
            await next.close()
            pending?.resume(throwing: StripeNativeError.cancelled)
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertEqual(driver.logouts, 1)
        }
    }

    func testTeardownWithoutATerminalReportsAnUnknownOutcomeUnlessTheHandleWasReleased() async throws {
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        let root = UIViewController(), window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for released in [false, true] {
            let client = FlowClient()
            client.delay = true
            let gate = TerminalGate()
            var errors: [String] = [], ended = 0
            var handlers = MeldEventHandlers(onError: { errors.append($0.code) }).gated(by: gate)
            let backstop = handlers.sessionEnded
            handlers.sessionEnded = { ended += 1; backstop?($0) }
            let session = try StripePaymentSession(order: FlowHarness.order(), host: root.view, request: nil, handlers: handlers,
                client: client, store: FlowStore(),
                factory: { try await StripeSdkRuntime.open(ownership: StripeSdkOwnership()) { FlowDriver() } })
            let handle = MeldWidgetHandle(mode: "native-sdk", session: session, gate: gate)
            for _ in 0..<100 {
                if client.delayed != nil { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            if released { handle.unmount() } else { session.unmount() }
            client.delayed?(FlowHarness.bootstrap[0]); client.delayed = nil
            for _ in 0..<100 {
                if ended >= 2, root.presentedViewController == nil { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertEqual(errors, released ? [] : ["PAYMENT_OUTCOME_UNKNOWN"], "released: \(released)")
            XCTAssertNil(root.presentedViewController)
        }
    }
}

@MainActor
private final class FlowHarness {
    let client = FlowClient(), driver = FlowDriver(), forms = FlowForms()
    let lifetime = StripeFlowLifetime(), factory = FlowCounter()
    let store: FlowStore
    let flow: StripeFlowController
    init(applePay: Bool = false, registration: Bool = false, store: FlowStore = FlowStore(),
         wire: URLSessionConfiguration? = nil) throws {
        self.store = store
        let order = try Self.order(applePay: applePay, registration: registration)
        let counter = factory, driver = driver
        let request = applePay ? try order.paymentRequest() : nil
        let transport: PaymentActionSending
        if let wire { transport = PaymentActionClient(descriptor: order.actions, configuration: wire) } else { transport = client }
        flow = StripeFlowController(order: order, client: transport, store: store, forms: forms, lifetime: lifetime, request: request,
                                   factory: {
            counter.value += 1
            return try await StripeSdkRuntime.open(ownership: StripeSdkOwnership()) { driver }
        }, pause: {})
    }
    static let bootstrap: [Result<[String: Any], Error>] = [
        .success(["version": 1, "status": "NOT_STARTED", "nextStep": "NONE", "sdk": ["authenticationState": "BOOTSTRAP"]]),
        .success(["version": 1, "status": "READY", "nextStep": "SDK_AUTHORIZE", "sdk": ["authenticationState": "REAUTHORIZE", "authorizationHandle": "lai_synthetic", "expiresAt": "2030-01-01T00:00:00Z"]]),
        .success(["version": 1, "status": "VERIFIED", "nextStep": "CREATE_PAYMENT_SESSION"])
    ]
    static func bootstrap(prefill: [String: Any]) -> Result<[String: Any], Error> {
        .success(["version": 1, "status": "NOT_STARTED", "nextStep": "NONE", "sdk": ["authenticationState": "BOOTSTRAP", "prefill": prefill]])
    }
    static let sumsubPrefill: [String: Any] = ["email": "buyer@example.test", "identity": [
        "firstName": "Ada", "lastName": "Lovelace", "dateOfBirth": "1990-03-15",
        "address": ["line1": "1 Market St", "city": "San Francisco", "state": "CA", "postalCode": "94105", "country": "US"]]]
    static let allIdentityFields = ["FIRST_NAME", "LAST_NAME", "DATE_OF_BIRTH", "ID_NUMBER", "ADDRESS_LINE_1",
                                    "ADDRESS_CITY", "ADDRESS_STATE", "ADDRESS_POSTAL_CODE", "ADDRESS_COUNTRY"]
    static let authToken: Result<[String: Any], Error> = .success(["version": 1, "status": "READY", "nextStep": "SDK_AUTHORIZE", "sdk": ["clientSecret": "latcs_synthetic", "expiresAt": "2030-01-01T00:00:00Z"]])
    static func read(_ status: String, _ next: String) -> Result<[String: Any], Error> {
        .success(["version": 1, "status": status, "nextStep": next])
    }
    static func resume() -> Result<[String: Any], Error> {
        .success(["version": 1, "status": "READY", "nextStep": "REFRESH_QUOTE", "sdk": ["authenticationState": "RESTORE", "sessionHandle": "cos_synthetic"]])
    }
    static func customer(_ status: String = "VERIFIED", next: String = "CREATE_PAYMENT_SESSION", missing: [String] = [],
                         tier: String? = "L1") -> Result<[String: Any], Error> {
        var customer: [String: Any] = ["missingFields": missing, "tiers": []]
        customer["highestVerifiedTier"] = tier
        return .success(["version": 1, "status": status, "nextStep": next, "customer": customer])
    }
    nonisolated static func limits(_ next: String = "CREATE_PAYMENT_SESSION") -> Result<[String: Any], Error> {
        .success(["version": 1, "status": "READY", "nextStep": next, "limits": ["availability": "AVAILABLE", "limits": []]])
    }
    static func payment(_ status: String = "REQUIRES_PAYMENT", next: String = "CONFIRM_PAYMENT", secret: Bool = true) -> Result<[String: Any], Error> {
        var sdk = ["sessionHandle": "cos_synthetic"]
        if secret { sdk["clientSecret"] = "cos_synthetic_secret" }
        return .success(["version": 1, "status": status, "nextStep": next, "sdk": sdk])
    }
    static func order(applePay: Bool = false, registration: Bool = false) throws -> StripeNativeOrder {
        var json: [String: Any] = ["id": "synthetic-order", "paymentMethodType": applePay ? "APPLE_PAY" : "CREDIT_DEBIT_CARD",
            "headlessPresentation": ["surface": "NATIVE_SDK", "protocol": "STRIPE_CRYPTO_ONRAMP", "version": 1],
            "payload": ["serviceProvider": "TEST_PROVIDER", "sourceAmount": 20, "sourceCurrencyCode": "USD", "countryCode": "US", "destinationWalletAddress": "wallet-synthetic"],
            "paymentMethodResponseDetails": ["sdkBootstrapType": "STRIPE_CRYPTO_ONRAMP", "providerIntentId": "lai_synthetic", "sdkFlow": "AUTHORIZE", "sdkEnvironment": "SANDBOX", "expiresAtEpochSeconds": 1_900_000_000, "continuationToken": "synthetic-bearer", "clientConfiguration": ["publicKey": "pk_test_synthetic", "walletNetwork": "base", "merchantIdentifier": "merchant.example.stripe"]],
            "paymentActions": ["version": 1, "endpoint": "/crypto/order/headless/onramp/TEST_PROVIDER/synthetic-order/actions", "bearerTokenPointer": "/paymentMethodResponseDetails/continuationToken",
                "operations": ["READ_SUBMISSION", "READ_CUSTOMER_STATUS", "READ_LIMITS", "COMPLETE_CUSTOMER_LINK", "CREATE_CUSTOMER_AUTH_TOKEN", "PREPARE_CUSTOMER_AUTHORIZATION", "CREATE_PAYMENT_SESSION", "CONFIRM_PAYMENT", "REFRESH_QUOTE"].enumerated().map { ["operation": $0.element, "idempotencyKeyRequired": $0.offset >= 3] as [String: Any] }]]
        if registration {
            var details = json["paymentMethodResponseDetails"] as! [String: Any]
            details["sdkFlow"] = "REGISTER"
            details.removeValue(forKey: "providerIntentId")
            json["paymentMethodResponseDetails"] = details
        }
        return try StripeNativeOrder(MeldOrder.from(jsonData: JSONSerialization.data(withJSONObject: json)), environment: .sandbox)
    }
}

private final class FlowCounter { var value = 0 }
private final class FlowWire: URLProtocol {
    enum Reply { case http(Int, [String: Any]), lost }
    struct Sent { let operation: String?; let key: String? }
    static var replies: [Reply] = []
    static var sent: [Sent] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while case let count = stream.read(&buffer, maxLength: buffer.count), count > 0 { data.append(buffer, count: count) }
            return data
        }
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        Self.sent.append(Sent(operation: json?["operation"] as? String, key: request.value(forHTTPHeaderField: "X-Idempotency-Key")))
        guard !Self.replies.isEmpty, case let .http(status, reply) = Self.replies.removeFirst() else {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: reply))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class FlowProviderSheet: UIViewController {
    var onDisappear: (() -> Void)?
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDisappear?(); onDisappear = nil
    }
}
private final class FlowClient: PaymentActionSending {
    struct Call { let operation: String; let fields: [String: Any]; let key: UUID? }
    var calls: [Call] = []
    var responses: [Result<[String: Any], Error>] = []
    var limits: [Result<[String: Any], Error>] = []
    var delay = false
    var delayed: ((Result<[String: Any], Error>) -> Void)?
    func send(_ operation: String, fields: [String: Any], key: UUID?, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        calls.append(Call(operation: operation, fields: fields, key: key))
        if delay { delayed = completion; return }
        if operation == "READ_LIMITS" { completion(limits.isEmpty ? FlowHarness.limits() : limits.removeFirst()); return }
        guard !responses.isEmpty else { XCTFail("Unexpected action \(operation)"); completion(.failure(PaymentActionError.invalidResponse)); return }
        completion(responses.removeFirst())
    }
    func finish() {}
}
private final class FlowStore: WalletAttemptStoring {
    var value = WalletAttemptRecord()
    var unreadable = false, unwritable = false
    func record() throws -> WalletAttemptRecord {
        if unreadable { throw PaymentActionError.storage }
        return value
    }
    func claimSubmission() throws -> UUID {
        guard !value.submissionStarted else { throw PaymentActionError.alreadyAttempted }
        value.submissionStarted = true; return value.submissionKey
    }
    func claimVerification() throws { value.verificationOpened = true }
    func observeSubmission() throws {
        if unwritable { throw PaymentActionError.storage }
        value.submissionStarted = true
    }
}
@MainActor
private final class FlowForms: StripeFlowPresenting {
    let presenter = UIViewController()
    var calls: [String] = []
    var handOffs = 0
    func handOff() async throws -> UIViewController { handOffs += 1; return presenter }
    var identityRequests: [[String]] = []
    func email() async throws -> String { calls.append("email"); return "customer@example.test" }
    func registration() async throws -> StripeRegistrationInput { calls.append("registration"); return StripeRegistrationInput(name: nil, phone: "+12025550123") }
    func identity(fields: [String]) async throws -> StripeIdentityInput {
        calls.append("identity"); identityRequests.append(fields)
        var input = StripeIdentityInput(); if fields.contains("ID_NUMBER") { input.idNumber = "000000000" }
        return input
    }
    func address() async throws -> StripeAddressInput { calls.append("address"); return StripeAddressInput(line1: "Synthetic", line2: nil, city: "Synthetic", state: "CA", postalCode: "00000", country: "US") }
    func showProgress(_ message: String) {}
    func close() {}
}
@MainActor
private final class FlowDriver: StripeSdkDriving {
    var calls: [String] = []
    var emails: [String] = []
    var registrations: [String] = []
    var failRegistrations = 0
    var attached: [StripeIdentityInput] = []
    var hasAccountResult = true, failAuthentication = false, updateAddress = false, cancelCollection = false
    var checkoutCallbacks = 1, logouts = 0
    var callbackSession: String?
    var failToken: StripeNativeError?
    var onHasAccount: (() -> Void)?
    var onToken: (() -> Void)?
    var onAuthenticate: (() async throws -> Void)?
    var collectedRequest: PKPaymentRequest?
    func hasAccount(email: String) async throws -> Bool {
        calls.append("hasAccount"); emails.append(email); onHasAccount?(); return hasAccountResult
    }
    func register(email: String, name: String?, phone: String, country: String) async throws {
        calls.append("register"); emails.append(email); registrations.append("\(name ?? "-") \(phone)")
        if failRegistrations > 0 { failRegistrations -= 1; throw StripeNativeError.invalidResponse }
    }
    func authorize(intent: String, from presenter: UIViewController) async throws -> String { calls.append("authorize"); return "crc_synthetic" }
    func authenticate(secret: String) async throws {
        calls.append("authenticate"); try await onAuthenticate?()
        if failAuthentication { throw StripeNativeError.authorizationRequired }
    }
    func attachIdentity(_ input: StripeIdentityInput) async throws { calls.append("attachIdentity"); attached.append(input) }
    func verifyIdentity(from presenter: UIViewController) async throws { calls.append("verifyIdentity") }
    func confirmIdentity(address: StripeAddressInput?, from presenter: UIViewController) async throws -> StripeKycConfirmation {
        calls.append("confirmIdentity"); if updateAddress { updateAddress = false; return .updateAddress }; return .confirmed
    }
    func registerWallet(address: String, network: String) async throws { calls.append("registerWallet") }
    func collectPayment(request: PKPaymentRequest?, from presenter: UIViewController) async throws {
        collectedRequest = request
        calls.append("collectPayment"); if cancelCollection { throw StripeNativeError.cancelled }
    }
    func createPaymentToken() async throws -> String {
        calls.append("createPaymentToken"); onToken?()
        if let failToken { throw failToken }
        return "cpt_synthetic"
    }
    func checkout(session: String, from presenter: UIViewController, secret: @escaping @MainActor (String) async throws -> String) async throws {
        calls.append("checkout")
        for _ in 0..<checkoutCallbacks { _ = try await secret(callbackSession ?? session) }
    }
    func logOut() async throws { logouts += 1 }
}
