import Foundation
import CryptoKit
import Security
import UIKit
import XCTest
@testable import MeldSDK

@MainActor
final class LegalDecisionRecoveryTests: XCTestCase {
    func testLostResponseRemountRequiresExplicitRecoveryAndRepeatsExactDecision() async throws {
        for accepted in [true, false] {
            let store = MemoryLegalDecisionStore()
            var firstKey: UUID?
            var firstBody: Data?
            do {
                try await LegalConsent.require(LegalConsentFixtures.code, store: store, send: { operation, fields, key in
                    if operation == "READ_LEGAL_DISCLOSURE" { return LegalConsentFixtures.read() }
                    firstKey = key
                    firstBody = try JSONSerialization.data(withJSONObject: fields, options: .sortedKeys)
                    throw PaymentActionError.transport
                }, present: { _ in accepted }, check: {})
                XCTFail("Uncertain write cannot authorize collection")
            } catch PaymentActionError.transport {}
            XCTAssertNotNil(store.value)
            var recovered = false
            var writes = 0
            do {
                try await LegalConsent.require(LegalConsentFixtures.code, store: store, send: { operation, fields, key in
                    if operation == "READ_LEGAL_DISCLOSURE" {
                        XCTAssertTrue(recovered)
                        return LegalConsentFixtures.read(LegalConsentFixtures.receipt(firstKey!))
                    }
                    XCTAssertTrue(recovered)
                    writes += 1
                    XCTAssertEqual(key, firstKey)
                    XCTAssertEqual(try JSONSerialization.data(withJSONObject: fields, options: .sortedKeys), firstBody)
                    return LegalConsentFixtures.recorded(LegalConsentFixtures.receipt(key!, result: accepted ? "ACCEPTED" : "DECLINED"))
                }, recover: { decision in
                    XCTAssertEqual(decision.accepted, accepted)
                    recovered = true
                    return true
                }, present: { _ in XCTFail("Cannot replace saved choice"); return !accepted }, check: {})
                XCTAssertTrue(accepted)
            } catch LegalConsentError.declined { XCTAssertFalse(accepted) }
            XCTAssertEqual(writes, 1)
            XCTAssertNil(store.value)
        }
    }

    func testCancelledRecoveryAndMismatchedReceiptRetainOriginalDecision() async throws {
        let disclosure = try LegalDisclosure(LegalConsentFixtures.disclosure, code: LegalConsentFixtures.code)
        for cancel in [true, false] {
            let store = MemoryLegalDecisionStore()
            let original = LegalDecision(disclosure: disclosure, accepted: false)
            try store.retain(original)
            var calls = 0
            do {
                try await LegalConsent.require(LegalConsentFixtures.code, store: store, send: { _, _, _ in
                    calls += 1
                    return LegalConsentFixtures.recorded(LegalConsentFixtures.receipt())
                }, recover: { _ in !cancel }, present: { _ in XCTFail("Saved decision exists"); return true }, check: {})
                XCTFail("Must not authorize")
            } catch {}
            XCTAssertEqual(calls, cancel ? 0 : 1)
            XCTAssertEqual(store.value, original)
        }
    }

    func testKeychainRemountPreservesDecisionAndRejectsReplacementOrWrongResolution() throws {
        let identity = "synthetic-legal-" + UUID().uuidString
        let first = LegalDecisionStore(identity: identity, code: LegalConsentFixtures.code)
        let second = LegalDecisionStore(identity: identity, code: LegalConsentFixtures.code)
        let disclosure = try LegalDisclosure(LegalConsentFixtures.disclosure, code: LegalConsentFixtures.code)
        let original = LegalDecision(disclosure: disclosure, accepted: false)
        let replacement = LegalDecision(disclosure: disclosure, accepted: true)
        XCTAssertNil(try first.pending())
        try first.retain(original)
        defer { try? first.resolve(original) }
        XCTAssertEqual(try second.pending(), original)
        XCTAssertThrowsError(try second.retain(replacement))
        XCTAssertThrowsError(try second.resolve(replacement))
        XCTAssertEqual(try first.pending(), original)
        try second.resolve(original)
        XCTAssertNil(try first.pending())
    }

    func testLateRecoveryReceiptCannotClearDecisionOrAuthorizeCollection() async throws {
        let store = MemoryLegalDecisionStore()
        let disclosure = try LegalDisclosure(LegalConsentFixtures.disclosure, code: LegalConsentFixtures.code)
        let original = LegalDecision(disclosure: disclosure, accepted: true)
        try store.retain(original)
        var active = true
        do {
            try await LegalConsent.require(LegalConsentFixtures.code, store: store, send: { _, _, key in
                active = false
                return LegalConsentFixtures.recorded(LegalConsentFixtures.receipt(key!))
            }, recover: { _ in true }, present: { _ in XCTFail("Retired"); return true }, check: {
                if !active { throw LegalConsentError.cancelled }
            })
            XCTFail("Retired flow cannot continue")
        } catch LegalConsentError.cancelled {}
        XCTAssertEqual(store.value, original)
    }

    func testRecoveryViewOffersOnlySavedDecisionRetryAndCancel() throws {
        let disclosure = try LegalDisclosure(LegalConsentFixtures.disclosure, code: LegalConsentFixtures.code)
        var decision: Bool?
        let view = LegalDisclosureViewController(disclosure: disclosure, recovery: true) { result in
            if case .success(let value) = result { decision = value }
        }
        view.loadViewIfNeeded()
        let stack = try XCTUnwrap(view.view.subviews.compactMap { $0 as? UIStackView }.first)
        XCTAssertEqual(stack.arrangedSubviews.count, 1)
        let retry = try XCTUnwrap(stack.arrangedSubviews.first as? UIButton)
        XCTAssertEqual(retry.title(for: .normal), "Retry saved decision")
        XCTAssertNil(decision)
        retry.sendActions(for: .touchUpInside)
        XCTAssertEqual(decision, true)
    }

    func testRecoveredAcceptanceRereadsChangedDocumentBeforeAuthorizing() async throws {
        let store = MemoryLegalDecisionStore()
        let disclosure = try LegalDisclosure(LegalConsentFixtures.disclosure, code: LegalConsentFixtures.code)
        let original = LegalDecision(disclosure: disclosure, accepted: true)
        try store.retain(original)
        var operations: [String] = []
        var presented = false
        do {
            try await LegalConsent.require(LegalConsentFixtures.code, store: store, send: { operation, _, key in
                operations.append(operation)
                if operation == "RECORD_LEGAL_EVIDENCE" {
                    XCTAssertEqual(key, original.key)
                    return LegalConsentFixtures.recorded(LegalConsentFixtures.receipt(key!))
                }
                var changed = LegalConsentFixtures.disclosure
                changed["documentVersion"] = "v2"
                changed["documentDigest"] = String(repeating: "b", count: 64)
                return ["version": 1, "status": "READY", "nextStep": "COLLECT_LEGAL_EVIDENCE",
                        "legal": ["disclosure": changed]]
            }, recover: { _ in true }, present: { current in
                presented = true
                XCTAssertEqual(current.version, "v2")
                throw LegalConsentError.cancelled
            }, check: {})
            XCTFail("An old acceptance cannot authorize the new document")
        } catch LegalConsentError.cancelled {}
        XCTAssertTrue(presented)
        XCTAssertEqual(operations, ["RECORD_LEGAL_EVIDENCE", "READ_LEGAL_DISCLOSURE"])
        XCTAssertNil(store.value)
    }

    func testMalformedOrFutureKeychainRecordsFailClosed() throws {
        let identity = "synthetic-corrupt-" + UUID().uuidString
        let code = LegalConsentFixtures.code
        let store = LegalDecisionStore(identity: identity, code: code)
        let disclosure = try LegalDisclosure(LegalConsentFixtures.disclosure, code: code)
        let original = LegalDecision(disclosure: disclosure, accepted: true)
        try store.retain(original)
        let account = SHA256.hash(data: Data((identity + "\n" + code).utf8)).map { String(format: "%02x", $0) }.joined()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.meld.sdk.legal-decisions.v1", kSecAttrAccount as String: account]
        defer { SecItemDelete(query as CFDictionary) }
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        for (field, value): (String, Any) in [("version", 2), ("accepted", "true"), ("digest", "bad"), ("unknown", true)] {
            var corrupt = raw; corrupt[field] = value
            let data = try JSONSerialization.data(withJSONObject: corrupt)
            XCTAssertEqual(SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary), errSecSuccess)
            XCTAssertThrowsError(try store.pending())
            XCTAssertThrowsError(try store.retain(original))
        }
    }

    func testFailureToRetainDecisionPreventsWrite() async throws {
        var calls = 0
        do {
            try await LegalConsent.require(LegalConsentFixtures.code, store: FailingLegalDecisionStore(), send: { _, _, _ in
                calls += 1
                return LegalConsentFixtures.read()
            }, present: { _ in true }, check: {})
            XCTFail("Storage failure must stop")
        } catch PaymentActionError.storage {}
        XCTAssertEqual(calls, 1)
    }
}

private struct FailingLegalDecisionStore: LegalDecisionStoring {
    func pending() throws -> LegalDecision? { nil }
    func retain(_ decision: LegalDecision) throws { throw PaymentActionError.storage }
    func resolve(_ decision: LegalDecision) throws { throw PaymentActionError.storage }
}
