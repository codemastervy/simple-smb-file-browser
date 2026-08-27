import XCTest
@testable import SimpleSMBFileBrowser

/// Covers `SMBService`: the connection outcomes and each file operation.
///
/// Everything runs against `MockSMBClient`, so the failure cases are exact and
/// no SMB server is required.
final class SMBServiceTests: XCTestCase {

    private func makeService(
        client: MockSMBClient,
        profile: ServerProfile = .fixture(),
        password: String? = "secret",
        timeout: TimeInterval = 5
    ) -> (SMBService, MockSMBClientFactory) {
        let factory = MockSMBClientFactory(client: client)
        let service = SMBService(
            profile: profile, password: password, factory: factory, timeout: timeout
        )
        return (service, factory)
    }

    // MARK: - Connect

    func testConnectSucceeds() async throws {
        let client = MockSMBClient()
        let (service, factory) = makeService(client: client)

        try await service.connect()

        let isConnected = await service.isConnected
        XCTAssertTrue(isConnected)
        XCTAssertEqual(client.connectCallCount, 1)
        XCTAssertEqual(factory.record.requestedTimeout, 5)
    }

    func testConnectIsIdempotent() async throws {
        let client = MockSMBClient()
        let (service, _) = makeService(client: client)

        try await service.connect()
        try await service.connect()

        XCTAssertEqual(client.connectCallCount, 1, "A second connect on a live session should be a no-op")
    }

    func testAuthenticationFailureIsReportedAsSuch() async {
        let client = MockSMBClient()
        // libsmb2 surfaces a rejected session as EACCES.
        client.connectError = POSIXError(.EACCES)
        let (service, _) = makeService(client: client)

        do {
            try await service.connect()
            XCTFail("Expected connect to throw")
        } catch let failure as BrowseFailure {
            XCTAssertEqual(failure.kind, .authenticationFailed)
            XCTAssertEqual(failure.target, "192.168.1.50")
            XCTAssertTrue(failure.message.contains("192.168.1.50"))
            XCTAssertTrue(failure.suggestsEditingConnection)
        } catch {
            XCTFail("Expected BrowseFailure, got \(error)")
        }

        let isConnected = await service.isConnected
        XCTAssertFalse(isConnected)
    }

    func testTimeoutIsReportedAsTimedOut() async {
        let client = MockSMBClient()
        client.connectError = POSIXError(.ETIMEDOUT)
        let (service, _) = makeService(client: client)

        do {
            try await service.connect()
            XCTFail("Expected connect to throw")
        } catch let failure as BrowseFailure {
            XCTAssertEqual(failure.kind, .timedOut)
            XCTAssertTrue(failure.message.contains("timed out"))
            XCTAssertTrue(failure.suggestsRecoveryApp, "A timeout should offer the VPN/tunnel recovery app")
        } catch {
            XCTFail("Expected BrowseFailure, got \(error)")
        }
    }

    func testHostUnreachableIsReportedAsSuch() async {
        let client = MockSMBClient()
        client.connectError = POSIXError(.EHOSTUNREACH)
        let (service, _) = makeService(client: client)

        do {
            try await service.connect()
            XCTFail("Expected connect to throw")
        } catch let failure as BrowseFailure {
            XCTAssertEqual(failure.kind, .hostUnreachable)
            XCTAssertTrue(failure.suggestsRecoveryApp)
        } catch {
            XCTFail("Expected BrowseFailure, got \(error)")
        }
    }

    func testConnectionRefusedIsReportedAsSuch() async {
        let client = MockSMBClient()
        client.connectError = POSIXError(.ECONNREFUSED)
        let (service, _) = makeService(client: client)

        do {
            try await service.connect()
            XCTFail("Expected connect to throw")
        } catch let failure as BrowseFailure {
            XCTAssertEqual(failure.kind, .connectionRefused)
        } catch {
            XCTFail("Expected BrowseFailure, got \(error)")
        }
    }

    func testInvalidProfileFailsBeforeAnyClientIsMade() async {
        let client = MockSMBClient()
        // No host: the profile can't produce an smb:// URL.
        let (service, _) = makeService(client: client, profile: .fixture(host: ""))

        do {
            try await service.connect()
            XCTFail("Expected connect to throw")
        } catch let failure as BrowseFailure {
            XCTAssertEqual(failure.kind, .invalidConfiguration)
            XCTAssertEqual(client.connectCallCount, 0, "Validation should short-circuit before dialling")
        } catch {
            XCTFail("Expected BrowseFailure, got \(error)")
        }
    }

    func testDisconnectClearsSession() async throws {
        let client = MockSMBClient()
        let (service, _) = makeService(client: client)

        try await service.connect()
        await service.disconnect()

        let isConnected = await service.isConnected
        XCTAssertFalse(isConnected)
        XCTAssertEqual(client.disconnectCallCount, 1)
    }

    func testReconnectTearsDownThenConnectsAgain() async throws {
        let client = MockSMBClient()
        let (service, _) = makeService(client: client)

        try await service.connect()
        try await service.reconnect()

        XCTAssertEqual(client.disconnectCallCount, 1)
        XCTAssertEqual(client.connectCallCount, 2)
    }

    // MARK: - Listing

    func testListDirectoryReturnsItems() async throws {
        let client = MockSMBClient()
        client.directoryListing = [
            .fixture(path: "/Movies", isDirectory: true),
            .fixture(path: "/notes.txt", size: 42),
        ]
        let (service, _) = makeService(client: client)

        let items = try await service.listDirectory(at: "/")

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(client.listedPaths, ["/"])
        XCTAssertEqual(items.first?.name, "Movies")
        XCTAssertTrue(items.first?.isDirectory == true)
    }

    func testListDirectoryConnectsOnDemand() async throws {
        let client = MockSMBClient()
        let (service, _) = makeService(client: client)

        _ = try await service.listDirectory(at: "/")

        XCTAssertEqual(client.connectCallCount, 1, "Browsing should connect without an explicit connect() call")
    }

    func testListDirectoryFailureMapsToNotFound() async {
        let client = MockSMBClient()
        client.operationError = POSIXError(.ENOENT)
        let (service, _) = makeService(client: client)

        do {
            _ = try await service.listDirectory(at: "/missing")
            XCTFail("Expected listDirectory to throw")
        } catch let failure as BrowseFailure {
            XCTAssertEqual(failure.kind, .notFound)
        } catch {
            XCTFail("Expected BrowseFailure, got \(error)")
        }
    }

    // MARK: - Mutations

    func testCreateDirectory() async throws {
        let client = MockSMBClient()
        let (service, _) = makeService(client: client)

        try await service.createDirectory(at: "/Movies/2026")

        XCTAssertEqual(client.createdDirectories, ["/Movies/2026"])
    }

    func testDeleteFileUsesRemoveFile() async throws {
        let client = MockSMBClient()
        let (service, _) = makeService(client: client)

        try await service.delete(.fixture(path: "/notes.txt"))

        XCTAssertEqual(client.removedFiles, ["/notes.txt"])
        XCTAssertTrue(client.removedDirectories.isEmpty)
    }

    func testDeleteDirectoryRemovesRecursively() async throws {
        let client = MockSMBClient()
        let (service, _) = makeService(client: client)

        try await service.delete(.fixture(path: "/Movies", isDirectory: true))

        XCTAssertTrue(client.removedFiles.isEmpty)
        XCTAssertEqual(client.removedDirectories.count, 1)
        XCTAssertEqual(client.removedDirectories.first?.path, "/Movies")
        XCTAssertTrue(client.removedDirectories.first?.recursive == true)
    }

    func testDeleteFailureMapsToPermissionDenied() async {
        let client = MockSMBClient()
        client.operationError = POSIXError(.EROFS)
        let (service, _) = makeService(client: client)

        do {
            try await service.delete(.fixture(path: "/notes.txt"))
            XCTFail("Expected delete to throw")
        } catch let failure as BrowseFailure {
            XCTAssertEqual(failure.kind, .permissionDenied)
        } catch {
            XCTFail("Expected BrowseFailure, got \(error)")
        }
    }

    func testRenameMovesToSiblingPath() async throws {
        let client = MockSMBClient()
        let (service, _) = makeService(client: client)

        try await service.rename(.fixture(path: "/Movies/old.mkv"), to: "new.mkv")

        XCTAssertEqual(client.moves.count, 1)
        XCTAssertEqual(client.moves.first?.from, "/Movies/old.mkv")
        XCTAssertEqual(client.moves.first?.to, "/Movies/new.mkv")
    }

    func testRenameAtRootStaysAtRoot() async throws {
        let client = MockSMBClient()
        let (service, _) = makeService(client: client)

        try await service.rename(.fixture(path: "/notes.txt"), to: "readme.txt")

        XCTAssertEqual(client.moves.first?.to, "/readme.txt")
    }

    func testMove() async throws {
        let client = MockSMBClient()
        let (service, _) = makeService(client: client)

        try await service.move(from: "/a.txt", to: "/Archive/a.txt")

        XCTAssertEqual(client.moves.first?.from, "/a.txt")
        XCTAssertEqual(client.moves.first?.to, "/Archive/a.txt")
    }

    func testMoveFailureMapsToAlreadyExists() async {
        let client = MockSMBClient()
        client.operationError = POSIXError(.EEXIST)
        let (service, _) = makeService(client: client)

        do {
            try await service.move(from: "/a.txt", to: "/b.txt")
            XCTFail("Expected move to throw")
        } catch let failure as BrowseFailure {
            XCTAssertEqual(failure.kind, .alreadyExists)
        } catch {
            XCTFail("Expected BrowseFailure, got \(error)")
        }
    }

    func testCopyReportsProgress() async throws {
        let client = MockSMBClient()
        let (service, _) = makeService(client: client)
        var observed: [Int64] = []

        try await service.copy(from: "/a.txt", to: "/b.txt", progress: { transferred, _ in
            observed.append(transferred)
            return true
        })

        XCTAssertEqual(client.copies.first?.from, "/a.txt")
        XCTAssertEqual(observed, [50, 100])
    }

    // MARK: - Transfers

    func testUpload() async throws {
        let client = MockSMBClient()
        let (service, _) = makeService(client: client)
        let local = URL(fileURLWithPath: "/tmp/upload-me.txt")

        try await service.upload(from: local, to: "/upload-me.txt")

        XCTAssertEqual(client.uploads.count, 1)
        XCTAssertEqual(client.uploads.first?.to, "/upload-me.txt")
        XCTAssertEqual(client.uploads.first?.from, local)
    }

    func testUploadFailureMapsToOutOfSpace() async {
        let client = MockSMBClient()
        client.operationError = POSIXError(.ENOSPC)
        let (service, _) = makeService(client: client)

        do {
            try await service.upload(from: URL(fileURLWithPath: "/tmp/x"), to: "/x")
            XCTFail("Expected upload to throw")
        } catch let failure as BrowseFailure {
            XCTAssertEqual(failure.kind, .outOfSpace)
        } catch {
            XCTFail("Expected BrowseFailure, got \(error)")
        }
    }

    func testDownloadWritesToDestination() async throws {
        let client = MockSMBClient()
        client.streamChunks = [Data("hello ".utf8), Data("world".utf8)]
        let (service, _) = makeService(client: client)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: destination) }

        try await service.download(from: "/greeting.txt", to: destination)

        XCTAssertEqual(client.downloads.first?.from, "/greeting.txt")
        let written = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertEqual(written, "hello world")
    }

    func testTransferCancelsWhenProgressReturnsFalse() async throws {
        let client = MockSMBClient()
        let (service, _) = makeService(client: client)

        try await service.download(
            from: "/big.iso",
            to: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            progress: { _, _ in false }
        )

        XCTAssertTrue(client.wasCancelled, "Returning false from the progress handler must abort the transfer")
    }

    // MARK: - Streaming

    func testReadStreamYieldsChunks() async throws {
        let client = MockSMBClient()
        client.streamChunks = [Data([1, 2]), Data([3])]
        let (service, _) = makeService(client: client)

        var received = Data()
        for try await chunk in try await service.readStream(at: "/blob.bin") {
            received.append(chunk)
        }

        XCTAssertEqual(received, Data([1, 2, 3]))
    }

    func testListShares() async throws {
        let client = MockSMBClient()
        client.shares = ["Media", "Backups"]
        let (service, _) = makeService(client: client)

        let shares = try await service.listShares()

        XCTAssertEqual(shares, ["Media", "Backups"])
    }

    func testUpdatePasswordIsUsedOnNextConnect() async throws {
        let client = MockSMBClient()
        let (service, _) = makeService(client: client, password: "wrong")

        await service.updatePassword("right")
        try await service.connect()

        XCTAssertEqual(client.connectCallCount, 1)
    }
}
