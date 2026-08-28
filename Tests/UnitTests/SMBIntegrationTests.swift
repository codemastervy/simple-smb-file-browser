import XCTest
@testable import SimpleSMBFileBrowser

/// Exercises the real AMSMB2 stack against an actual SMB server.
///
/// Every other SMB test in this suite runs against `MockSMBClient`, which
/// encodes assumptions about AMSMB2 read off its source — path conventions,
/// which `errno` a rejected password produces, whether a share must be connected
/// before it can be listed. If any of those assumptions is wrong, the mock is
/// wrong the same way and the tests still pass. This file is the only thing that
/// can catch that.
///
/// Skipped unless `SMB_TEST_HOST` is set, so a normal run is unaffected:
///
///     SMB_TEST_HOST=192.168.1.50 \
///     SMB_TEST_SHARE=Media \
///     SMB_TEST_USER=me SMB_TEST_PASS=secret \
///     xcodebuild test -only-testing:SimpleSMBFileBrowserTests/SMBIntegrationTests ...
///
/// With only the host set it enumerates shares and stops; supply a share to run
/// the full read/write cycle. Everything it creates is removed afterwards.
final class SMBIntegrationTests: XCTestCase {

    private var host: String!
    private var share: String?
    private var user: String = ""
    private var password: String = ""

    override func setUpWithError() throws {
        let config = try Self.loadConfiguration()
        host = config.host
        share = config.share
        user = config.user ?? ""
        password = config.password ?? ""
        port = config.port ?? 445
        domain = config.domain ?? ""
        continueAfterFailure = false
    }

    private var port: Int = 445
    private var domain: String = ""

    struct Configuration: Decodable {
        let host: String
        var share: String?
        var user: String?
        var password: String?
        var port: Int?
        var domain: String?
    }

    /// Reads `~/.simple-smb-integration.json`, falling back to the environment.
    ///
    /// A file rather than environment variables because `xcodebuild test` does
    /// not forward the shell environment into a test bundle hosted by an app —
    /// neither plain variables nor the `TEST_RUNNER_` prefix reach it. The file
    /// lives outside the repository so a real host and credentials are never
    /// committed.
    ///
    ///     { "host": "192.168.1.50", "share": "Media",
    ///       "user": "", "password": "" }
    static func loadConfiguration() throws -> Configuration {
        let environment = ProcessInfo.processInfo.environment
        if let host = environment["SMB_TEST_HOST"], !host.isEmpty {
            return Configuration(
                host: host,
                share: environment["SMB_TEST_SHARE"],
                user: environment["SMB_TEST_USER"],
                password: environment["SMB_TEST_PASS"],
                port: environment["SMB_TEST_PORT"].flatMap(Int.init),
                domain: environment["SMB_TEST_DOMAIN"]
            )
        }

        // NSHomeDirectory rather than homeDirectoryForCurrentUser: the latter is
        // macOS-only, and this test target also builds for iOS. Under the App
        // Sandbox both resolve to the container, which is where the file has to
        // live for a sandboxed test host to read it.
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".simple-smb-integration.json")
        guard let data = try? Data(contentsOf: url) else {
            throw XCTSkip("""
                No live SMB server configured. Create ~/.simple-smb-integration.json \
                with {"host": "...", "share": "..."} to run these.
                """)
        }
        return try JSONDecoder().decode(Configuration.self, from: data)
    }

    private func makeProfile(share: String) -> ServerProfile {
        ServerProfile(
            name: "Integration",
            host: host,
            port: port,
            shareName: share,
            username: user,
            domain: domain
        )
    }

    private func makeService(share: String) -> SMBService {
        SMBService(profile: makeProfile(share: share), password: password, timeout: 20)
    }

    /// Requires a share; skips with a clear message when one wasn't supplied.
    private func requireShare() throws -> String {
        guard let share, !share.isEmpty else {
            throw XCTSkip("Set SMB_TEST_SHARE to run share-level tests")
        }
        return share
    }

    // MARK: - Discovery

    /// Enumerates shares. Uses whatever share name was given (or IPC$, which is
    /// what share enumeration actually talks to) purely to establish a session.
    func test01_ListShares() async throws {
        let service = makeService(share: share ?? "IPC$")
        do {
            let shares = try await service.listShares()
            print("SMB shares on \(host!): \(shares.isEmpty ? "(none returned)" : shares.joined(separator: ", "))")
            XCTAssertFalse(shares.isEmpty, "Server returned no shares — check credentials or guest access")
        } catch let failure as BrowseFailure {
            XCTFail("listShares failed: \(failure.kind) — \(failure.message) [\(failure.underlyingDescription ?? "no detail")]")
        }
        await service.disconnect()
    }

    // MARK: - Connection

    func test02_Connect() async throws {
        let share = try requireShare()
        let service = makeService(share: share)
        do {
            try await service.connect()
        } catch let failure as BrowseFailure {
            XCTFail("connect failed: \(failure.kind) — \(failure.message) [\(failure.underlyingDescription ?? "no detail")]")
        }
        let connected = await service.isConnected
        XCTAssertTrue(connected)
        await service.disconnect()
    }

    /// The assumption this is really testing: that a rejected password surfaces
    /// as something the app maps to `.authenticationFailed`. The mock asserts
    /// EACCES because that is what the source suggests — this checks reality.
    func test03_WrongPasswordIsAnAuthFailure() async throws {
        let share = try requireShare()
        try XCTSkipIf(user.isEmpty, "Needs a real username; guest shares accept anything")

        let service = SMBService(
            profile: makeProfile(share: share),
            password: "definitely-not-the-password-\(UUID().uuidString)",
            timeout: 20
        )
        do {
            try await service.connect()
            XCTFail("Expected a bad password to be rejected")
        } catch let failure as BrowseFailure {
            print("Bad password produced: kind=\(failure.kind) detail=\(failure.underlyingDescription ?? "none")")
            XCTAssertEqual(
                failure.kind, .authenticationFailed,
                "A rejected password must map to .authenticationFailed, or the failure modal shows the wrong recovery actions"
            )
        }
    }

    /// Checks the timeout mapping against a real unroutable address rather than
    /// a mock that simply throws ETIMEDOUT on demand.
    func test04_UnreachableHostTimesOut() async throws {
        let profile = ServerProfile(
            name: "Nowhere", host: "192.0.2.1", shareName: "any", username: "x"
        )
        let service = SMBService(profile: profile, password: "x", timeout: 5)
        do {
            try await service.connect()
            XCTFail("192.0.2.1 is reserved and must not connect")
        } catch let failure as BrowseFailure {
            print("Unreachable host produced: kind=\(failure.kind) detail=\(failure.underlyingDescription ?? "none")")
            XCTAssertTrue(
                [.timedOut, .hostUnreachable, .connectionRefused].contains(failure.kind),
                "Expected a reachability failure, got \(failure.kind)"
            )
        }
    }

    // MARK: - Browsing

    /// Verifies the path convention the whole app is built on: that `"/"` is the
    /// share root and that listings come back with usable names and paths.
    func test05_ListRootAndPathConventions() async throws {
        let share = try requireShare()
        let service = makeService(share: share)
        let items = try await service.listDirectory(at: "/")
        print("Root of \(share) has \(items.count) items")
        for item in items.prefix(10) {
            print("  \(item.isDirectory ? "DIR " : "FILE") name=\(item.name) path=\(item.path) size=\(item.size)")
        }

        for item in items {
            XCTAssertFalse(item.name.isEmpty, "Every entry must have a name")
            XCTAssertFalse(item.path.isEmpty, "Every entry must have a path")
            XCTAssertFalse(
                item.path.hasSuffix("/"),
                "Directory paths must have the trailing slash stripped, got \(item.path)"
            )
        }
        await service.disconnect()
    }

    // MARK: - Full write cycle

    /// Create → upload → list → download → verify bytes → rename → delete.
    /// Everything is confined to one directory, removed at the end.
    func test06_WriteCycle() async throws {
        let share = try requireShare()
        let service = makeService(share: share)

        let directory = "SimpleSMBTest-\(UUID().uuidString.prefix(8))"
        let payload = Data("simple-smb integration \(UUID().uuidString)".utf8)

        let localSource = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString).txt")
        try payload.write(to: localSource)
        defer { try? FileManager.default.removeItem(at: localSource) }

        do {
            try await service.createDirectory(at: directory)
        } catch let failure as BrowseFailure {
            throw XCTSkip("Share is not writable (\(failure.kind)); read-only checks already ran")
        }

        let directoryItem = FileItem(path: directory, name: directory, isDirectory: true)

        let remotePath = BrowsePath.appending("uploaded.txt", to: directory)
        // Progress callbacks arrive on AMSMB2's own queue, so the flag needs to
        // be reference-typed rather than a captured var.
        let uploadProgressSeen = ProgressFlag()
        try await service.upload(from: localSource, to: remotePath) { transferred, _ in
            if transferred > 0 { uploadProgressSeen.set() }
            return true
        }
        XCTAssertTrue(uploadProgressSeen.value, "Upload should report progress")

        let listing = try await service.listDirectory(at: directory)
        XCTAssertEqual(listing.map(\.name), ["uploaded.txt"])
        XCTAssertEqual(listing.first?.size, Int64(payload.count), "Reported size should match what was written")

        let downloadTarget = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: downloadTarget) }
        try await service.download(from: remotePath, to: downloadTarget)
        XCTAssertEqual(try Data(contentsOf: downloadTarget), payload, "Downloaded bytes must match uploaded bytes")

        // Streaming read — the path QuickLook previews depend on.
        var streamed = Data()
        for try await chunk in try await service.readStream(at: remotePath) {
            streamed.append(chunk)
        }
        XCTAssertEqual(streamed, payload, "Streamed bytes must match uploaded bytes")

        // Rename is a move to a sibling path; this is the convention the app assumes.
        guard let uploaded = listing.first else { return XCTFail("Nothing uploaded") }
        try await service.rename(uploaded, to: "renamed.txt")
        let afterRename = try await service.listDirectory(at: directory)
        XCTAssertEqual(afterRename.map(\.name), ["renamed.txt"])

        for item in afterRename {
            try await service.delete(item)
        }
        let afterDelete = try await service.listDirectory(at: directory)
        XCTAssertTrue(afterDelete.isEmpty, "Directory should be empty after deleting its contents")

        // Remove the test directory itself. This used to be a
        // `defer { Task { ... } }`, which never ran before the test process
        // exited — so every run left a SimpleSMBTest-XXXX directory behind on
        // the server. Cleanup has to be awaited inline.
        try await service.delete(directoryItem)
        let root = try await service.listDirectory(at: "/")
        XCTAssertFalse(
            root.contains { $0.name == directory },
            "The test directory must not be left behind on the server"
        )

        await service.disconnect()
    }

    /// Removes anything an earlier interrupted run left behind, so a failure
    /// mid-cycle doesn't accumulate directories on a real server.
    func test07_CleansUpStrayTestDirectories() async throws {
        let share = try requireShare()
        let service = makeService(share: share)

        let strays = (try await service.listDirectory(at: "/"))
            .filter { $0.isDirectory && $0.name.hasPrefix("SimpleSMBTest-") }
        for stray in strays {
            try? await service.delete(stray)
            print("removed stray test directory: \(stray.name)")
        }

        let remaining = (try await service.listDirectory(at: "/"))
            .filter { $0.name.hasPrefix("SimpleSMBTest-") }
        XCTAssertTrue(remaining.isEmpty, "Stray test directories should be gone")
        await service.disconnect()
    }
}


/// Thread-safe flag for observing progress callbacks off the test's thread.
private final class ProgressFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}
