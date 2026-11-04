import SafariServices
import UIKit
import XCTest
@testable import MeldSDK

final class RequirementsLoopTests: XCTestCase {
    private let meldKyc = "*:MELD_KYC:MELD_KYC_APPROVED"
    private let upholdTerms = "UPHOLD:AGREEMENT:general-us"
    private let email = "*:CUSTOMER_DETAILS:CUSTOMER_EMAIL"

    // MARK: - Fixtures end to end

    func testFreshCustomerSubmitsMeldKycOpensTheLinkAndDismissesItWhenTheStepLeaves() throws {
        let h = try LoopHarness("banxa-fresh")
        h.transport.reads = try RequirementsFixtures.reads("banxa-fresh") + RequirementsFixtures.reads("waiting-on-meld-kyc")
        h.transport.add(try RequirementsFixtures.runs("banxa-fresh"))
        h.options.waitTimeoutMs = 60_000
        h.start()
        let result = try h.waitForResult(self)

        XCTAssertEqual(result.status, .pending)
        XCTAssertNil(result.pending)
        XCTAssertEqual(Array(h.transport.operations.prefix(2)), ["READ", "RUN_STEP"])
        XCTAssertEqual(h.transport.runCalls.count, 1)
        XCTAssertJSONEqual(h.transport.runCalls[0].body, try RequirementsFixtures.runs("banxa-fresh")[0].request)
        XCTAssertEqual(h.transport.runCalls[0].key, h.keys[0].uuidString.lowercased())
        XCTAssertNil(h.transport.calls[0].key, "READ carries no idempotency key")
        XCTAssertJSONEqual(h.transport.calls[0].body, ["version": 1, "operation": "READ"])
        XCTAssertEqual(h.pages.pages.map(\.url.absoluteString), ["https://in.sumsub.com/websdk/p/sbx_fixture_1"])
        XCTAssertTrue(h.pages.pages[0].unmounted, "dismissed once the step left next[]")
        XCTAssertEqual(result.providers.map(\.serviceProvider), ["BANXA"])
        XCTAssertEqual(result.providers.first?.status, "WAITING")
        XCTAssertEqual(result.providers.first?.eligible, false)
        XCTAssertEqual(result.providers.first?.open.map(\.code), ["MELD_KYC_APPROVED", "PROVIDER_KYC_SHARE", "PROVIDER_KYC_APPROVED"])
        XCTAssertTrue(h.progress.contains(.presenting))
        XCTAssertTrue(h.progress.contains(.waiting))
        XCTAssertTrue(h.mainThreadOnly)
        XCTAssertTrue(h.transport.unmatched.isEmpty)
        XCTAssertEqual(h.transport.finished, 1)
    }

    func testTwoProvidersRunTermsThenEmailThenOneMeldKycForBoth() throws {
        let h = try LoopHarness("banxa-uphold")
        let reads = try RequirementsFixtures.reads("banxa-uphold")
        h.transport.reads = [reads[0], RequirementsFixtures.read(reads[0], without: [upholdTerms]), reads[1]]
        h.transport.add(try RequirementsFixtures.runs("banxa-uphold"))
        var agreements: [MeldAgreementRequest] = []
        var collects: [MeldCollectRequest] = []
        h.handlers.confirmAgreement = { agreements.append($0); $1(true) }
        h.handlers.collect = { collects.append($0); $1(["email": "ada@example.com"]) }
        h.pages.behaviour = .closeAfterOpening
        h.start()
        let result = try h.waitForResult(self)

        XCTAssertEqual(h.transport.runCalls.count, 3)
        for (call, run) in zip(h.transport.runCalls, try RequirementsFixtures.runs("banxa-uphold")) {
            XCTAssertJSONEqual(call.body, run.request)
        }
        XCTAssertEqual(Set(h.transport.runCalls.compactMap(\.key)).count, 3, "each step has its own key")
        XCTAssertEqual(agreements.map(\.serviceProvider), ["UPHOLD"])
        XCTAssertEqual(agreements.first?.code, "general-us")
        XCTAssertEqual(agreements.first?.url?.absoluteString, "https://uphold.test/tos-us")
        XCTAssertEqual(collects.map(\.stepId), [email])
        XCTAssertEqual(collects.first?.fields.map(\.key), ["email"])
        XCTAssertNil(collects.first?.fieldErrors)
        XCTAssertEqual(h.pages.opened.map(\.absoluteString), ["https://in.sumsub.com/websdk/p/sbx_fixture_1"])
        XCTAssertEqual(result.status, .actionRequired, "closed before submitting: the step is still offered")
        XCTAssertEqual(result.pending?.map(\.stepId), [meldKyc])
        XCTAssertEqual(result.pending?.first?.serviceProviders, ["BANXA", "UPHOLD"])
        XCTAssertEqual(result.pending?.first?.level, "LEVEL_2")
        XCTAssertEqual(result.providers.map(\.serviceProvider), ["BANXA", "UPHOLD"])
        XCTAssertTrue(h.transport.unmatched.isEmpty)
    }

    func testRefusedFieldsAreCollectedAgainWithTheirErrors() throws {
        let h = try LoopHarness("uphold-fresh")
        let read = try XCTUnwrap(try RequirementsFixtures.reads("uphold-fresh").first)
        h.transport.reads = [read, RequirementsFixtures.read(read, without: [upholdTerms])]
            + (try RequirementsFixtures.reads("uphold-after-terms-and-details"))
        h.transport.add(try RequirementsFixtures.runs("uphold-fresh"))
        h.transport.add(try RequirementsFixtures.runs("uphold-after-terms-and-details"))
        var collects: [MeldCollectRequest] = []
        h.handlers.confirmAgreement = { $1(true) }
        h.handlers.collect = { request, done in
            collects.append(request)
            DispatchQueue.global().async { done(["email": collects.count == 1 ? "not-an-email" : "ada@example.com"]) }
        }
        h.pages.behaviour = .cancelPrompt
        h.start()
        let result = try h.waitForResult(self)

        XCTAssertEqual(collects.count, 2)
        XCTAssertNil(collects[0].fieldErrors)
        XCTAssertEqual(collects[1].fieldErrors, [MeldFieldError(key: "email", reason: "INVALID")])
        let runs = try RequirementsFixtures.runs("uphold-fresh")
        XCTAssertEqual(h.transport.runCalls.count, 4)
        XCTAssertJSONEqual(h.transport.runCalls[0].body, runs[1].request)
        XCTAssertJSONEqual(h.transport.runCalls[1].body, runs[0].request)
        XCTAssertJSONEqual(h.transport.runCalls[2].body, runs[2].request)
        XCTAssertNotEqual(h.transport.runCalls[1].key, h.transport.runCalls[2].key, "a new body is a new key")
        XCTAssertEqual(result.status, .actionRequired, "Cancel on the prompt leaves the step to the customer")
        XCTAssertEqual(result.pending?.map(\.stepId), [meldKyc])
        XCTAssertTrue(h.pages.opened.isEmpty)
        XCTAssertTrue(h.mainThreadOnly)
        XCTAssertTrue(h.transport.unmatched.isEmpty)
    }

    func testAnExpiringHostedPageIsRefreshedBeforeItOpensAndAgainAfterItCloses() throws {
        let h = try LoopHarness("noah-hosted-onboarding")
        h.transport.reads = try RequirementsFixtures.reads("noah-hosted-onboarding")
        let runs = try RequirementsFixtures.runs("noah-hosted-onboarding")
        h.transport.add(runs)
        h.pages.behaviour = .closeAfterOpening
        h.options.waitTimeoutMs = 30_000
        h.start()
        let result = try h.waitForResult(self)

        XCTAssertEqual(h.transport.runCalls.count, 2)
        XCTAssertJSONEqual(h.transport.runCalls[0].body, runs[0].request)
        XCTAssertJSONEqual(h.transport.runCalls[1].body, runs[1].request)
        XCTAssertEqual(h.transport.operations.firstIndex(of: "RUN_STEP"), 1, "refresh before anything is shown")
        XCTAssertEqual(h.pages.pages.map(\.url.absoluteString), ["https://onboarding.noah.test/hosted?session=fixture-2"])
        XCTAssertNotEqual(h.transport.runCalls[0].key, h.transport.runCalls[1].key)
        XCTAssertEqual(result.status, .pending)
        XCTAssertEqual(result.providers.first?.status, "WAITING")
        XCTAssertTrue(h.transport.unmatched.isEmpty)
    }

    func testProviderHostedFormFromAProcessIsPresentedAndPolledAtItsInterval() throws {
        let h = try LoopHarness("coinbase-limit-upgrade")
        h.transport.reads = try RequirementsFixtures.reads("coinbase-limit-upgrade")
        h.transport.add(try RequirementsFixtures.runs("coinbase-limit-upgrade"))
        h.options.waitTimeoutMs = 10_000
        h.start()
        let result = try h.waitForResult(self)

        XCTAssertEqual(h.pages.pages.map(\.url.absoluteString), ["https://pay.coinbase.test/limits/upgrade?session=fixture"])
        XCTAssertTrue(h.pages.pages[0].unmounted)
        XCTAssertEqual(result.status, .pending)
        XCTAssertTrue(h.clock.delays.contains(2000), "PENDING process polls at 2000 ms")
        XCTAssertEqual(h.transport.runCalls.count, 1)
    }

    func testUnknownStepIsUndeterminedWithoutRunningAnything() throws {
        let h = try LoopHarness("unknown-step")
        h.transport.reads = try RequirementsFixtures.reads("unknown-step")
        h.handlers.collect = { _, _ in XCTFail("nothing to collect") }
        h.start()
        let result = try h.waitForResult(self)

        XCTAssertEqual(result.status, .undetermined)
        XCTAssertEqual(h.transport.operations, ["READ"])
        XCTAssertEqual(result.providers.first?.eligible, nil)
        XCTAssertEqual(result.providers.first?.status, "UNDETERMINED")
        XCTAssertEqual(result.providers.first?.open.map(\.code), ["PROVIDER_EXTRA_KYC"])
        XCTAssertEqual(result.providers.first?.open.first?.reason, "STATE_UNAVAILABLE")
        XCTAssertTrue(result.continuation.isEmpty)
        XCTAssertEqual(h.progress, [.reading])
    }

    func testAShareTheProviderRefusedEndsBlockedWithItsReasonAndErrorCodesInOpen() throws {
        let h = try LoopHarness("coinme-share-refused")
        h.transport.reads = try RequirementsFixtures.reads("coinme-share-refused")
        h.handlers.collect = { _, _ in XCTFail("nothing to collect") }
        h.start()
        let result = try h.waitForResult(self)

        XCTAssertEqual(result.status, .blocked)
        XCTAssertEqual(h.transport.operations, ["READ"])
        XCTAssertNil(result.pending)
        XCTAssertEqual(result.providers.map(\.serviceProvider), ["COINME"])
        XCTAssertEqual(result.providers.first?.eligible, false)
        let open = try XCTUnwrap(result.providers.first?.open)
        XCTAssertEqual(open.map(\.code), ["PROVIDER_KYC_SHARE", "PROVIDER_KYC_APPROVED"])
        XCTAssertEqual(open[0].status, "BLOCKED")
        XCTAssertEqual(open[0].reason, "Coinme needs the customer's phone verified first")
        XCTAssertEqual(open[0].errorCodes, ["PHONE_VERIFICATION_REQUIRED"])
        XCTAssertNil(open[1].reason)
        XCTAssertNil(open[1].errorCodes)
    }

    func testEveryRequirementsSessionFixtureReplaysThroughTheLoop() throws {
        let names = try RequirementsFixtures.sessionNames()
        XCTAssertGreaterThanOrEqual(names.count, 9)
        for name in names {
            let replay = try FixtureReplay(name)
            let h = replay.harness
            h.start()
            let result = try h.waitForResult(self)
            let actions = try XCTUnwrap(replay.mint["requirementsActions"] as? [String: Any])
            let endpoint = "https://api-sb.meld.io" + (try XCTUnwrap(actions["endpoint"] as? String))
            let bearer = "Bearer " + (try XCTUnwrap(replay.mint["token"] as? String))
            for call in h.transport.calls {
                XCTAssertEqual(call.request.url?.absoluteString, endpoint, name)
                XCTAssertEqual(call.request.value(forHTTPHeaderField: "Authorization"), bearer, name)
                if call.operation == "READ" {
                    XCTAssertNil(call.key, name)
                    XCTAssertJSONEqual(call.body, ["version": 1, "operation": "READ"])
                } else {
                    XCTAssertNotNil(call.key.flatMap(UUID.init(uuidString:)), name)
                }
            }
            XCTAssertEqual(Set(h.transport.runCalls.compactMap(\.key)).count, h.transport.runCalls.count,
                           "\(name): every RUN_STEP is a new request")
            let unused = replay.exchanges.filter { !$0.used }
            XCTAssertFalse(unused.contains { $0.operation == "READ" }, "\(name): every READ was replayed")
            XCTAssertEqual(unused.count, replay.neverOffered, "\(name): every RUN_STEP the reads offer was replayed")
            XCTAssertLessThanOrEqual(replay.unscripted.count, 1, name)
            XCTAssertNotEqual(result.status, .failed, name)
            XCTAssertTrue(NSArray(array: RequirementsFixtures.reported(result.providers)).isEqual(to: RequirementsFixtures.reported(replay.current)),
                          "\(name): providers as last read, with each open step's reason and errorCodes")
            XCTAssertTrue(h.mainThreadOnly, name)
        }
    }

    func testRefusedStepIsReadAgainAndNeverResent() throws {
        let h = try LoopHarness("banxa-fresh")
        h.transport.reads = try RequirementsFixtures.reads("banxa-fresh") + RequirementsFixtures.reads("waiting-on-meld-kyc")
        h.transport.add(try RequirementsFixtures.runs("waiting-on-meld-kyc"))
        h.options.waitTimeoutMs = 20_000
        h.start()
        let result = try h.waitForResult(self)

        XCTAssertEqual(h.transport.runCalls.count, 1, "409 CONCURRENT_STATE_CHANGE is never resent")
        XCTAssertEqual(h.transport.operations[2], "READ")
        XCTAssertEqual(result.status, .pending)
        XCTAssertTrue(h.pages.pages.isEmpty)
    }

    func testActionRequiredWithNothingToRunOrWaitForEndsAtOnceWithAnEmptyPending() throws {
        var read = try XCTUnwrap(try RequirementsFixtures.reads("uphold-fresh").first)
        read["next"] = [[String: Any]]()
        let h = try LoopHarness("uphold-fresh")
        h.transport.reads = [read]
        h.start()
        let result = try h.waitForResult(self)
        XCTAssertEqual(result.status, .actionRequired)
        XCTAssertEqual(result.pending?.count, 0)
        XCTAssertEqual(result.providers.first?.open.first?.code, "general-us", "providers[].open names what is left")
        XCTAssertEqual(h.transport.operations, ["READ"])
        XCTAssertTrue(h.clock.delays.isEmpty, "never polled")

        let waiting = try LoopHarness("uphold-fresh")
        read["waitingOn"] = try XCTUnwrap(try RequirementsFixtures.reads("waiting-on-meld-kyc").first)["waitingOn"]
        waiting.transport.reads = [read]
        waiting.options.waitTimeoutMs = 20_000
        waiting.start()
        XCTAssertEqual(try waiting.waitForResult(self).status, .pending, "something to wait for keeps polling")
        XCTAssertFalse(waiting.clock.delays.isEmpty)
    }

    func testAPageClosedUnfinishedIsNotPresentedAgainWhenOnlyItsLinkRotated() throws {
        let step = "NOAH:EXTERNAL_KYC:NOAH_HOSTED_ONBOARDING"
        let read = try XCTUnwrap(try RequirementsFixtures.reads("noah-hosted-onboarding").first)
        let first = RequirementsFixtures.read(read, changing: step) { $0["expiresAt"] = "2026-11-04T15:30:00Z" }
        let rotated = RequirementsFixtures.read(try XCTUnwrap(relinked(first) as? [String: Any]), changing: step) {
            $0["expiresAt"] = "2026-11-04T15:35:00Z"
        }
        let h = try LoopHarness("noah-hosted-onboarding")
        h.transport.reads = [first, rotated]
        h.transport.add([try XCTUnwrap(try RequirementsFixtures.runs("noah-hosted-onboarding").first)])
        h.pages.behaviour = .closeAfterOpening
        h.start()
        let result = try h.waitForResult(self)
        XCTAssertEqual(h.pages.pages.map(\.url.absoluteString), ["https://onboarding.noah.test/hosted?session=fixture-1"])
        XCTAssertEqual(h.transport.runCalls.count, 1, "one refresh after the close")
        XCTAssertEqual(result.status, .actionRequired)
        XCTAssertEqual(result.pending?.map(\.stepId), [step])
        XCTAssertTrue(h.transport.unmatched.isEmpty)
    }

    func testAConflictOnTheRefreshAfterCloseReadsAgain() throws {
        let h = try LoopHarness("noah-hosted-onboarding")
        h.transport.reads = try RequirementsFixtures.reads("noah-hosted-onboarding")
        h.transport.add(try RequirementsFixtures.runs("noah-hosted-onboarding"))
        var runs = 0
        h.transport.respond = { call in
            guard call.operation == "RUN_STEP" else { return nil }
            runs += 1
            return runs == 2 ? FixtureTransport.json(409, ["version": 1, "code": "CONCURRENT_STATE_CHANGE"]) : nil
        }
        h.pages.behaviour = .closeAfterOpening
        h.options.waitTimeoutMs = 30_000
        h.start()
        let result = try h.waitForResult(self)
        let refresh = try XCTUnwrap(h.transport.calls.lastIndex { $0.operation == "RUN_STEP" })
        XCTAssertEqual(h.transport.runCalls.count, 2, "the refresh is not resent")
        XCTAssertEqual(h.transport.calls.dropFirst(refresh + 1).first?.operation, "READ")
        XCTAssertEqual(result.status, .pending)
        XCTAssertNil(result.error)
    }

    func testA401OnTheRefreshAfterCloseRenewsAndRefreshesAgainWithoutReopeningThePage() throws {
        let runs = try RequirementsFixtures.runs("noah-hosted-onboarding")
        let normal = try closeRefresh(refusing: [:])
        XCTAssertEqual(normal.renewals, 0)
        XCTAssertEqual(normal.harness.transport.runCalls.count, 2)
        XCTAssertEqual(normal.result.status, .actionRequired, "closed unfinished: the step is still offered")
        XCTAssertEqual(normal.result.pending?.map(\.stepId), [try XCTUnwrap(runs[1].request["stepId"] as? String)])

        let unauthorized = FixtureTransport.json(401, ["version": 1, "code": "AUTHORIZATION_REQUIRED"])
        let unknown = FixtureTransport.json(503, ["version": 1, "code": "OUTCOME_UNKNOWN"])
        let inFlight = FixtureTransport.json(425, ["version": 1, "code": "OPERATION_IN_FLIGHT"])
        let lost = ActionTransportResult.transportFailed
        // Answers by call, counted from the refresh after the close (0).
        let cases: [(String, [Int: ActionTransportResult], Bool)] = [
            ("401", [0: unauthorized], false), ("lost, 401", [0: lost, 1: unauthorized], false),
            ("425, 401", [0: inFlight, 1: unauthorized], false), ("503, READ 401", [0: unknown, 1: unauthorized], false),
            ("503, READ lost, READ 401", [0: unknown, 1: lost, 2: unauthorized], false),
            ("503, resend 401", [0: unknown, 2: unauthorized], false), ("presentUrl, 401", [0: unauthorized], true),
        ]
        for (name, refused, presentUrl) in cases {
            let run = try closeRefresh(refusing: refused, presentUrl: presentUrl)
            let calls = run.harness.transport.calls
            let resent = run.refresh + (try XCTUnwrap(refused.keys.max())) + 1
            XCTAssertEqual(run.renewals, 1, name)
            if presentUrl {
                XCTAssertEqual(run.presented, 1, "one page: \(name)")
            } else {
                XCTAssertEqual(run.harness.pages.pages.map(\.prompted), [true], "one prompt, one page: \(name)")
                XCTAssertEqual(run.harness.pages.opened.count, 1, name)
            }
            XCTAssertJSONEqual(calls[resent].body, runs[1].request)
            XCTAssertEqual(calls[resent].request.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.renewedToken)", name)
            XCTAssertNotEqual(calls[resent].key, calls[run.refresh].key, name)
            XCTAssertEqual(calls.dropFirst(resent + 1).first?.operation, "READ", name)
            XCTAssertFalse(calls.dropFirst(resent + 1).contains { $0.operation == "RUN_STEP" }, "nothing runs again: \(name)")
            XCTAssertEqual(run.result.status, normal.result.status, name)
            XCTAssertEqual(run.result.pending?.map(\.stepId), normal.result.pending?.map(\.stepId), name)
            XCTAssertNil(run.result.error, name)
            XCTAssertTrue(run.harness.transport.unmatched.isEmpty, name)
        }
    }

    func testA401AgainOnTheRefreshAfterCloseEndsExpired() throws {
        let runs = try RequirementsFixtures.runs("noah-hosted-onboarding")
        let unauthorized = FixtureTransport.json(401, ["version": 1, "code": "AUTHORIZATION_REQUIRED"])
        let cases: [(String, [Int: ActionTransportResult])] = [
            ("401, 401", [0: unauthorized, 1: unauthorized]),
            ("401, lost, 401", [0: unauthorized, 1: .transportFailed, 2: unauthorized]),
        ]
        for (name, refused) in cases {
            let run = try closeRefresh(refusing: refused)
            let calls = run.harness.transport.calls
            XCTAssertEqual(run.renewals, 1, name)
            XCTAssertJSONEqual(calls[run.refresh + 1].body, runs[1].request)
            XCTAssertEqual(calls[run.refresh + 1].request.value(forHTTPHeaderField: "Authorization"),
                           "Bearer \(Self.renewedToken)", name)
            XCTAssertEqual(calls.count, run.refresh + refused.count, "nothing after the second 401: \(name)")
            XCTAssertEqual(run.result.status, .expired, name)
            XCTAssertNil(run.result.error, name)
            XCTAssertEqual(run.harness.pages.pages.map(\.prompted), [true], name)
        }
    }

    func testAPageTheSdkDismissesIsNotRefreshed() throws {
        let h = try LoopHarness("noah-hosted-onboarding")
        h.transport.reads = try RequirementsFixtures.reads("noah-hosted-onboarding")
        h.transport.add(try RequirementsFixtures.runs("noah-hosted-onboarding"))
        h.options.waitTimeoutMs = 30_000
        h.start()
        let result = try h.waitForResult(self)
        XCTAssertTrue(h.pages.pages[0].unmounted, "dismissed when the step left next[]")
        XCTAssertEqual(h.transport.runCalls.count, 1, "only the refresh before opening")
        XCTAssertEqual(result.status, .pending)
    }

    func testAFailedReadWhileThePageIsOpenIsIgnoredAndPollingGoesOn() throws {
        let h = try LoopHarness("noah-hosted-onboarding")
        h.transport.reads = try RequirementsFixtures.reads("noah-hosted-onboarding")
        h.transport.add(try RequirementsFixtures.runs("noah-hosted-onboarding"))
        let failures: [ActionTransportResult] = [.transportFailed,
                                                 FixtureTransport.json(401, ["version": 1, "code": "AUTHORIZATION_REQUIRED"]),
                                                 FixtureTransport.json(503, ["version": 1, "code": "OUTCOME_UNKNOWN"]),
                                                 FixtureTransport.json(500, ["version": 1, "code": "INTERNAL_ERROR"])]
        var reads = 0
        h.transport.respond = { call in
            guard call.operation == "READ" else { return nil }
            reads += 1
            return (2...5).contains(reads) ? failures[reads - 2] : nil
        }
        var renewals = 0
        h.handlers.renewSession = { done in renewals += 1; done(nil) }
        h.options.waitTimeoutMs = 30_000
        h.start()
        let result = try h.waitForResult(self)
        XCTAssertEqual(renewals, 0, "no renewal for a background READ")
        XCTAssertEqual(result.status, .pending)
        XCTAssertNil(result.error)
        XCTAssertEqual(Array(h.clock.delays.prefix(6)), [4000, 4000, 4000, 4000, 4000, 15000], "polled on at pollAfterMs")
        XCTAssertTrue(h.pages.pages[0].unmounted, "dismissed by the first READ that answered")
        XCTAssertEqual(h.transport.runCalls.count, 1)
    }

    // MARK: - Waiting

    func testWaitingSleepsPollAfterMsRefreshWakesItAndTheTimeoutIsPending() throws {
        let h = try LoopHarness("waiting-on-meld-kyc")
        h.transport.reads = try RequirementsFixtures.reads("waiting-on-meld-kyc")
        h.clock.manual = true
        h.options.waitTimeoutMs = 20_000
        let loop = h.start()
        h.spin { h.clock.live.count == 1 }
        XCTAssertEqual(h.clock.delays, [15000])
        XCTAssertEqual(h.transport.operations, ["READ"])
        loop.refresh()
        h.spin { h.transport.operations.count == 2 && h.clock.live.count == 1 }
        XCTAssertEqual(h.transport.operations, ["READ", "READ"], "refresh() reads at once")
        XCTAssertTrue(h.results.isEmpty)
        while h.results.isEmpty, h.clock.fireNext() { h.spin { !h.clock.live.isEmpty || !h.results.isEmpty } }
        let result = try h.waitForResult(self)
        XCTAssertEqual(result.status, .pending)
        XCTAssertEqual(h.progress.filter { $0 == .waiting }.count, h.clock.delays.count)
    }

    func testPollIntervalIsKeptBetweenOneAndSixtySecondsAndDefaultsToFour() throws {
        let read = try XCTUnwrap(try RequirementsFixtures.reads("waiting-on-meld-kyc").first)
        let cases: [(Any?, Int)] = [(nil, 4000), ("2000", 4000), (true, 4000), (NSNull(), 4000), (0, 1000), (-5, 1000),
                                    (999, 1000), (2000, 2000), (2500.5, 2500), (60_000, 60_000), (300_000, 60_000)]
        for (value, expected) in cases {
            var copy = read
            copy["pollAfterMs"] = value
            XCTAssertEqual(try RequirementsSnapshot(copy).pollAfterMs, expected, String(describing: value))
        }
        var slow = read
        slow["pollAfterMs"] = 300_000
        let h = try LoopHarness("waiting-on-meld-kyc")
        h.transport.reads = [slow]
        h.clock.manual = true
        let loop = h.start()
        h.spin { h.clock.live.count == 1 }
        XCTAssertEqual(h.clock.delays, [60_000])
        loop.cancel()
    }

    func testRefreshDoesNotShortenARetryBackoff() throws {
        let failures: [ActionTransportResult] = [.transportFailed,
                                                 FixtureTransport.json(425, ["version": 1, "code": "OPERATION_IN_FLIGHT"])]
        for failure in failures {
            let h = try LoopHarness("banxa-fresh")
            h.clock.manual = true
            h.transport.reads = try RequirementsFixtures.reads("banxa-fresh")
            h.transport.add(try RequirementsFixtures.runs("banxa-fresh"))
            var failed = false
            h.transport.respond = { call in
                guard call.operation == "RUN_STEP", !failed else { return nil }
                failed = true
                return failure
            }
            let loop = h.start()
            h.spin { h.clock.live.count == 1 }
            XCTAssertEqual(h.clock.delays, [1000])
            loop.refresh()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            XCTAssertEqual(h.transport.runCalls.count, 1, "refresh() leaves the backoff alone")
            XCTAssertTrue(h.clock.fireNext())
            h.spin { h.transport.runCalls.count == 2 }
            XCTAssertEqual(h.transport.runCalls.count, 2)
            XCTAssertEqual(h.transport.runCalls[1].key, h.transport.runCalls[0].key)
            loop.cancel()
        }
    }

    // MARK: - Handlers

    func testTermsAreNeverAcceptedWithoutTheIntegrator() throws {
        let read = try onlyStep(upholdTerms, of: "uphold-fresh")
        let h = try LoopHarness("uphold-fresh")
        h.transport.reads = [read]
        h.start()
        let noHandler = try h.waitForResult(self)
        XCTAssertEqual(noHandler.status, .actionRequired)
        XCTAssertEqual(noHandler.pending?.map(\.stepId), [upholdTerms])
        XCTAssertTrue(h.transport.runCalls.isEmpty)

        let declined = try LoopHarness("uphold-fresh")
        declined.transport.reads = [read]
        var asked = 0
        declined.handlers.confirmAgreement = { _, done in asked += 1; done(false) }
        declined.start()
        let result = try declined.waitForResult(self)
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(result.status, .actionRequired)
        XCTAssertEqual(result.pending?.map(\.stepId), [upholdTerms])
        XCTAssertTrue(declined.transport.runCalls.isEmpty)
    }

    func testAnUnknownKindIsNeverRunAndTheNextRunnableStepIs() throws {
        var read = try XCTUnwrap(try RequirementsFixtures.reads("banxa-fresh").first)
        let unknown: [String: Any] = ["stepId": "BANXA:PROVIDER_PROCESS:passkey", "kind": "SIGN_WITH_PASSKEY",
                                      "type": "PROVIDER_PROCESS", "code": "passkey", "serviceProviders": ["BANXA"]]
        read["next"] = [unknown] + (read["next"] as? [[String: Any]] ?? [])
        let h = try LoopHarness("banxa-fresh")
        h.transport.reads = [read]
        h.transport.add(try RequirementsFixtures.runs("banxa-fresh"))
        h.pages.behaviour = .cancelPrompt
        h.start()
        let result = try h.waitForResult(self)
        XCTAssertEqual(h.transport.runCalls.map(\.stepId), [meldKyc], "the unknown kind is skipped, never sent")
        XCTAssertEqual(result.status, .actionRequired)
        XCTAssertEqual(result.pending?.map(\.stepId), [meldKyc])

        let only = try LoopHarness("banxa-fresh")
        only.transport.reads = [RequirementsFixtures.read(read, without: [meldKyc])]
        only.start()
        let alone = try only.waitForResult(self)
        XCTAssertEqual(alone.status, .actionRequired)
        XCTAssertEqual(alone.pending?.map(\.kind), ["SIGN_WITH_PASSKEY"])
        XCTAssertTrue(only.transport.runCalls.isEmpty)
    }

    func testCollectAnsweringNilReadsAgainWithoutRunning() throws {
        let h = try LoopHarness("uphold-fresh")
        h.transport.reads = [try onlyStep(email, of: "uphold-fresh")]
        var asked = 0
        h.handlers.collect = { _, done in asked += 1; done(nil) }
        h.start()
        let result = try h.waitForResult(self)
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(h.transport.runCalls.isEmpty)
        XCTAssertGreaterThan(h.transport.operations.count, 1)
        XCTAssertEqual(result.status, .actionRequired)
        XCTAssertEqual(result.pending?.map(\.stepId), [email])
    }

    func testFieldErrorsAreCollectedAgainAtMostThreeTimes() throws {
        let h = try LoopHarness("uphold-fresh")
        h.transport.reads = [try onlyStep(email, of: "uphold-fresh")]
        h.transport.respond = { call in
            call.operation == "RUN_STEP"
                ? FixtureTransport.json(400, ["version": 1, "code": "INVALID_REQUEST", "fieldErrors": [["key": "email", "reason": "INVALID"]]])
                : nil
        }
        var asked = 0
        h.handlers.collect = { _, done in asked += 1; done(["email": "x"]) }
        h.start()
        let result = try h.waitForResult(self)
        XCTAssertEqual(asked, 4)
        XCTAssertEqual(h.transport.runCalls.count, 4)
        XCTAssertEqual(result.status, .actionRequired)
        XCTAssertEqual(result.pending?.map(\.stepId), [email])
    }

    func testVerifyContactAsksForTheContactThenTheCodeWithTheContinuation() throws {
        let step = "*:VERIFICATION:EMAIL"
        let read = try onlyStep(email, of: "uphold-fresh", changing: {
            $0 = ["stepId": step, "kind": "VERIFY_CONTACT", "type": "VERIFICATION", "code": "EMAIL", "serviceProviders": ["UPHOLD"]]
        })
        let h = try LoopHarness("uphold-fresh")
        h.transport.reads = [read] + (try RequirementsFixtures.reads("unknown-step"))
        let base: [String: Any] = ["version": 1, "operation": "RUN_STEP", "stepId": step]
        h.transport.runs = [
            (base, 200, ["version": 1, "stepId": step, "outcome": "COLLECT", "fields": [["key": "email"]]]),
            (base.merging(["fields": ["email": "ada@example.com"]]) { $1 }, 200,
             ["version": 1, "stepId": step, "outcome": "COLLECT", "fields": [["key": "otp", "label": "Code"]], "continuation": "vrf_1"]),
            (base.merging(["fields": ["otp": "000000"], "continuation": "vrf_1"]) { $1 }, 400,
             ["version": 1, "code": "INVALID_REQUEST", "fieldErrors": [["key": "otp", "reason": "INVALID"]]]),
            (base.merging(["fields": ["otp": "123456"], "continuation": "vrf_1"]) { $1 }, 200,
             ["version": 1, "stepId": step, "outcome": "DONE"]),
        ]
        var collects: [MeldCollectRequest] = []
        h.handlers.collect = { request, done in
            collects.append(request)
            switch collects.count {
            case 1: done(["email": "ada@example.com"])
            case 2: done(["otp": "000000"])
            default: done(["otp": "123456"])
            }
        }
        h.start()
        let result = try h.waitForResult(self)
        XCTAssertEqual(collects.map { $0.fields.map(\.key) }, [["email"], ["otp"], ["otp"]])
        XCTAssertEqual(collects[1].fields.first?.label, "Code")
        XCTAssertEqual(collects[2].fieldErrors, [MeldFieldError(key: "otp", reason: "INVALID")])
        XCTAssertEqual(h.transport.runCalls.count, 4)
        XCTAssertTrue(h.transport.unmatched.isEmpty)
        XCTAssertEqual(result.status, .undetermined)
    }

    func testARejectedCodeIsAskedForAgainAtMostThreeTimes() throws {
        let step = "*:VERIFICATION:EMAIL"
        let read = try onlyStep(email, of: "uphold-fresh", changing: {
            $0 = ["stepId": step, "kind": "VERIFY_CONTACT", "type": "VERIFICATION", "code": "EMAIL", "serviceProviders": ["UPHOLD"]]
        })
        let h = try LoopHarness("uphold-fresh")
        h.transport.reads = [read]
        h.transport.respond = { call in
            guard call.operation == "RUN_STEP" else { return nil }
            return call.body["fields"] == nil
                ? FixtureTransport.json(200, ["version": 1, "stepId": step, "outcome": "COLLECT", "fields": [["key": "otp"]],
                                              "continuation": "vrf_1"])
                : FixtureTransport.json(400, ["version": 1, "code": "INVALID_REQUEST", "fieldErrors": [["key": "otp", "reason": "INVALID"]]])
        }
        var asked = 0
        h.handlers.collect = { _, done in asked += 1; done(["otp": "000000"]) }
        h.start()
        let result = try h.waitForResult(self)
        XCTAssertEqual(asked, 4)
        XCTAssertEqual(h.transport.runCalls.filter { $0.body["fields"] != nil }.count, 4)
        XCTAssertEqual(result.status, .actionRequired)
        XCTAssertEqual(result.pending?.map(\.stepId), [step])
    }

    func testPresentUrlReplacesTheDefaultPresenterAndItsCompletionMeansClosed() throws {
        let h = try LoopHarness("uphold-after-terms-and-details")
        h.transport.reads = try RequirementsFixtures.reads("uphold-after-terms-and-details")
        h.transport.add(try RequirementsFixtures.runs("uphold-after-terms-and-details"))
        var presented: [MeldPresentUrlRequest] = []
        h.handlers.presentUrl = { request, closed in presented.append(request); DispatchQueue.main.async(execute: closed) }
        h.start()
        let result = try h.waitForResult(self)
        XCTAssertEqual(presented.map(\.url.absoluteString), ["https://in.sumsub.com/websdk/p/sbx_fixture_1"])
        XCTAssertEqual(presented.first?.expiresAt, RequirementsFixtures.date("2026-11-04T15:30:00Z"))
        XCTAssertEqual(presented.first?.stepId, meldKyc)
        XCTAssertEqual(String(describing: presented[0]), "[MeldPresentUrlRequest REDACTED]")
        XCTAssertTrue(h.pages.pages.isEmpty)
        XCTAssertEqual(h.transport.runCalls.count, 1, "no refresh after an outcome page")
        XCTAssertEqual(result.status, .actionRequired)
        XCTAssertEqual(result.pending?.map(\.stepId), [meldKyc])
    }

    func testHostedStepIsNotRunnableWithoutAPresenter() throws {
        let h = try LoopHarness("noah-hosted-onboarding")
        h.transport.reads = try RequirementsFixtures.reads("noah-hosted-onboarding")
        h.pages.available = false
        h.start()
        let result = try h.waitForResult(self)
        XCTAssertEqual(result.status, .actionRequired)
        XCTAssertEqual(result.pending?.map(\.kind), ["OPEN_URL"])
        XCTAssertTrue(h.transport.runCalls.isEmpty)
    }

    func testALinkThatAgedBehindThePromptIsRefreshedAndOpenedWithoutASecondPrompt() throws {
        let h = try LoopHarness("noah-hosted-onboarding")
        h.transport.reads = try RequirementsFixtures.reads("noah-hosted-onboarding")
        let runs = try RequirementsFixtures.runs("noah-hosted-onboarding")
        var refreshed = runs[0].response
        refreshed["url"] = "https://onboarding.noah.test/hosted?session=fixture-3"
        refreshed["expiresAt"] = "2026-11-04T17:00:00Z"
        h.transport.runs = [(runs[0].request, runs[0].status, runs[0].response), (runs[0].request, 200, refreshed),
                            (runs[1].request, runs[1].status, runs[1].response)]
        h.pages.beforeOpen = {
            if h.pages.pages.count == 1 { h.clock.current = RequirementsFixtures.date("2026-11-04T15:59:30Z") }
        }
        h.pages.behaviour = .closeAfterOpening
        h.options.waitTimeoutMs = 30_000
        h.start()
        let result = try h.waitForResult(self)
        XCTAssertEqual(h.pages.pages.map(\.url.absoluteString), ["https://onboarding.noah.test/hosted?session=fixture-2",
                                                                 "https://onboarding.noah.test/hosted?session=fixture-3"])
        XCTAssertEqual(h.pages.pages.map(\.prompted), [true, false], "never a second prompt")
        XCTAssertEqual(h.pages.opened.map(\.absoluteString), ["https://onboarding.noah.test/hosted?session=fixture-3"])
        XCTAssertEqual(h.transport.runCalls.count, 3, "before the prompt, behind it, after the close")
        XCTAssertEqual(result.status, .pending)
        XCTAssertTrue(h.transport.unmatched.isEmpty)
    }

    func testA401OnTheRefreshBehindThePromptRenewsAndRefreshesAgainWithoutASecondPrompt() throws {
        var renewedMint = try RequirementsFixtures.mint("noah-hosted-onboarding")
        renewedMint["token"] = "eyJhbGciOiJIUzI1NiJ9.fixture.renewed-session-token"
        let renewed = try MeldRequirementsSession.from(jsonData: JSONSerialization.data(withJSONObject: renewedMint))
        let read = try XCTUnwrap(try RequirementsFixtures.reads("noah-hosted-onboarding").first)
        let runs = try RequirementsFixtures.runs("noah-hosted-onboarding")
        let stepId = try XCTUnwrap(runs[0].request["stepId"] as? String)
        var refreshed = runs[0].response
        refreshed["url"] = "https://onboarding.noah.test/hosted?session=fixture-3"
        refreshed["expiresAt"] = "2026-11-04T17:00:00Z"
        let unauthorized = FixtureTransport.json(401, ["version": 1, "code": "AUTHORIZATION_REQUIRED"])
        let unknown = FixtureTransport.json(503, ["version": 1, "code": "OUTCOME_UNKNOWN"])
        let inFlight = FixtureTransport.json(425, ["version": 1, "code": "OPERATION_IN_FLIGHT"])
        let lost = ActionTransportResult.transportFailed
        // Answers by call number: the 3rd call is the refresh behind the prompt.
        func run(refusing refused: [Int: ActionTransportResult]) throws -> (LoopHarness, MeldReadyResult, Int) {
            let h = try LoopHarness("noah-hosted-onboarding")
            // The step stays offered, so a closed page coming back behind a new prompt would show too.
            h.transport.reads = [read]
            h.transport.runs = [(runs[0].request, runs[0].status, runs[0].response), (runs[0].request, 200, refreshed),
                                (runs[1].request, runs[1].status, runs[1].response)]
            var calls = 0
            h.transport.respond = { _ in calls += 1; return refused[calls] }
            var renewals = 0
            h.handlers.renewSession = { done in renewals += 1; done(renewed) }
            h.pages.beforeOpen = {
                if h.pages.pages.count == 1 { h.clock.current = RequirementsFixtures.date("2026-11-04T15:59:30Z") }
            }
            h.pages.behaviour = .closeAfterOpening
            h.start()
            return (h, try h.waitForResult(self), renewals)
        }

        let cases: [(String, [Int: ActionTransportResult])] = [
            ("401", [3: unauthorized]), ("lost, 401", [3: lost, 4: unauthorized]), ("425, 401", [3: inFlight, 4: unauthorized]),
            ("503, READ 401", [3: unknown, 4: unauthorized]), ("503, READ lost, READ 401", [3: unknown, 4: lost, 5: unauthorized]),
            ("503, resend 401", [3: unknown, 5: unauthorized]),
        ]
        for (name, refused) in cases {
            let (h, result, renewals) = try run(refusing: refused)
            XCTAssertEqual(renewals, 1, name)
            XCTAssertEqual(h.pages.pages.map(\.prompted), [true, false], "never a second prompt: \(name)")
            XCTAssertEqual(h.pages.opened.map(\.absoluteString), ["https://onboarding.noah.test/hosted?session=fixture-3"], name)
            let retry = h.transport.calls[try XCTUnwrap(refused.keys.max())]
            XCTAssertJSONEqual(retry.body, runs[0].request)
            XCTAssertEqual(retry.request.value(forHTTPHeaderField: "Authorization"), "Bearer \(renewedMint["token"]!)", name)
            XCTAssertNotEqual(retry.key, h.transport.calls[2].key, name)
            XCTAssertEqual(result.status, .actionRequired, name)
            XCTAssertEqual(result.pending?.map(\.stepId), [stepId], name)
            XCTAssertTrue(h.transport.unmatched.isEmpty, name)
        }

        let (h, result, renewals) = try run(refusing: [3: unauthorized, 4: unauthorized])
        XCTAssertEqual(renewals, 1)
        XCTAssertEqual(result.status, .expired, "the refresh refused again after the renewal ends the run")
        XCTAssertEqual(h.pages.pages.map(\.prompted), [true])
    }

    func testAnOutcomeLinkThatAgedBehindThePromptOpensAsItIs() throws {
        let h = try LoopHarness("banxa-fresh")
        h.transport.reads = try RequirementsFixtures.reads("banxa-fresh")
        h.transport.add(try RequirementsFixtures.runs("banxa-fresh"))
        h.pages.beforeOpen = { h.clock.current = RequirementsFixtures.date("2026-11-04T15:29:30Z") }
        h.pages.behaviour = .closeAfterOpening
        h.start()
        _ = try h.waitForResult(self)
        XCTAssertEqual(h.pages.opened.map(\.absoluteString), ["https://in.sumsub.com/websdk/p/sbx_fixture_1"])
        XCTAssertEqual(h.transport.runCalls.count, 1, "a SUBMIT outcome has no refresh")
    }

    // MARK: - Errors

    func testTransportFailuresRetryTheSameKeyWithBackoff() throws {
        let h = try LoopHarness("banxa-fresh")
        h.transport.reads = try RequirementsFixtures.reads("banxa-fresh")
        h.transport.add(try RequirementsFixtures.runs("banxa-fresh"))
        var failures = 2
        h.transport.respond = { call in
            guard call.operation == "RUN_STEP", failures > 0 else { return nil }
            failures -= 1
            return .transportFailed
        }
        h.pages.behaviour = .cancelPrompt
        h.start()
        let result = try h.waitForResult(self)
        XCTAssertEqual(h.transport.runCalls.count, 3)
        XCTAssertEqual(Set(h.transport.runCalls.compactMap(\.key)).count, 1, "the same key on every retry")
        XCTAssertEqual(Array(h.clock.delays.prefix(2)), [1000, 2000])
        XCTAssertEqual(h.pages.pages.count, 1)
        XCTAssertEqual(result.status, .actionRequired)
    }

    func testTransportFailureAfterThreeRetriesFails() throws {
        let h = try LoopHarness("banxa-fresh")
        h.transport.reads = try RequirementsFixtures.reads("banxa-fresh")
        h.transport.respond = { $0.operation == "RUN_STEP" ? .transportFailed : nil }
        h.start()
        let result = try h.waitForResult(self)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.error?.kind, .transport)
        XCTAssertEqual(h.transport.runCalls.count, 4)
        XCTAssertEqual(Set(h.transport.runCalls.compactMap(\.key)).count, 1)
        XCTAssertEqual(h.clock.delays, [1000, 2000, 4000])
    }

    func testOperationInFlightRetriesTheSameKey() throws {
        let h = try LoopHarness("banxa-fresh")
        h.transport.reads = try RequirementsFixtures.reads("banxa-fresh")
        h.transport.add(try RequirementsFixtures.runs("banxa-fresh"))
        var busy = true
        h.transport.respond = { call in
            guard call.operation == "RUN_STEP", busy else { return nil }
            busy = false
            return FixtureTransport.json(425, ["version": 1, "code": "OPERATION_IN_FLIGHT"])
        }
        h.pages.behaviour = .cancelPrompt
        h.start()
        _ = try h.waitForResult(self)
        XCTAssertEqual(h.transport.runCalls.count, 2)
        XCTAssertEqual(h.transport.runCalls[0].key, h.transport.runCalls[1].key)
        XCTAssertEqual(h.clock.delays.first, 1000)
    }

    func testOperationInFlightFailsAfterFiveRetries() throws {
        let h = try LoopHarness("banxa-fresh")
        h.transport.reads = try RequirementsFixtures.reads("banxa-fresh")
        h.transport.respond = { $0.operation == "RUN_STEP" ? FixtureTransport.json(425, ["version": 1]) : nil }
        h.start()
        let result = try h.waitForResult(self)
        XCTAssertEqual(h.transport.runCalls.count, 6)
        XCTAssertEqual(Set(h.transport.runCalls.compactMap(\.key)).count, 1)
        XCTAssertEqual(h.clock.delays, Array(repeating: 1000, count: 5))
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.error?.kind, .http)
        XCTAssertEqual(result.error?.status, 425)
        XCTAssertEqual(result.error?.code, "OPERATION_IN_FLIGHT")
    }

    private static let outcomeUnknown = FixtureTransport.json(503, ["version": 1, "code": "OUTCOME_UNKNOWN"])

    func testOutcomeUnknownOnASubmitReadsAndEndsActionRequiredWithoutSendingItAgain() throws {
        let h = try LoopHarness("banxa-fresh")
        h.transport.reads = [try XCTUnwrap(try RequirementsFixtures.reads("banxa-fresh").first)]
        h.transport.respond = { $0.operation == "RUN_STEP" ? Self.outcomeUnknown : nil }
        h.start()
        let result = try h.waitForResult(self)
        XCTAssertEqual(h.transport.operations, ["READ", "RUN_STEP", "READ"])
        XCTAssertEqual(result.status, .actionRequired)
        XCTAssertEqual(result.pending?.map(\.stepId), [meldKyc])
        XCTAssertNil(result.error)
        XCTAssertTrue(h.pages.pages.isEmpty, "no page opens")
    }

    func testOutcomeUnknownGoesOnWhenTheReadShowsTheStepLanded() throws {
        let offered = try XCTUnwrap(try RequirementsFixtures.reads("banxa-fresh").first)
        var landed = RequirementsFixtures.read(offered, without: [meldKyc])
        landed["status"] = "READY"
        let h = try LoopHarness("banxa-fresh")
        h.transport.reads = [offered, landed]
        h.transport.respond = { $0.operation == "RUN_STEP" ? Self.outcomeUnknown : nil }
        h.start()
        let result = try h.waitForResult(self)
        XCTAssertEqual(h.transport.operations, ["READ", "RUN_STEP", "READ"])
        XCTAssertEqual(result.status, .ready)
        XCTAssertNil(result.error)
    }

    func testOutcomeUnknownOnCollectedValuesEndsActionRequiredWithoutSendingThemAgain() throws {
        let h = try LoopHarness("uphold-fresh")
        h.transport.reads = [try onlyStep(email, of: "uphold-fresh")]
        h.transport.respond = { $0.operation == "RUN_STEP" ? Self.outcomeUnknown : nil }
        var asked = 0
        h.handlers.collect = { _, done in asked += 1; done(["email": "ada@example.com"]) }
        h.start()
        let result = try h.waitForResult(self)
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(h.transport.operations, ["READ", "RUN_STEP", "READ"])
        XCTAssertEqual(result.status, .actionRequired)
        XCTAssertEqual(result.pending?.map(\.stepId), [email])
    }

    func testOutcomeUnknownOnAnAcceptanceEndsActionRequiredWithoutSendingItAgain() throws {
        let h = try LoopHarness("uphold-fresh")
        h.transport.reads = [try onlyStep(upholdTerms, of: "uphold-fresh")]
        h.transport.respond = { $0.operation == "RUN_STEP" ? Self.outcomeUnknown : nil }
        var asked = 0
        h.handlers.confirmAgreement = { _, done in asked += 1; done(true) }
        h.start()
        let result = try h.waitForResult(self)
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(h.transport.operations, ["READ", "RUN_STEP", "READ"])
        XCTAssertEqual(result.status, .actionRequired)
        XCTAssertEqual(result.pending?.map(\.stepId), [upholdTerms])
    }

    private func verifyContactRead() throws -> (stepId: String, read: [String: Any]) {
        let step = "*:VERIFICATION:EMAIL"
        let read = try onlyStep(email, of: "uphold-fresh", changing: {
            $0 = ["stepId": step, "kind": "VERIFY_CONTACT", "type": "VERIFICATION", "code": "EMAIL", "serviceProviders": ["UPHOLD"]]
        })
        return (step, read)
    }

    func testOutcomeUnknownOnSendingACodeEndsActionRequiredWithoutSendingAnother() throws {
        let (step, read) = try verifyContactRead()
        let h = try LoopHarness("uphold-fresh")
        h.transport.reads = [read]
        h.transport.respond = { $0.operation == "RUN_STEP" ? Self.outcomeUnknown : nil }
        var asked = 0
        h.handlers.collect = { _, done in asked += 1; done(["otp": "123456"]) }
        h.start()
        let result = try h.waitForResult(self)
        XCTAssertEqual(asked, 0, "no code was confirmed sent, so none is asked for")
        XCTAssertEqual(h.transport.operations, ["READ", "RUN_STEP", "READ"])
        XCTAssertEqual(result.status, .actionRequired)
        XCTAssertEqual(result.pending?.map(\.stepId), [step])
    }

    func testOutcomeUnknownOnConfirmingACodeEndsActionRequiredWithoutSendingItAgain() throws {
        let (step, read) = try verifyContactRead()
        let h = try LoopHarness("uphold-fresh")
        h.transport.reads = [read]
        h.transport.respond = { call in
            guard call.operation == "RUN_STEP" else { return nil }
            guard call.body["fields"] != nil else {
                return FixtureTransport.json(200, ["version": 1, "stepId": step, "outcome": "COLLECT", "fields": [["key": "otp"]],
                                                   "continuation": "vrf_1"])
            }
            return Self.outcomeUnknown
        }
        var asked = 0
        h.handlers.collect = { _, done in asked += 1; done(["otp": "123456"]) }
        h.start()
        let result = try h.waitForResult(self)
        XCTAssertEqual(asked, 1, "no second code is sent or asked for")
        XCTAssertEqual(h.transport.operations, ["READ", "RUN_STEP", "RUN_STEP", "READ"])
        XCTAssertJSONEqual(h.transport.runCalls[1].body, ["version": 1, "operation": "RUN_STEP", "stepId": step,
                                                          "fields": ["otp": "123456"], "continuation": "vrf_1"])
        XCTAssertEqual(result.status, .actionRequired)
        XCTAssertEqual(result.pending?.map(\.stepId), [step])
    }

    func testOutcomeUnknownThenA401OnTheReadEndsActionRequiredOnTheRenewedSessionWithoutSendingItAgain() throws {
        let h = try LoopHarness("banxa-fresh")
        h.transport.reads = [try XCTUnwrap(try RequirementsFixtures.reads("banxa-fresh").first)]
        var calls = 0
        h.transport.respond = { _ in
            calls += 1
            switch calls {
            case 2: return Self.outcomeUnknown
            case 3: return FixtureTransport.json(401, ["version": 1, "code": "AUTHORIZATION_REQUIRED"])
            default: return nil
            }
        }
        var renewals = 0
        h.handlers.renewSession = { done in renewals += 1; done(h.session) }
        h.start()
        let result = try h.waitForResult(self)
        XCTAssertEqual(renewals, 1)
        XCTAssertEqual(h.transport.operations, ["READ", "RUN_STEP", "READ", "READ"])
        XCTAssertEqual(result.status, .actionRequired)
        XCTAssertEqual(result.pending?.map(\.stepId), [meldKyc])
    }

    func testOutcomeUnknownOnAPageRefreshIsResentWithANewKeyAtMostThreeTimes() throws {
        let h = try LoopHarness("noah-hosted-onboarding")
        let read = try XCTUnwrap(try RequirementsFixtures.reads("noah-hosted-onboarding").first)
        h.transport.reads = [read]
        h.transport.respond = { $0.operation == "RUN_STEP" ? Self.outcomeUnknown : nil }
        h.start()
        let result = try h.waitForResult(self)
        XCTAssertEqual(h.transport.operations, Array(repeating: ["READ", "RUN_STEP"], count: 4).flatMap { $0 } + ["READ"],
                       "the fourth is read first too")
        XCTAssertEqual(Set(h.transport.runCalls.compactMap(\.key)).count, 4, "a new key on every resend")
        XCTAssertTrue(h.transport.runCalls.allSatisfy { $0.body["refresh"] as? Bool == true }, "only the refresh is resent")
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.error?.status, 503)
        XCTAssertEqual(result.error?.code, "OUTCOME_UNKNOWN")
    }

    func testExpiredSessionIsRenewedOrEndsExpired() throws {
        let mint = try RequirementsFixtures.mint("unknown-step")
        var renewedMint = mint
        renewedMint["token"] = "eyJhbGciOiJIUzI1NiJ9.fixture.renewed-session-token"
        let renewed = try MeldRequirementsSession.from(jsonData: JSONSerialization.data(withJSONObject: renewedMint))
        let read = try XCTUnwrap(try RequirementsFixtures.reads("unknown-step").first)
        let unauthorized = { (call: FixtureTransport.Call) -> ActionTransportResult? in
            call.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(mint["token"]!)"
                ? FixtureTransport.json(401, ["version": 1, "code": "AUTHORIZATION_REQUIRED"]) : nil
        }

        let h = try LoopHarness("unknown-step")
        h.transport.reads = [read]
        h.transport.respond = unauthorized
        var renewals = 0
        h.handlers.renewSession = { done in renewals += 1; done(renewed) }
        h.start()
        let result = try h.waitForResult(self)
        XCTAssertEqual(result.status, .undetermined)
        XCTAssertEqual(renewals, 1)
        XCTAssertEqual(h.transport.calls.last?.request.value(forHTTPHeaderField: "Authorization"),
                       "Bearer eyJhbGciOiJIUzI1NiJ9.fixture.renewed-session-token")

        let without = try LoopHarness("unknown-step")
        without.transport.respond = unauthorized
        without.start()
        XCTAssertEqual(try without.waitForResult(self).status, .expired)

        let stale = try LoopHarness("unknown-step")
        stale.transport.respond = unauthorized
        stale.handlers.renewSession = { done in done(stale.session) }
        stale.start()
        XCTAssertEqual(try stale.waitForResult(self).status, .expired, "a renewal that is refused again ends")

        let declined = try LoopHarness("unknown-step")
        declined.transport.respond = unauthorized
        declined.handlers.renewSession = { $0(nil) }
        declined.start()
        XCTAssertEqual(try declined.waitForResult(self).status, .expired)
    }

    func testRenewSessionIsAskedAtMostThreeTimesPerRun() throws {
        let h = try LoopHarness("banxa-fresh")
        h.transport.reads = try RequirementsFixtures.reads("banxa-fresh")
        h.transport.add(try RequirementsFixtures.runs("banxa-fresh"))
        var refused = 0
        h.transport.respond = { call in
            guard call.operation == "RUN_STEP", refused < 4 else { return nil }
            refused += 1
            return FixtureTransport.json(401, ["version": 1, "code": "AUTHORIZATION_REQUIRED"])
        }
        var renewals = 0
        h.handlers.renewSession = { done in renewals += 1; done(h.session) }
        h.pages.behaviour = .cancelPrompt
        h.start()
        let result = try h.waitForResult(self)
        XCTAssertEqual(renewals, 3)
        XCTAssertEqual(result.status, .expired)
        XCTAssertEqual(h.transport.operations, Array(repeating: ["READ", "RUN_STEP"], count: 4).flatMap { $0 })
    }

    func testASessionFromAnotherEnvironmentGoesToTheConfiguredOneAndEndsExpired() throws {
        let h = try LoopHarness("unknown-step")
        h.environment = .production
        h.transport.respond = { _ in FixtureTransport.json(401, ["version": 1, "code": "AUTHORIZATION_REQUIRED"]) }
        var renewals = 0
        h.handlers.renewSession = { done in renewals += 1; done(h.session) }
        h.start()
        let result = try h.waitForResult(self)
        XCTAssertEqual(h.transport.calls.map { $0.request.url?.host }, ["api.meld.io", "api.meld.io"])
        XCTAssertEqual(renewals, 1)
        XCTAssertEqual(result.status, .expired)
        XCTAssertNil(result.error)
    }

    func testOtherHttpErrorsAndUnreadableResponsesFail() throws {
        let h = try LoopHarness("banxa-fresh")
        h.transport.reads = try RequirementsFixtures.reads("banxa-fresh")
        h.transport.respond = { $0.operation == "RUN_STEP"
            ? FixtureTransport.json(502, ["version": 1, "code": "PROVIDER_UNAVAILABLE", "message": "synthetic-private"]) : nil }
        h.start()
        let http = try h.waitForResult(self)
        XCTAssertEqual(http.status, .failed)
        XCTAssertEqual(http.error?.kind, .http)
        XCTAssertEqual(http.error?.status, 502)
        XCTAssertEqual(http.error?.code, "PROVIDER_UNAVAILABLE")

        for body: Any in [["version": 1], ["version": 2, "status": "READY"], "not json"] {
            let broken = try LoopHarness("banxa-fresh")
            broken.transport.respond = { _ in
                .response(status: 200, body: (body as? String).map { Data($0.utf8) } ?? (try? JSONSerialization.data(withJSONObject: body)))
            }
            broken.start()
            let result = try broken.waitForResult(self)
            XCTAssertEqual(result.status, .failed)
            XCTAssertEqual(result.error?.kind, .protocol)
        }

        let wrongStep = try LoopHarness("banxa-fresh")
        wrongStep.transport.reads = try RequirementsFixtures.reads("banxa-fresh")
        wrongStep.transport.respond = { $0.operation == "RUN_STEP"
            ? FixtureTransport.json(200, ["version": 1, "stepId": "BANXA:OTHER:STEP", "outcome": "DONE"]) : nil }
        wrongStep.start()
        XCTAssertEqual(try wrongStep.waitForResult(self).error?.kind, .protocol)
    }

    func testTheSameStepWithNoChangeAfterTheSettleWindowIsActionRequired() throws {
        let h = try LoopHarness("banxa-fresh")
        h.transport.reads = try RequirementsFixtures.reads("banxa-fresh")
        h.transport.respond = { $0.operation == "RUN_STEP"
            ? FixtureTransport.json(200, ["version": 1, "stepId": "*:MELD_KYC:MELD_KYC_APPROVED", "outcome": "DONE"]) : nil }
        h.start()
        let result = try h.waitForResult(self)
        XCTAssertEqual(h.transport.runCalls.count, 1)
        XCTAssertEqual(result.status, .actionRequired)
        XCTAssertEqual(result.pending?.map(\.stepId), [meldKyc])
        XCTAssertGreaterThanOrEqual(h.clock.delays.reduce(0, +), RequirementsLoop.settleWindowMs)
    }

    // MARK: - Cancel

    func testCancelAbortsTheRequestInFlightAndNothingFollows() throws {
        let h = try LoopHarness("banxa-fresh")
        h.transport.hold = true
        let loop = h.start()
        h.spin { !h.transport.held.isEmpty }
        loop.cancel()
        XCTAssertEqual(h.transport.held.map(\.0.cancelled), [true], "the request in flight is aborted")
        let result = try h.waitForResult(self)
        XCTAssertEqual(result.status, .cancelled)
        XCTAssertEqual(h.transport.finished, 1)
        h.transport.release(FixtureTransport.json(200, try XCTUnwrap(try RequirementsFixtures.reads("banxa-fresh").first)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(h.results.count, 1)
        XCTAssertEqual(h.transport.operations, ["READ"])
    }

    func testCancelWhileCollectingIgnoresTheLateAnswer() throws {
        let h = try LoopHarness("uphold-fresh")
        h.transport.reads = [try onlyStep(email, of: "uphold-fresh")]
        var answer: (([String: String]?) -> Void)?
        h.handlers.collect = { answer = $1 }
        let loop = h.start()
        h.spin { answer != nil }
        loop.cancel()
        answer?(["email": "ada@example.com"])
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(try h.waitForResult(self).status, .cancelled)
        XCTAssertTrue(h.transport.runCalls.isEmpty)
    }

    func testCancelInsideOnProgressSendsNothingMore() throws {
        for (state, sent) in [(MeldReadyProgress.State.reading, [String]()), (.running, ["READ"])] {
            let h = try LoopHarness("banxa-fresh")
            h.transport.reads = try RequirementsFixtures.reads("banxa-fresh")
            h.transport.add(try RequirementsFixtures.runs("banxa-fresh"))
            h.handlers.onProgress = { [weak h] in if $0.state == state { h?.loop?.cancel() } }
            h.start()
            XCTAssertEqual(try h.waitForResult(self).status, .cancelled, state.rawValue)
            XCTAssertEqual(h.transport.operations, sent, state.rawValue)
            XCTAssertEqual(h.transport.postsAfterFinish, 0, "nothing is sent on the closed transport")
        }
    }

    func testNoHandlerOrPageRunsAfterCancelInsideOnProgress() throws {
        var called: [String] = []
        let collecting = try LoopHarness("uphold-fresh")
        collecting.transport.reads = [try onlyStep(email, of: "uphold-fresh")]
        collecting.handlers.collect = { _, _ in called.append("collect") }
        let agreeing = try LoopHarness("uphold-fresh")
        agreeing.transport.reads = [try onlyStep(upholdTerms, of: "uphold-fresh")]
        agreeing.handlers.confirmAgreement = { _, _ in called.append("confirmAgreement") }
        let presenting = try LoopHarness("banxa-fresh")
        let presentingUrl = try LoopHarness("banxa-fresh")
        for h in [presenting, presentingUrl] {
            h.transport.reads = try RequirementsFixtures.reads("banxa-fresh")
            h.transport.add(try RequirementsFixtures.runs("banxa-fresh"))
        }
        presentingUrl.handlers.presentUrl = { _, _ in called.append("presentUrl") }
        let renewing = try LoopHarness("unknown-step")
        renewing.transport.respond = { _ in FixtureTransport.json(401, ["version": 1, "code": "AUTHORIZATION_REQUIRED"]) }
        renewing.handlers.renewSession = { _ in called.append("renewSession") }
        let runs: [(LoopHarness, MeldReadyProgress.State)] = [(collecting, .awaitingInput), (agreeing, .awaitingInput),
                                                             (presenting, .presenting), (presentingUrl, .presenting),
                                                             (renewing, .awaitingInput)]
        for (h, state) in runs {
            h.handlers.onProgress = { [weak h] in if $0.state == state { h?.loop?.cancel() } }
            h.start()
            XCTAssertEqual(try h.waitForResult(self).status, .cancelled)
        }
        XCTAssertEqual(called, [])
        XCTAssertTrue(presenting.pages.pages.isEmpty, "no prompt for a run that ended")
    }

    // MARK: - Snapshot

    func testFingerprintIgnoresExpiryLinksAndThePollIntervalOnly() throws {
        let read = try XCTUnwrap(try RequirementsFixtures.reads("noah-hosted-onboarding").first)
        var later = RequirementsFixtures.read(try XCTUnwrap(relinked(read) as? [String: Any]),
                                              changing: "NOAH:EXTERNAL_KYC:NOAH_HOSTED_ONBOARDING") {
            $0["expiresAt"] = "2026-11-04T16:00:00Z"
        }
        later["pollAfterMs"] = 15000
        later["expiresAt"] = "2026-11-04T16:28:30Z"
        XCTAssertEqual(try RequirementsSnapshot(read).fingerprint, try RequirementsSnapshot(later).fingerprint)
        let changed = RequirementsFixtures.read(read, changing: "NOAH:EXTERNAL_KYC:NOAH_HOSTED_ONBOARDING") {
            $0["reason"] = "RESUBMISSION_REQUESTED"
        }
        XCTAssertNotEqual(try RequirementsSnapshot(read).fingerprint, try RequirementsSnapshot(changed).fingerprint)
    }

    func testErrorCodesAreKeptOnlyAsANonEmptyListOfStrings() throws {
        let read = try XCTUnwrap(try RequirementsFixtures.reads("coinme-share-refused").first)
        func share(_ codes: Any?) throws -> MeldReadyRequirement {
            var copy = read
            var providers = try XCTUnwrap(copy["providers"] as? [[String: Any]])
            var requirements = try XCTUnwrap(providers[0]["requirements"] as? [[String: Any]])
            requirements[3]["errorCodes"] = codes
            providers[0]["requirements"] = requirements
            copy["providers"] = providers
            return try XCTUnwrap(try RequirementsSnapshot(copy).providers.first?.open.first)
        }
        XCTAssertEqual(try share(["PHONE_VERIFICATION_REQUIRED", "NEWER_CODE"]).errorCodes, ["PHONE_VERIFICATION_REQUIRED", "NEWER_CODE"])
        for codes: Any? in [nil, NSNull(), [String](), "PHONE_VERIFICATION_REQUIRED", ["PHONE_VERIFICATION_REQUIRED", 7], ["code": "X"]] {
            let refused = try share(codes)
            XCTAssertNil(refused.errorCodes, "\(String(describing: codes))")
            XCTAssertEqual(refused.reason, "Coinme needs the customer's phone verified first")
            XCTAssertEqual(refused.status, "BLOCKED")
        }
    }

    func testContinuationListsOrderContinuationStepsAndOpenListsPreOrderOnes() throws {
        var read = try XCTUnwrap(try RequirementsFixtures.reads("unknown-step").first)
        var providers = try XCTUnwrap(read["providers"] as? [[String: Any]])
        var requirements = try XCTUnwrap(providers[0]["requirements"] as? [[String: Any]])
        requirements.append(["type": "PROVIDER_PROCESS", "code": "IDENTITY_CHECK", "status": "REQUIRED",
                             "timing": "ORDER_CONTINUATION", "action": ["type": "SDK_STEP", "nextStep": "SDK_VERIFY_IDENTITY"]])
        providers[0]["requirements"] = requirements
        read["providers"] = providers
        let snapshot = try RequirementsSnapshot(read)
        XCTAssertEqual(snapshot.continuation.map(\.code), ["IDENTITY_CHECK"])
        XCTAssertEqual(snapshot.continuation.first?.serviceProvider, "BANXA")
        XCTAssertEqual(snapshot.continuation.first?.nextStep, "SDK_VERIFY_IDENTITY")
        XCTAssertFalse(snapshot.providers[0].open.contains { $0.code == "IDENTITY_CHECK" })
        XCTAssertEqual(String(describing: snapshot.next.first ?? MeldReadyStep(stepId: "a", kind: "SUBMIT", type: "t", code: "c",
            serviceProviders: [], level: nil, url: "https://x.test", expiresAt: nil, fields: nil, reason: nil)), "[MeldReadyStep REDACTED]")
    }

    // MARK: - Default presenter

    func testDefaultPresenterOpensOnlyAfterContinueAndDismissesWhenTheStepLeaves() throws {
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        let root = UIViewController(), window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let pages = RecordingPages(HostedPages(anchor: root))
        let h = try LoopHarness("banxa-fresh")
        h.clock.manual = true
        h.transport.reads = try RequirementsFixtures.reads("banxa-fresh") + RequirementsFixtures.reads("waiting-on-meld-kyc")
        let run = try XCTUnwrap(try RequirementsFixtures.runs("banxa-fresh").first)
        var response = run.response
        response["url"] = "https://meld.invalid/hosted"
        h.transport.runs = [(run.request, run.status, response)]
        let loop = RequirementsLoop(session: h.session, environment: .sandbox, handlers: MeldReadyHandlers(),
                                    options: MeldReadyOptions(), pages: pages, clock: h.clock,
                                    transport: { [transport = h.transport] in transport }, onResult: { _ in })
        loop.start()
        h.spin { root.presentedViewController is UIAlertController }
        XCTAssertTrue(root.presentedViewController is UIAlertController, "the prompt comes first")
        XCTAssertTrue(pages.opened.isEmpty)
        let presenter = try XCTUnwrap(pages.presented.first)
        presenter.proceed()
        h.spin { root.presentedViewController is SFSafariViewController }
        XCTAssertTrue(root.presentedViewController is SFSafariViewController, "opened after Continue")
        XCTAssertEqual(pages.opened, [URL(string: "https://meld.invalid/hosted")!])
        XCTAssertTrue(h.clock.fireNext(), "the background READ")
        h.spin { root.presentedViewController == nil }
        XCTAssertNil(root.presentedViewController, "dismissed when the step left next[]")
        loop.cancel()
    }

    func testAHostedPageThatFailsToLoadClosesAndIsRefreshedOnce() throws {
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        let root = UIViewController(), window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let pages = RecordingPages(HostedPages(anchor: root))
        let h = try LoopHarness("noah-hosted-onboarding")
        h.clock.manual = true
        h.transport.reads = try RequirementsFixtures.reads("noah-hosted-onboarding")
        var runs = try RequirementsFixtures.runs("noah-hosted-onboarding")
        var refreshed = runs[0].response
        refreshed["url"] = "https://meld.invalid/onboarding"
        h.transport.runs = [(runs[0].request, runs[0].status, refreshed)]
        runs.removeFirst()
        h.transport.add(runs)
        let loop = RequirementsLoop(session: h.session, environment: .sandbox, handlers: MeldReadyHandlers(),
                                    options: MeldReadyOptions(), pages: pages, clock: h.clock,
                                    transport: { [transport = h.transport] in transport }, onResult: { _ in })
        loop.start()
        h.spin { root.presentedViewController is UIAlertController }
        try XCTUnwrap(pages.presented.first).proceed()
        h.spin { root.presentedViewController is SFSafariViewController }
        let safari = try XCTUnwrap(root.presentedViewController as? SFSafariViewController)
        try XCTUnwrap(pages.presented.first).safariViewController(safari, didCompleteInitialLoad: false)
        h.spin { root.presentedViewController == nil && h.transport.runCalls.count == 2 }
        XCTAssertNil(root.presentedViewController)
        XCTAssertEqual(h.transport.runCalls.count, 2, "one refresh before opening, one after the failed load")
        h.spin { h.transport.operations.last == "READ" && h.clock.live.count == 1 }
        XCTAssertTrue(h.transport.unmatched.isEmpty)
        loop.cancel()
    }

    func testDefaultPresenterOpensTheRefreshOfAnAgedLinkWithoutASecondPrompt() throws {
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        let root = UIViewController(), window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let pages = RecordingPages(HostedPages(anchor: root))
        let h = try LoopHarness("noah-hosted-onboarding")
        h.clock.manual = true
        h.transport.reads = try RequirementsFixtures.reads("noah-hosted-onboarding")
        let run = try XCTUnwrap(try RequirementsFixtures.runs("noah-hosted-onboarding").first)
        var aging = run.response, refreshed = run.response
        aging["url"] = "https://meld.invalid/aging"
        refreshed["url"] = "https://meld.invalid/refreshed"
        refreshed["expiresAt"] = "2026-11-04T17:00:00Z"
        h.transport.runs = [(run.request, run.status, aging), (run.request, run.status, refreshed)]
        let loop = RequirementsLoop(session: h.session, environment: .sandbox, handlers: MeldReadyHandlers(),
                                    options: MeldReadyOptions(), pages: pages, clock: h.clock,
                                    transport: { [transport = h.transport] in transport }, onResult: { _ in })
        loop.start()
        h.spin { root.presentedViewController is UIAlertController }
        h.clock.current = RequirementsFixtures.date("2026-11-04T15:59:30Z")
        try XCTUnwrap(pages.presented.first).proceed()
        h.spin { root.presentedViewController is SFSafariViewController }
        XCTAssertTrue(root.presentedViewController is SFSafariViewController, "opened with no second Continue")
        XCTAssertEqual(pages.opened, [URL(string: "https://meld.invalid/refreshed")!])
        XCTAssertEqual(pages.presented.count, 2)
        XCTAssertEqual(h.transport.runCalls.count, 2)
        loop.cancel()
        h.spin { root.presentedViewController == nil }
    }

    func testOpenHostedVerificationClosesOnceAndRefusesNonHttps() throws {
        let pages = FixturePages()
        pages.behaviour = .closeAfterOpening
        var closed = 0
        HostedVerification.open(URL(string: "https://verify.example.test/session")!, pages: pages) { closed += 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(closed, 1)
        XCTAssertEqual(pages.opened.map(\.absoluteString), ["https://verify.example.test/session"])

        var refused = 0
        Meld.openHostedVerification(url: URL(string: "http://verify.example.test/session")!) { refused += 1 }
        XCTAssertEqual(refused, 0, "after the call returns")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(refused, 1)
    }

    func testEnsureReadyResolvesAfterReturningAndRefusesAnAbsoluteEndpointOnAnotherHost() throws {
        var mint = try RequirementsFixtures.mint("banxa-fresh")
        var actions = try XCTUnwrap(mint["requirementsActions"] as? [String: Any])
        actions["endpoint"] = "https://api.meld.io" + (actions["endpoint"] as? String ?? "")
        mint["requirementsActions"] = actions
        let session = try MeldRequirementsSession.from(jsonData: JSONSerialization.data(withJSONObject: mint))
        let previous = Meld.environment
        Meld.configure(environment: .sandbox)
        defer { Meld.configure(environment: previous) }
        var results: [MeldReadyResult] = []
        Meld.ensureReady(session: session, handlers: MeldReadyHandlers()) { results.append($0) }
        XCTAssertTrue(results.isEmpty)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(results.map(\.status), [.failed])
        XCTAssertEqual(results.first?.error?.kind, .protocol)
    }

    private static let renewedToken = "eyJhbGciOiJIUzI1NiJ9.fixture.renewed-session-token"

    /// Noah's hosted page closed unfinished, with the calls from the refresh after the close (0) answered by `refused`.
    /// The step stays offered and every later refresh answers a fresh link, so a page opened again would show.
    private func closeRefresh(refusing refused: [Int: ActionTransportResult], presentUrl: Bool = false) throws
        -> (harness: LoopHarness, result: MeldReadyResult, refresh: Int, renewals: Int, presented: Int) {
        var renewedMint = try RequirementsFixtures.mint("noah-hosted-onboarding")
        renewedMint["token"] = Self.renewedToken
        let renewed = try MeldRequirementsSession.from(jsonData: JSONSerialization.data(withJSONObject: renewedMint))
        let runs = try RequirementsFixtures.runs("noah-hosted-onboarding")
        var refreshed = runs[0].response
        refreshed["url"] = "https://onboarding.noah.test/hosted?session=fixture-3"
        refreshed["expiresAt"] = "2026-11-04T17:00:00Z"
        let h = try LoopHarness("noah-hosted-onboarding")
        h.transport.reads = [try XCTUnwrap(try RequirementsFixtures.reads("noah-hosted-onboarding").first)]
        h.transport.runs = [(runs[0].request, runs[0].status, runs[0].response), (runs[1].request, 200, refreshed),
                            (runs[1].request, 200, refreshed)]
        var calls = 0, runSteps = 0, refresh: Int?
        h.transport.respond = { call in
            calls += 1
            if call.operation == "RUN_STEP" { runSteps += 1 }
            if refresh == nil, runSteps == 2 { refresh = calls - 1 }
            return refresh.flatMap { refused[calls - 1 - $0] }
        }
        var presented = 0
        if presentUrl { h.handlers.presentUrl = { _, closed in presented += 1; DispatchQueue.main.async(execute: closed) } }
        var renewals = 0
        h.handlers.renewSession = { done in renewals += 1; done(renewed) }
        h.pages.behaviour = .closeAfterOpening
        h.start()
        let result = try h.waitForResult(self)
        return (h, result, try XCTUnwrap(refresh), renewals, presented)
    }

    /// The same JSON with every `url` rotated, as a refresh leaves it.
    private func relinked(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.reduce(into: [String: Any]()) { $0[$1.key] = $1.key == "url" ? "\($1.value)-rotated" : relinked($1.value) }
        }
        if let array = value as? [Any] { return array.map(relinked) }
        return value
    }

    private func onlyStep(_ stepId: String, of fixture: String, changing: ((inout [String: Any]) -> Void)? = nil) throws -> [String: Any] {
        var read = try XCTUnwrap(try RequirementsFixtures.reads(fixture).first)
        read["next"] = (read["next"] as? [[String: Any]] ?? []).filter { $0["stepId"] as? String == stepId }
        if let changing { read = RequirementsFixtures.read(read, changing: stepId, changing) }
        return read
    }
}

private final class RecordingPages: RequirementsPages {
    let pages: HostedPages
    var presented: [HostedVerificationPresenter] = []
    var opened: [URL] = []
    init(_ pages: HostedPages) { self.pages = pages }
    var available: Bool { pages.available }
    func present(_ url: URL, prompted: Bool, onOpen: @escaping () -> Bool,
                 onClose: @escaping (Bool) -> Void) throws -> MeldProviderSession {
        let session = try pages.present(url, prompted: prompted, onOpen: { [weak self] in
            let open = onOpen()
            if open { self?.opened.append(url) }
            return open
        }, onClose: onClose)
        if let presenter = session as? HostedVerificationPresenter { presented.append(presenter) }
        return session
    }
}
