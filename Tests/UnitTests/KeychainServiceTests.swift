import XCTest
@testable import SimpleSMBFileBrowser

/// Covers `KeychainService` against the real Keychain, plus the in-memory
/// double used elsewhere in the tests.
final class KeychainServiceTests: XCTestCase {
    /// A per-run service name so a failed run can't poison the next one, and so
    /// these tests never touch credentials the app actually saved.
    private var service: KeychainService!
    private var serviceName: String!

    override func setUp() {
        super.setUp()
        serviceName = "test.SimpleSMBFileBrowser.\(UUID().uuidString)"
        service = KeychainService(service: serviceName)
    }

    override func tearDown() {
        try? service.removeAllPasswords()
        service = nil
        super.tearDown()
    }

    /// The Keychain is unavailable to an unsigned/ad-hoc test host in some
    /// configurations, which shows up as errSecMissingEntitlement (-34018).
    /// That's an environment limitation, not a defect, so skip rather than fail.
    private func skipIfKeychainUnavailable(_ error: any Error) throws {
        if case KeychainError.unexpectedStatus(let status) = error, status == -34018 {
            throw XCTSkip("Keychain unavailable to this test host (errSecMissingEntitlement)")
        }
    }

    func testStoreAndRetrievePassword() throws {
        let id = UUID()
        do {
            try service.setPassword("hunter2", for: id)
        } catch {
            try skipIfKeychainUnavailable(error)
            throw error
        }

        XCTAssertEqual(try service.password(for: id), "hunter2")
    }

    func testRetrievingUnknownIDReturnsNil() throws {
        // Evaluated outside the assertion: XCTAssertNil catches a throw from its
        // autoclosure and reports it as a failure, which would bypass the skip.
        let stored: String?
        do {
            stored = try service.password(for: UUID())
        } catch {
            try skipIfKeychainUnavailable(error)
            throw error
        }
        XCTAssertNil(stored)
    }

    func testOverwritingPasswordUpdatesInPlace() throws {
        let id = UUID()
        do {
            try service.setPassword("first", for: id)
        } catch {
            try skipIfKeychainUnavailable(error)
            throw error
        }
        // SecItemAdd fails with errSecDuplicateItem, so this must go down the
        // SecItemUpdate path rather than throwing.
        try service.setPassword("second", for: id)

        XCTAssertEqual(try service.password(for: id), "second")
    }

    func testRemovePassword() throws {
        let id = UUID()
        do {
            try service.setPassword("gone-soon", for: id)
        } catch {
            try skipIfKeychainUnavailable(error)
            throw error
        }

        try service.removePassword(for: id)

        XCTAssertNil(try service.password(for: id))
    }

    func testRemovingAbsentPasswordSucceeds() throws {
        do {
            // Deleting something already absent is not an error.
            try service.removePassword(for: UUID())
        } catch {
            try skipIfKeychainUnavailable(error)
            throw error
        }
    }

    func testPasswordsAreIsolatedByID() throws {
        let first = UUID()
        let second = UUID()
        do {
            try service.setPassword("one", for: first)
        } catch {
            try skipIfKeychainUnavailable(error)
            throw error
        }
        try service.setPassword("two", for: second)

        XCTAssertEqual(try service.password(for: first), "one")
        XCTAssertEqual(try service.password(for: second), "two")
    }

    func testTwoServiceNamesDoNotSeeEachOther() throws {
        let id = UUID()
        let other = KeychainService(service: "\(serviceName!).other")
        defer { try? other.removeAllPasswords() }

        do {
            try service.setPassword("mine", for: id)
        } catch {
            try skipIfKeychainUnavailable(error)
            throw error
        }

        XCTAssertNil(try other.password(for: id))
    }

    func testUnicodePasswordRoundTrips() throws {
        let id = UUID()
        let password = "pässwörd-🔐-日本語"
        do {
            try service.setPassword(password, for: id)
        } catch {
            try skipIfKeychainUnavailable(error)
            throw error
        }

        XCTAssertEqual(try service.password(for: id), password)
    }

    // MARK: - In-memory double

    func testInMemoryStoreRoundTrips() throws {
        let store = InMemoryCredentialStore()
        let id = UUID()

        try store.setPassword("abc", for: id)
        XCTAssertEqual(try store.password(for: id), "abc")

        try store.removePassword(for: id)
        XCTAssertNil(try store.password(for: id))
    }

    func testInMemoryStorePropagatesInjectedError() {
        let store = InMemoryCredentialStore()
        store.errorToThrow = KeychainError.dataCorrupted

        XCTAssertThrowsError(try store.setPassword("x", for: UUID())) { error in
            XCTAssertEqual(error as? KeychainError, .dataCorrupted)
        }
    }

    func testInMemoryStoreRemoveAll() throws {
        let store = InMemoryCredentialStore(initial: [UUID(): "a", UUID(): "b"])
        XCTAssertEqual(store.count, 2)

        try store.removeAllPasswords()

        XCTAssertEqual(store.count, 0)
    }
}
