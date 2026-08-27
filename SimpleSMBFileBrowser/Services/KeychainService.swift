import Foundation
import Security

/// Storage for SMB passwords.
///
/// A protocol rather than a concrete type so unit tests and previews can swap
/// in an in-memory double; the real Keychain is awkward to exercise in CI and
/// on a simulator without an entitled, signed host app.
protocol CredentialStoring: Sendable {
    func setPassword(_ password: String, for id: UUID) throws
    func password(for id: UUID) throws -> String?
    func removePassword(for id: UUID) throws
    func removeAllPasswords() throws
}

enum KeychainError: Error, Equatable, LocalizedError {
    case unexpectedStatus(OSStatus)
    case dataCorrupted

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String?
            return message ?? "Keychain error \(status)."
        case .dataCorrupted:
            return "The stored password could not be read."
        }
    }
}

/// Keychain-backed credential storage, keyed by `ServerProfile.id`.
///
/// Passwords are stored as generic passwords under a single service name, with
/// the profile UUID as the account. Keying by UUID rather than host/username
/// means renaming a server or changing its user never orphans a secret.
struct KeychainService: CredentialStoring {
    /// Overridable so tests can isolate themselves from real stored credentials.
    let service: String

    init(service: String = "eu.org.amirulandalib.SimpleSMBFileBrowser.smb-credentials") {
        self.service = service
    }

    private func baseQuery(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    func setPassword(_ password: String, for id: UUID) throws {
        let data = Data(password.utf8)
        var query = baseQuery(for: id)

        // Try to update an existing item first; SecItemAdd fails with
        // errSecDuplicateItem rather than overwriting.
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        query[kSecValueData as String] = data
        // Available after first unlock so an auto-connect at launch can read the
        // password without the device having been unlocked in this boot.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    func password(for id: UUID) throws -> String? {
        var query = baseQuery(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainError.dataCorrupted }
            guard let password = String(data: data, encoding: .utf8) else {
                throw KeychainError.dataCorrupted
            }
            return password
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func removePassword(for id: UUID) throws {
        let status = SecItemDelete(baseQuery(for: id) as CFDictionary)
        // Deleting something already absent is success, not failure.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func removeAllPasswords() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

/// In-memory credential store for tests and previews.
final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private var storage: [UUID: String] = [:]
    private let lock = NSLock()
    /// When set, every operation throws this instead — used to exercise the
    /// failure paths in callers.
    var errorToThrow: (any Error)?

    init(initial: [UUID: String] = [:]) {
        self.storage = initial
    }

    func setPassword(_ password: String, for id: UUID) throws {
        if let errorToThrow { throw errorToThrow }
        lock.withLock { storage[id] = password }
    }

    func password(for id: UUID) throws -> String? {
        if let errorToThrow { throw errorToThrow }
        return lock.withLock { storage[id] }
    }

    func removePassword(for id: UUID) throws {
        if let errorToThrow { throw errorToThrow }
        lock.withLock { _ = storage.removeValue(forKey: id) }
    }

    func removeAllPasswords() throws {
        if let errorToThrow { throw errorToThrow }
        lock.withLock { storage.removeAll() }
    }

    var count: Int { lock.withLock { storage.count } }
}
