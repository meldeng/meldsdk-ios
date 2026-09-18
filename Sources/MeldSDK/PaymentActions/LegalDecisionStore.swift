import CryptoKit
import Foundation
import Security

struct LegalDecision: Codable, Equatable, CustomStringConvertible {
    let version: Int
    let key: UUID
    let code: String
    let documentVersion: String
    let locale: String
    let digest: String
    let accepted: Bool
    var description: String { "LegalDecision[REDACTED]" }

    init(disclosure: LegalDisclosure, accepted: Bool) {
        version = 1; key = UUID(); code = disclosure.code
        documentVersion = disclosure.version; locale = disclosure.locale
        digest = disclosure.digest; self.accepted = accepted
    }

    var fields: [String: Any] {
        ["legalRequirementCode": code, "legalEvidence": ["documentVersion": documentVersion,
         "locale": locale, "documentDigest": digest, "result": accepted ? "ACCEPTED" : "DECLINED"]]
    }

    func validate() throws {
        guard version == 1, code.range(of: "\\A[A-Z][A-Z0-9_]{0,63}\\z", options: .regularExpression) != nil
        else { throw PaymentActionError.storage }
        _ = try LegalDisclosure(["requirementCode": code, "title": "Saved decision",
            "documentVersion": documentVersion, "locale": locale, "documentDigest": digest,
            "text": "Previously reviewed disclosure."], code: code)
    }
}

protocol LegalDecisionStoring {
    func pending() throws -> LegalDecision?
    func retain(_ decision: LegalDecision) throws
    func resolve(_ decision: LegalDecision) throws
}

/// One unresolved decision per order/requirement. No disclosure text, bearer, provider URL or PII.
final class LegalDecisionStore: LegalDecisionStoring {
    private static let lock = NSLock()
    private let account: String
    private let service = "io.meld.sdk.legal-decisions.v1"
    init(identity: String, code: String) {
        account = SHA256.hash(data: Data((identity + "\n" + code).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    func pending() throws -> LegalDecision? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try read()
    }
    func retain(_ decision: LegalDecision) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try decision.validate()
        if let existing = try read() {
            guard existing == decision else { throw PaymentActionError.alreadyAttempted }
            return
        }
        var insert = query
        insert[kSecValueData as String] = try JSONEncoder().encode(decision)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw PaymentActionError.storage }
    }
    func resolve(_ decision: LegalDecision) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard try read() == decision else { throw PaymentActionError.storage }
        guard SecItemDelete(query as CFDictionary) == errSecSuccess else { throw PaymentActionError.storage }
    }
    private func read() throws -> LegalDecision? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 4096,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["version", "key", "code", "documentVersion", "locale", "digest", "accepted"]),
              let decision = try? JSONDecoder().decode(LegalDecision.self, from: data)
        else { throw PaymentActionError.storage }
        try decision.validate()
        return decision
    }
}
