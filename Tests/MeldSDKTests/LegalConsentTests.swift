import Foundation
import UIKit
import XCTest
@testable import MeldSDK

enum LegalConsentFixtures {
    static let code = "IDENTITY_DATA_SHARING"
    static let digest = String(repeating: "a", count: 64)
    static let disclosure: [String: Any] = ["requirementCode": code, "title": "Synthetic disclosure",
        "documentVersion": "v1", "locale": "en-US", "text": "Synthetic test-only copy.", "documentDigest": digest]
    static func receipt(_ key: UUID = UUID(), result: String = "ACCEPTED") -> [String: Any] {
        ["id": key.uuidString, "requirementCode": code, "documentVersion": "v1", "locale": "en-US",
         "documentDigest": digest, "result": result, "recordedAt": "2026-09-18T10:00:00.123456Z"]
    }
    static func read(_ receipt: [String: Any]? = nil) -> [String: Any] {
        var legal: [String: Any] = ["disclosure": disclosure]
        if let receipt { legal["receipt"] = receipt }
        return ["version": 1, "status": "READY", "nextStep": "COLLECT_LEGAL_EVIDENCE", "legal": legal]
    }
    static func recorded(_ receipt: [String: Any]) -> [String: Any] {
        ["version": 1, "status": receipt["result"] as? String == "ACCEPTED" ? "AUTHORIZED" : "REJECTED",
         "nextStep": "NONE", "legal": ["receipt": receipt]]
    }
}

@MainActor
final class LegalConsentTests: XCTestCase {
    func testDisclosureViewShowsExactCopyAndMakesNoDecisionBeforeAnExplicitTap() throws {
        let disclosure = try LegalDisclosure(LegalConsentFixtures.disclosure, code: LegalConsentFixtures.code)
        var decisions: [Bool] = []
        let view = LegalDisclosureViewController(disclosure: disclosure) { result in
            if case .success(let accepted) = result { decisions.append(accepted) }
        }
        view.loadViewIfNeeded()
        let copy = try XCTUnwrap(view.view.subviews.compactMap { $0 as? UITextView }.first)
        XCTAssertEqual(copy.text, disclosure.text)
        XCTAssertEqual(copy.accessibilityLanguage, disclosure.locale)
        XCTAssertFalse(copy.isEditable)
        XCTAssertTrue(decisions.isEmpty)
        let buttons = try XCTUnwrap(view.view.subviews.compactMap { $0 as? UIStackView }.first)
        let accept = try XCTUnwrap(buttons.arrangedSubviews.first as? UIButton)
        accept.sendActions(for: .touchUpInside)
        view.cancel()
        XCTAssertEqual(decisions, [true])
    }

    func testAcceptanceRequiresMatchingDurableReceiptAndSendsOnlyMetadata() async throws {
        var calls: [String] = []
        try await LegalConsent.require(LegalConsentFixtures.code, store: MemoryLegalDecisionStore(), send: { operation, fields, key in
            calls.append(operation)
            XCTAssertEqual(fields["legalRequirementCode"] as? String, LegalConsentFixtures.code)
            if operation == "READ_LEGAL_DISCLOSURE" { XCTAssertNil(key); return LegalConsentFixtures.read() }
            XCTAssertNotNil(key)
            let evidence = try XCTUnwrap(fields["legalEvidence"] as? [String: Any])
            XCTAssertEqual(Set(evidence.keys), Set(["documentVersion", "locale", "documentDigest", "result"]))
            XCTAssertEqual(evidence["result"] as? String, "ACCEPTED")
            return LegalConsentFixtures.recorded(LegalConsentFixtures.receipt(key!))
        }, present: { disclosure in
            XCTAssertEqual(calls, ["READ_LEGAL_DISCLOSURE"])
            XCTAssertEqual(disclosure.text, "Synthetic test-only copy.")
            return true
        }, check: {})
        XCTAssertEqual(calls, ["READ_LEGAL_DISCLOSURE", "RECORD_LEGAL_EVIDENCE"])
    }

    func testCurrentAcceptedReceiptResumesWithoutPresentingOrWritingAgain() async throws {
        var calls = 0
        try await LegalConsent.require(LegalConsentFixtures.code, store: MemoryLegalDecisionStore(), send: { _, _, _ in
            calls += 1; return LegalConsentFixtures.read(LegalConsentFixtures.receipt())
        }, present: { _ in XCTFail("Receipt already accepted"); return true }, check: {})
        XCTAssertEqual(calls, 1)
    }

    func testDeclineIsRecordedAndCannotAuthorizeCollection() async throws {
        do {
            try await LegalConsent.require(LegalConsentFixtures.code, store: MemoryLegalDecisionStore(), send: { operation, _, key in
                if operation == "READ_LEGAL_DISCLOSURE" { return LegalConsentFixtures.read() }
                return LegalConsentFixtures.recorded(LegalConsentFixtures.receipt(key!, result: "DECLINED"))
            }, present: { _ in false }, check: {})
            XCTFail("Decline must stop collection")
        } catch LegalConsentError.declined {}
    }

    func testFailedOrMismatchedWritesNeverAuthorizeCollection() async throws {
        for invalid in 0..<5 {
            do {
                try await LegalConsent.require(LegalConsentFixtures.code, store: MemoryLegalDecisionStore(), send: { operation, _, key in
                    if operation == "READ_LEGAL_DISCLOSURE" { return LegalConsentFixtures.read() }
                    if invalid == 0 { throw PaymentActionError.transport }
                    var receipt = LegalConsentFixtures.receipt(key!)
                    if invalid == 1 { receipt["id"] = UUID().uuidString }
                    if invalid == 2 { receipt["documentDigest"] = String(repeating: "b", count: 64) }
                    if invalid == 3 { receipt["result"] = "DECLINED" }
                    if invalid == 4 { receipt["recordedAt"] = "invalid" }
                    return LegalConsentFixtures.recorded(receipt)
                }, present: { _ in true }, check: {})
                XCTFail("Invalid receipt must stop collection")
            } catch {}
        }
    }

    func testMissingConfigurationOrMalformedReadNeverPresents() async throws {
        for response: [String: Any] in [[:], ["version": 1, "status": "NOT_AVAILABLE"],
                                       ["version": 1, "status": "READY", "nextStep": "COLLECT_LEGAL_EVIDENCE", "legal": [:]]] {
            do {
                try await LegalConsent.require(LegalConsentFixtures.code, store: MemoryLegalDecisionStore(), send: { _, _, _ in response },
                    present: { _ in XCTFail("No approved copy"); return true }, check: {})
                XCTFail("Missing copy must stop collection")
            } catch {}
        }
    }

    func testReceiptCompletionAfterUnmountCannotAuthorizeCollection() async throws {
        var active = true
        do {
            try await LegalConsent.require(LegalConsentFixtures.code, store: MemoryLegalDecisionStore(), send: { operation, _, key in
                if operation == "READ_LEGAL_DISCLOSURE" { return LegalConsentFixtures.read() }
                active = false
                return LegalConsentFixtures.recorded(LegalConsentFixtures.receipt(key!))
            }, present: { _ in true }, check: {
                if !active { throw LegalConsentError.cancelled }
            })
            XCTFail("Late receipt cannot resume collection")
        } catch LegalConsentError.cancelled {}
    }

    func testLateReadOrPresentationCannotStartFurtherWork() async throws {
        for stopAfterRead in [true, false] {
            var active = true
            var calls = 0
            do {
                try await LegalConsent.require(LegalConsentFixtures.code, store: MemoryLegalDecisionStore(), send: { _, _, _ in
                    calls += 1
                    if stopAfterRead { active = false }
                    return LegalConsentFixtures.read()
                }, present: { _ in active = false; return true }, check: {
                    if !active { throw LegalConsentError.cancelled }
                })
                XCTFail("Unmount must stop")
            } catch LegalConsentError.cancelled {}
            XCTAssertEqual(calls, 1)
        }
    }
}

final class MemoryLegalDecisionStore: LegalDecisionStoring {
    var value: LegalDecision?
    func pending() throws -> LegalDecision? { value }
    func retain(_ decision: LegalDecision) throws {
        guard value == nil || value == decision else { throw PaymentActionError.alreadyAttempted }
        value = decision
    }
    func resolve(_ decision: LegalDecision) throws {
        guard value == decision else { throw PaymentActionError.storage }
        value = nil
    }
}
