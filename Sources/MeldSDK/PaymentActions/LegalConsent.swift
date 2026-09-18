import Foundation

enum LegalConsentError: Error { case unavailable, invalidResponse, declined, cancelled }

struct LegalDisclosure: CustomStringConvertible {
    let code: String
    let title: String
    let version: String
    let locale: String
    let text: String
    let digest: String
    var description: String { "LegalDisclosure[REDACTED]" }

    init(_ value: [String: Any], code: String) throws {
        guard value["requirementCode"] as? String == code,
              let title = value["title"] as? String, Self.plain(title, max: 120),
              let version = value["documentVersion"] as? String,
              Self.matches(version, "[A-Za-z0-9][A-Za-z0-9._-]{0,63}"),
              let locale = value["locale"] as? String, locale.count <= 35,
              Self.matches(locale, "[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*"),
              let text = value["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf16.count <= 4000,
              !text.unicodeScalars.contains(where: { ($0.value < 32 && ![9, 10, 13].contains($0.value)) || $0.value == 127 }),
              let digest = value["documentDigest"] as? String, Self.matches(digest, "[a-f0-9]{64}")
        else { throw LegalConsentError.invalidResponse }
        self.code = code; self.title = title; self.version = version; self.locale = locale
        self.text = text; self.digest = digest
    }

    private static func plain(_ value: String, max: Int) -> Bool {
        !value.isEmpty && value.utf16.count <= max && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }
    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: "\\A(?:" + pattern + ")\\z", options: .regularExpression) != nil
    }
}

/// No identity data enters this protocol. A transport or receipt failure prevents collection.
@MainActor
enum LegalConsent {
    typealias Send = @MainActor (String, [String: Any], UUID?) async throws -> [String: Any]

    static func require(_ code: String, send: Send,
                        present: @MainActor (LegalDisclosure) async throws -> Bool,
                        check: @MainActor () throws -> Void) async throws {
        try check()
        let read = try await send("READ_LEGAL_DISCLOSURE", ["legalRequirementCode": code], nil)
        try check()
        guard PaymentActionJSON.integer(read["version"]) == 1 else { throw LegalConsentError.invalidResponse }
        if read["status"] as? String == "NOT_AVAILABLE" { throw LegalConsentError.unavailable }
        guard read["status"] as? String == "READY", read["nextStep"] as? String == "COLLECT_LEGAL_EVIDENCE",
              let legal = read["legal"] as? [String: Any], let raw = legal["disclosure"] as? [String: Any]
        else { throw LegalConsentError.invalidResponse }
        let disclosure = try LegalDisclosure(raw, code: code)
        if let receipt = legal["receipt"] {
            let result = try validate(receipt, disclosure: disclosure, key: nil)
            if result == "ACCEPTED" { return }
        }
        let accepted = try await present(disclosure)
        try check()
        let key = UUID()
        let expected = accepted ? "ACCEPTED" : "DECLINED"
        let recorded = try await send("RECORD_LEGAL_EVIDENCE", [
            "legalRequirementCode": code,
            "legalEvidence": ["documentVersion": disclosure.version, "locale": disclosure.locale,
                              "documentDigest": disclosure.digest, "result": expected]], key)
        try check()
        guard PaymentActionJSON.integer(recorded["version"]) == 1,
              recorded["status"] as? String == (accepted ? "AUTHORIZED" : "REJECTED"),
              recorded["nextStep"] as? String == "NONE",
              let legal = recorded["legal"] as? [String: Any], let receipt = legal["receipt"],
              try validate(receipt, disclosure: disclosure, key: key) == expected
        else { throw LegalConsentError.invalidResponse }
        if !accepted { throw LegalConsentError.declined }
    }

    private static func validate(_ value: Any, disclosure: LegalDisclosure, key: UUID?) throws -> String {
        guard let receipt = value as? [String: Any],
              let rawID = receipt["id"] as? String, rawID.count == 36, let id = UUID(uuidString: rawID),
              key == nil || key == id,
              receipt["requirementCode"] as? String == disclosure.code,
              receipt["documentVersion"] as? String == disclosure.version,
              receipt["locale"] as? String == disclosure.locale,
              receipt["documentDigest"] as? String == disclosure.digest,
              let result = receipt["result"] as? String, ["ACCEPTED", "DECLINED"].contains(result),
              let recordedAt = receipt["recordedAt"] as? String, date(recordedAt) != nil
        else { throw LegalConsentError.invalidResponse }
        return result
    }

    private static func date(_ value: String) -> Date? {
        guard value.count <= 40 else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
