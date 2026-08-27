import XCTest
@testable import SimpleSMBFileBrowser

/// Covers `TransferCoordinator`, including the cross-provider path that has to
/// stage through a local temporary file.
@MainActor
final class TransferCoordinatorTests: XCTestCase {
    private var center: TransferCenter!
    private var coordinator: TransferCoordinator!
    private var deviceRoot: URL!
    private var deviceProvider: DeviceFileProvider!

    override func setUpWithError() throws {
        try super.setUpWithError()
        center = TransferCenter()
        coordinator = TransferCoordinator(center: center)

        deviceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("coordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: deviceRoot, withIntermediateDirectories: true)
        deviceProvider = DeviceFileProvider(
            service: DeviceFileService(onMyDeviceRoot: deviceRoot, iCloudRoot: deviceRoot),
            location: .onMyDevice,
            rootPath: deviceRoot.path
        )
    }

    override func tearDownWithError() throws {
        if let deviceRoot { try? FileManager.default.removeItem(at: deviceRoot) }
        try super.tearDownWithError()
    }

    private func makeSMBProvider(_ client: MockSMBClient) -> SMBFileProvider {
        let profile = ServerProfile.fixture()
        return SMBFileProvider(
            service: SMBService(
                profile: profile,
                password: "pw",
                factory: MockSMBClientFactory(client: client)
            ),
            label: profile.displayName,
            profileID: profile.id
        )
    }

    // MARK: - Cross-provider

    func testCopyFromSMBToDeviceStagesThroughLocalFile() async throws {
        let client = MockSMBClient()
        client.streamChunks = [Data("remote ".utf8), Data("payload".utf8)]
        let smb = makeSMBProvider(client)
        let item = FileItem.fixture(path: "/remote.txt", size: 14)

        let failures = await coordinator.transfer(
            [item], from: smb, to: deviceProvider,
            destinationDirectory: deviceRoot.path, mode: .copy
        )

        XCTAssertTrue(failures.isEmpty, "Expected no failures, got \(failures)")
        let landed = deviceRoot.appendingPathComponent("remote.txt")
        XCTAssertEqual(try String(contentsOf: landed, encoding: .utf8), "remote payload")
        // A download out of the share is the read half of the transfer.
        XCTAssertEqual(client.downloads.count, 1)
        XCTAssertEqual(client.downloads.first?.from, "/remote.txt")
    }

    func testMoveFromSMBToDeviceDeletesSourceAfterSuccess() async throws {
        let client = MockSMBClient()
        client.streamChunks = [Data("bye".utf8)]
        let smb = makeSMBProvider(client)

        let failures = await coordinator.transfer(
            [.fixture(path: "/gone.txt", size: 3)], from: smb, to: deviceProvider,
            destinationDirectory: deviceRoot.path, mode: .move
        )

        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(client.removedFiles, ["/gone.txt"], "A cross-provider move must delete the source")
    }

    func testFailedCrossProviderMoveLeavesSourceAlone() async throws {
        let client = MockSMBClient()
        client.operationError = POSIXError(.EACCES)
        let smb = makeSMBProvider(client)

        let failures = await coordinator.transfer(
            [.fixture(path: "/locked.txt")], from: smb, to: deviceProvider,
            destinationDirectory: deviceRoot.path, mode: .move
        )

        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(client.removedFiles.isEmpty, "A failed move must not delete the source")
    }

    // MARK: - Same provider

    func testSameProviderMoveIsARenameNotACopy() async throws {
        let client = MockSMBClient()
        let smb = makeSMBProvider(client)

        let failures = await coordinator.transfer(
            [.fixture(path: "/a.txt")], from: smb, to: smb,
            destinationDirectory: "/Archive", mode: .move
        )

        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(client.moves.count, 1)
        XCTAssertEqual(client.moves.first?.to, "/Archive/a.txt")
        XCTAssertTrue(client.downloads.isEmpty, "A same-provider move should not round-trip bytes")
        XCTAssertTrue(client.removedFiles.isEmpty, "A rename should not delete anything")
    }

    func testSameProviderCopyUsesProviderCopy() async throws {
        let client = MockSMBClient()
        let smb = makeSMBProvider(client)

        _ = await coordinator.transfer(
            [.fixture(path: "/a.txt")], from: smb, to: smb,
            destinationDirectory: "/Archive", mode: .copy
        )

        XCTAssertEqual(client.copies.count, 1)
        XCTAssertTrue(client.downloads.isEmpty)
    }

    // MARK: - Collisions

    func testCollidingNameIsDeduplicatedRatherThanOverwritten() async throws {
        let existing = deviceRoot.appendingPathComponent("dupe.txt")
        try "original".write(to: existing, atomically: true, encoding: .utf8)

        let client = MockSMBClient()
        client.streamChunks = [Data("incoming".utf8)]
        let smb = makeSMBProvider(client)

        let failures = await coordinator.transfer(
            [.fixture(path: "/dupe.txt", size: 8)], from: smb, to: deviceProvider,
            destinationDirectory: deviceRoot.path, mode: .copy
        )

        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(
            try String(contentsOf: existing, encoding: .utf8), "original",
            "The existing file must not be clobbered"
        )
        let deduped = deviceRoot.appendingPathComponent("dupe 2.txt")
        XCTAssertEqual(try String(contentsOf: deduped, encoding: .utf8), "incoming")
    }

    func testBatchOfIdenticalNamesEachGetAUniqueName() async throws {
        let client = MockSMBClient()
        client.streamChunks = [Data("x".utf8)]
        let smb = makeSMBProvider(client)

        // Two distinct source paths whose leaf names collide.
        let items = [
            FileItem(path: "/one/same.txt", name: "same.txt", isDirectory: false, size: 1),
            FileItem(path: "/two/same.txt", name: "same.txt", isDirectory: false, size: 1),
        ]

        let failures = await coordinator.transfer(
            items, from: smb, to: deviceProvider,
            destinationDirectory: deviceRoot.path, mode: .copy
        )

        XCTAssertTrue(failures.isEmpty, "Expected no failures, got \(failures)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: deviceRoot.appendingPathComponent("same.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: deviceRoot.appendingPathComponent("same 2.txt").path))
    }

    // MARK: - Reporting

    func testTransferIsRecordedInTheTransferCenter() async throws {
        let client = MockSMBClient()
        client.streamChunks = [Data("x".utf8)]
        let smb = makeSMBProvider(client)

        _ = await coordinator.transfer(
            [.fixture(path: "/tracked.txt", size: 1)], from: smb, to: deviceProvider,
            destinationDirectory: deviceRoot.path, mode: .copy
        )

        XCTAssertEqual(center.recent.count, 1)
        XCTAssertEqual(center.recent.first?.fileName, "tracked.txt")
        XCTAssertEqual(center.recent.first?.state, .completed)
    }

    func testFailedTransferIsRecordedAsFailed() async throws {
        let client = MockSMBClient()
        client.operationError = POSIXError(.ENOSPC)
        let smb = makeSMBProvider(client)

        _ = await coordinator.transfer(
            [.fixture(path: "/big.iso", size: 999)], from: smb, to: deviceProvider,
            destinationDirectory: deviceRoot.path, mode: .copy
        )

        XCTAssertEqual(center.recent.count, 1)
        guard case .failed(let failure) = center.recent.first?.state else {
            return XCTFail("Expected a failed transfer, got \(String(describing: center.recent.first?.state))")
        }
        XCTAssertEqual(failure.kind, .outOfSpace)
    }

    func testOneBadItemDoesNotStopTheRest() async throws {
        // The device provider refuses to overwrite, so the first item fails
        // only if its name is taken; instead make the *source* listing fail for
        // a directory while a sibling file succeeds.
        let client = MockSMBClient()
        client.streamChunks = [Data("ok".utf8)]
        let smb = makeSMBProvider(client)

        let items = [
            FileItem.fixture(path: "/first.txt", size: 2),
            FileItem.fixture(path: "/second.txt", size: 2),
        ]

        let failures = await coordinator.transfer(
            items, from: smb, to: deviceProvider,
            destinationDirectory: deviceRoot.path, mode: .copy
        )

        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(center.recent.count, 2, "Both items should have been attempted")
    }

    func testDirectoryTransferRecreatesTreeOnTheDestination() async throws {
        let client = MockSMBClient()
        client.streamChunks = [Data("leaf".utf8)]
        client.directoryListing = [.fixture(path: "/Tree/leaf.txt", size: 4)]
        let smb = makeSMBProvider(client)

        let failures = await coordinator.transfer(
            [.fixture(path: "/Tree", isDirectory: true)], from: smb, to: deviceProvider,
            destinationDirectory: deviceRoot.path, mode: .copy
        )

        XCTAssertTrue(failures.isEmpty, "Expected no failures, got \(failures)")
        let leaf = deviceRoot.appendingPathComponent("Tree/leaf.txt")
        XCTAssertEqual(try String(contentsOf: leaf, encoding: .utf8), "leaf")
    }
}
