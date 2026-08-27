import XCTest
@testable import SimpleSMBFileBrowser

/// Isolated UserDefaults so tests never read or write the real app domain.
private func makeDefaults() -> UserDefaults {
    let suite = "test.SimpleSMBFileBrowser.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

@MainActor
final class ServerStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var credentials: InMemoryCredentialStore!
    private var store: ServerStore!

    override func setUp() {
        super.setUp()
        defaults = makeDefaults()
        credentials = InMemoryCredentialStore()
        store = ServerStore(defaults: defaults, credentials: credentials)
    }

    func testStartsEmpty() {
        XCTAssertTrue(store.isEmpty)
        XCTAssertNil(store.defaultServerID)
        XCTAssertNil(store.launchServer)
    }

    func testSaveAddsProfileAndPassword() throws {
        let profile = ServerProfile.fixture()

        try store.save(profile, password: "pw")

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(try credentials.password(for: profile.id), "pw")
    }

    func testSaveTwiceUpdatesRatherThanDuplicates() throws {
        var profile = ServerProfile.fixture(name: "First")
        try store.save(profile, password: "pw")

        profile.name = "Renamed"
        try store.save(profile, password: nil)

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles.first?.name, "Renamed")
    }

    func testNilPasswordLeavesStoredPasswordIntact() throws {
        let profile = ServerProfile.fixture()
        try store.save(profile, password: "keep-me")

        try store.save(profile, password: nil)

        XCTAssertEqual(try credentials.password(for: profile.id), "keep-me")
    }

    func testTurningOffSaveCredentialsClearsTheSecret() throws {
        var profile = ServerProfile.fixture(saveCredentials: true)
        try store.save(profile, password: "pw")

        profile.saveCredentials = false
        try store.save(profile, password: nil)

        XCTAssertNil(try credentials.password(for: profile.id))
    }

    func testPasswordLookupRespectsSaveCredentialsFlag() throws {
        let profile = ServerProfile.fixture(saveCredentials: false)
        try credentials.setPassword("leaked", for: profile.id)
        try store.save(profile, password: nil)

        XCTAssertNil(store.password(for: profile), "A profile that doesn't save credentials must not return one")
    }

    func testSetDefaultAndPersist() throws {
        let profile = ServerProfile.fixture()
        try store.save(profile, password: nil, makeDefault: true)

        XCTAssertEqual(store.defaultServerID, profile.id)

        // A fresh store over the same defaults should see the same default.
        let reloaded = ServerStore(defaults: defaults, credentials: credentials)
        XCTAssertEqual(reloaded.defaultServerID, profile.id)
        XCTAssertEqual(reloaded.profiles.count, 1)
    }

    func testSetDefaultIgnoresUnknownID() throws {
        try store.save(.fixture(), password: nil)
        store.setDefault(UUID())
        XCTAssertNil(store.defaultServerID)
    }

    func testRemoveDropsProfilePasswordAndDefault() throws {
        let profile = ServerProfile.fixture()
        try store.save(profile, password: "pw", makeDefault: true)

        try store.remove(id: profile.id)

        XCTAssertTrue(store.isEmpty)
        XCTAssertNil(store.defaultServerID)
        XCTAssertNil(try credentials.password(for: profile.id))
    }

    func testLaunchServerFallsBackToFirstProfile() throws {
        let first = ServerProfile.fixture(name: "A")
        try store.save(first, password: nil)
        try store.save(.fixture(name: "B"), password: nil)

        // No explicit default: a single-server setup should still auto-connect.
        XCTAssertEqual(store.launchServer?.id, first.id)
    }

    func testDanglingDefaultIsDiscardedOnLoad() throws {
        let profile = ServerProfile.fixture()
        try store.save(profile, password: nil, makeDefault: true)
        // Simulate a profile list that lost the default's entry.
        defaults.set(try JSONEncoder().encode([ServerProfile]()), forKey: "servers.profiles")

        let reloaded = ServerStore(defaults: defaults, credentials: credentials)

        XCTAssertNil(reloaded.defaultServerID, "A default pointing at a missing profile must not survive")
    }
}

@MainActor
final class AppPreferencesTests: XCTestCase {
    func testDefaults() {
        let preferences = AppPreferences(defaults: makeDefaults())

        XCTAssertEqual(preferences.defaultViewMode, .list)
        XCTAssertEqual(preferences.defaultSort, .default)
        XCTAssertFalse(preferences.recursiveSearch)
        XCTAssertNil(preferences.recoveryApp)
    }

    func testValuesPersist() {
        let defaults = makeDefaults()
        let preferences = AppPreferences(defaults: defaults)

        preferences.defaultViewMode = .grid
        preferences.defaultSort = SortOption(field: .size, direction: .descending)
        preferences.recursiveSearch = true
        preferences.recoveryApp = RecoveryApp(name: "Tailscale", scheme: "tailscale")

        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.defaultViewMode, .grid)
        XCTAssertEqual(reloaded.defaultSort.field, .size)
        XCTAssertEqual(reloaded.defaultSort.direction, .descending)
        XCTAssertTrue(reloaded.recursiveSearch)
        XCTAssertEqual(reloaded.recoveryApp?.scheme, "tailscale")
    }

    func testClearingRecoveryApp() {
        let defaults = makeDefaults()
        let preferences = AppPreferences(defaults: defaults)
        preferences.recoveryApp = RecoveryApp(name: "T", scheme: "tailscale")

        preferences.recoveryApp = nil

        XCTAssertNil(AppPreferences(defaults: defaults).recoveryApp)
    }
}

@MainActor
final class TransferCenterTests: XCTestCase {
    func testBeginAddsActiveTransfer() {
        let center = TransferCenter()

        let id = center.begin(fileName: "a.txt", direction: .upload, destinationLabel: "nas", totalBytes: 100)

        XCTAssertEqual(center.active.count, 1)
        XCTAssertTrue(center.recent.isEmpty)
        XCTAssertEqual(center.transfers.first?.id, id)
    }

    func testUpdateTracksProgress() {
        let center = TransferCenter()
        let id = center.begin(fileName: "a", direction: .download, destinationLabel: "x", totalBytes: 200)

        center.update(id, transferred: 50, total: 200)

        XCTAssertEqual(center.transfers.first?.fractionCompleted, 0.25)
    }

    func testCompletionSnapsToFull() {
        let center = TransferCenter()
        let id = center.begin(fileName: "a", direction: .download, destinationLabel: "x", totalBytes: 200)
        center.update(id, transferred: 199, total: 200)

        center.finish(id, state: .completed)

        // A finished row reading 99% looks like a bug.
        XCTAssertEqual(center.transfers.first?.fractionCompleted, 1)
        XCTAssertEqual(center.active.count, 0)
        XCTAssertEqual(center.recent.count, 1)
    }

    func testRequestCancelMarksCancelledAndFlagsRegistry() {
        let center = TransferCenter()
        let id = center.begin(fileName: "a", direction: .upload, destinationLabel: "x")

        center.requestCancel(id)

        XCTAssertTrue(center.cancellation.isCancelled(id))
        XCTAssertEqual(center.transfers.first?.state, .cancelled)
    }

    func testProgressHandlerReturnsFalseOnceCancelled() {
        let center = TransferCenter()
        let id = center.begin(fileName: "a", direction: .upload, destinationLabel: "x", totalBytes: 10)
        let handler = center.progressHandler(for: id)

        XCTAssertTrue(handler(1, 10))
        center.requestCancel(id)
        XCTAssertFalse(handler(2, 10), "The handler's false return is what aborts the transfer")
    }

    func testClearHistoryKeepsActive() {
        let center = TransferCenter()
        let done = center.begin(fileName: "done", direction: .upload, destinationLabel: "x")
        center.finish(done, state: .completed)
        _ = center.begin(fileName: "running", direction: .upload, destinationLabel: "x")

        center.clearHistory()

        XCTAssertEqual(center.recent.count, 0)
        XCTAssertEqual(center.active.count, 1)
    }

    func testHistoryIsTrimmedToLimit()  {
        let center = TransferCenter()
        center.historyLimit = 3

        for index in 0..<6 {
            let id = center.begin(fileName: "f\(index)", direction: .upload, destinationLabel: "x")
            center.finish(id, state: .completed)
        }

        XCTAssertEqual(center.recent.count, 3)
    }

    func testCancelAllCancelsEveryActiveTransfer() {
        let center = TransferCenter()
        let a = center.begin(fileName: "a", direction: .upload, destinationLabel: "x")
        let b = center.begin(fileName: "b", direction: .upload, destinationLabel: "x")

        center.cancelAll()

        XCTAssertTrue(center.cancellation.isCancelled(a))
        XCTAssertTrue(center.cancellation.isCancelled(b))
        XCTAssertTrue(center.active.isEmpty)
    }

    func testOverallFractionAveragesKnownProgress() {
        let center = TransferCenter()
        let a = center.begin(fileName: "a", direction: .upload, destinationLabel: "x", totalBytes: 100)
        let b = center.begin(fileName: "b", direction: .upload, destinationLabel: "x", totalBytes: 100)
        center.update(a, transferred: 100, total: 100)
        center.update(b, transferred: 0, total: 100)

        XCTAssertEqual(center.overallFraction, 0.5)
    }
}
