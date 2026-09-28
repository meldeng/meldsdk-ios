import CryptoKit
import Foundation
import Security

struct WalletAttemptRecord: Codable {
    var submissionKey: UUID = UUID()
    var submissionStarted = false
    var verificationOpened = false
}

protocol WalletAttemptStoring {
    func record() throws -> WalletAttemptRecord
    func claimSubmission() throws -> UUID
    func claimVerification() throws
    func observeSubmission() throws
}

/// Only a mutation UUID and two non-secret fences are stored. No bearer, wallet token, URL or PII.
final class WalletAttemptStore: WalletAttemptStoring {
    private static let lock = NSLock()
    private let account: String
    private let service = "io.meld.sdk.wallet-attempts.v1"

    init(identity: String) {
        account = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func record() throws -> WalletAttemptRecord {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try read()
    }

    func claimSubmission() throws -> UUID {
        try update { record in
            guard !record.submissionStarted else { throw PaymentActionError.alreadyAttempted }
            record.submissionStarted = true
            return record.submissionKey
        }
    }

    func claimVerification() throws {
        try update { record in
            guard !record.verificationOpened else { throw PaymentActionError.alreadyAttempted }
            record.submissionStarted = true
            record.verificationOpened = true
        }
    }

    func observeSubmission() throws { try update { $0.submissionStarted = true } }

    private func update<T>(_ change: (inout WalletAttemptRecord) throws -> T) throws -> T {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var record = try read()
        let result = try change(&record)
        let data = try JSONEncoder().encode(record)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw PaymentActionError.storage }
        } else if update != errSecSuccess { throw PaymentActionError.storage }
        return result
    }

    private func read() throws -> WalletAttemptRecord {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return WalletAttemptRecord() }
        guard status == errSecSuccess, let data = result as? Data,
              let record = try? JSONDecoder().decode(WalletAttemptRecord.self, from: data)
        else { throw PaymentActionError.storage }
        return record
    }
}

/// In-process mount ownership complements the durable submission fence and the server's guard.
enum WalletMountOwnership {
    private static let lock = NSLock()
    private static var active = Set<String>()

    static func acquire(_ identity: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active.insert(identity).inserted
    }

    static func release(_ identity: String) {
        lock.lock(); defer { lock.unlock() }
        active.remove(identity)
    }
}
