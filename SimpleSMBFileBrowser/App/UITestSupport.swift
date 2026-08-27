import Foundation

/// Launch-argument hooks that make the UI tests deterministic.
///
/// All of it is gated on `-uiTesting`, which the app is never launched with in
/// normal use. Without this, UI tests would depend on whatever servers and
/// credentials happen to be on the device, and the connection-failure modal
/// could only be tested by unplugging a network cable.
enum UITestSupport {
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    static var isEnabled: Bool { arguments.contains("-uiTesting") }

    /// Seeds a saved server so the browser has something to open.
    static var seedsServer: Bool { arguments.contains("-uiTestSeedServer") }

    /// Configures a recovery app, so the failure modal shows its button.
    static var seedsRecoveryApp: Bool { arguments.contains("-uiTestRecoveryApp") }

    /// Seeds a directory of files in the on-device location, for multi-select
    /// and delete tests.
    static var seedsDeviceFiles: Bool { arguments.contains("-uiTestSeedFiles") }

    /// Forces every SMB connection to fail with a given failure kind, e.g.
    /// `-uiTestFailure timedOut`.
    static var forcedFailure: BrowseFailure.Kind? {
        guard let index = arguments.firstIndex(of: "-uiTestFailure"),
              index + 1 < arguments.count else { return nil }
        switch arguments[index + 1] {
        case "timedOut": return .timedOut
        case "authenticationFailed": return .authenticationFailed
        case "hostUnreachable": return .hostUnreachable
        default: return nil
        }
    }

    /// Builds the app model for a UI test run: isolated UserDefaults, in-memory
    /// credentials, and an SMB factory that fails on demand.
    @MainActor
    static func makeAppModel() -> AppModel {
        guard isEnabled else { return AppModel() }

        let suite = "uitest.SimpleSMBFileBrowser"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)

        let preferences = AppPreferences(defaults: defaults)
        if seedsRecoveryApp {
            preferences.recoveryApp = RecoveryApp(name: "Test VPN", scheme: "uitest-vpn")
        }

        let servers = ServerStore(defaults: defaults, credentials: InMemoryCredentialStore())
        if seedsServer {
            let profile = ServerProfile(
                name: "UI Test NAS", host: "192.168.99.99", shareName: "Media", username: "tester"
            )
            try? servers.save(profile, password: "pw", makeDefault: true)
        }

        if seedsDeviceFiles { seedDeviceFiles() }

        let factory: any SMBClientFactory = forcedFailure
            .map { FailingSMBClientFactory(kind: $0) } ?? AMSMB2ClientFactory()

        return AppModel(
            preferences: preferences,
            servers: servers,
            clientFactory: factory
        )
    }

    /// Writes a predictable set of files into the on-device root.
    private static func seedDeviceFiles() {
        let fileManager = FileManager.default
        guard let root = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let directory = root.appendingPathComponent("UITestFiles", isDirectory: true)
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 1...4 {
            let url = directory.appendingPathComponent("sample-\(index).txt")
            try? "sample \(index)".write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// SMB factory whose clients always fail to connect, used to drive the
/// connection-failure modal in UI tests.
private struct FailingSMBClientFactory: SMBClientFactory {
    let kind: BrowseFailure.Kind

    func makeClient(for profile: ServerProfile, password: String?, timeout: TimeInterval) throws -> any SMBClient {
        FailingSMBClient(failure: BrowseFailure(kind: kind, target: profile.host))
    }
}

private struct FailingSMBClient: SMBClient {
    let failure: BrowseFailure

    func connect() async throws { throw failure }
    func disconnect() async {}
    func listShares() async throws -> [String] { throw failure }
    func listDirectory(at path: String, recursive: Bool) async throws -> [FileItem] { throw failure }
    func attributes(at path: String) async throws -> FileItem { throw failure }
    func createDirectory(at path: String) async throws { throw failure }
    func removeFile(at path: String) async throws { throw failure }
    func removeDirectory(at path: String, recursive: Bool) async throws { throw failure }
    func move(from source: String, to destination: String) async throws { throw failure }
    func copy(from source: String, to destination: String, recursive: Bool, progress: TransferProgress?) async throws { throw failure }
    func upload(from localURL: URL, to path: String, progress: TransferProgress?) async throws { throw failure }
    func download(from path: String, to localURL: URL, progress: TransferProgress?) async throws { throw failure }
    func readStream(at path: String) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { $0.finish(throwing: failure) }
    }
}
