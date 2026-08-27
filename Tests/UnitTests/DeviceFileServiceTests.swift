import XCTest
@testable import SimpleSMBFileBrowser

/// Covers `DeviceFileService` against a real temporary directory, which is
/// exactly how it behaves in the app — just rooted somewhere disposable.
final class DeviceFileServiceTests: XCTestCase {
    private var root: URL!
    private var service: DeviceFileService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("device-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = DeviceFileService(onMyDeviceRoot: root, iCloudRoot: root)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        service = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func write(_ contents: String, to name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Roots

    func testRootsUseOverrides() async throws {
        let onDevice = await service.onMyDeviceRoot
        let iCloud = await service.iCloudDriveRoot
        XCTAssertEqual(onDevice, root)
        XCTAssertEqual(iCloud, root)
        let resolved = try await service.root(for: .onMyDevice)
        XCTAssertEqual(resolved, root)
    }

    // MARK: - Listing

    func testListDirectoryReturnsFilesAndFolders() async throws {
        _ = try write("hello", to: "a.txt")
        _ = try makeDirectory("Folder")

        let items = try await service.listDirectory(atPath: root.path)

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(Set(items.map(\.name)), ["a.txt", "Folder"])
        XCTAssertTrue(items.first(where: { $0.name == "Folder" })?.isDirectory == true)
    }

    func testListDirectoryReportsFileSize() async throws {
        _ = try write("12345", to: "size.txt")

        let items = try await service.listDirectory(atPath: root.path)

        XCTAssertEqual(items.first?.size, 5)
    }

    func testDirectoriesReportZeroSize() async throws {
        _ = try makeDirectory("Empty")

        let items = try await service.listDirectory(atPath: root.path)

        XCTAssertEqual(items.first?.size, 0)
    }

    func testListMissingDirectoryThrowsNotFound() async {
        do {
            _ = try await service.listDirectory(atPath: root.appendingPathComponent("nope").path)
            XCTFail("Expected listDirectory to throw")
        } catch let failure as BrowseFailure {
            XCTAssertEqual(failure.kind, .notFound)
        } catch {
            XCTFail("Expected BrowseFailure, got \(error)")
        }
    }

    func testRecursiveListingIncludesNestedFiles() async throws {
        let nested = try makeDirectory("Outer/Inner")
        try "deep".write(to: nested.appendingPathComponent("deep.txt"), atomically: true, encoding: .utf8)

        let items = try await service.listDirectory(atPath: root.path, recursive: true)

        XCTAssertTrue(items.contains { $0.name == "deep.txt" })
    }

    // MARK: - Create

    func testCreateDirectory() async throws {
        let target = root.appendingPathComponent("New", isDirectory: true)

        try await service.createDirectory(atPath: target.path)

        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testCreateDirectoryThatExistsThrowsAlreadyExists() async throws {
        let existing = try makeDirectory("Dupe")

        do {
            try await service.createDirectory(atPath: existing.path)
            XCTFail("Expected createDirectory to throw")
        } catch let failure as BrowseFailure {
            XCTAssertEqual(failure.kind, .alreadyExists)
        } catch {
            XCTFail("Expected BrowseFailure, got \(error)")
        }
    }

    // MARK: - Delete

    func testDeleteFile() async throws {
        let url = try write("bye", to: "delete-me.txt")
        let item = try await service.attributes(atPath: url.path)

        try await service.delete(item)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDeleteDirectoryRemovesContents() async throws {
        let directory = try makeDirectory("Tree")
        try "x".write(to: directory.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        let item = try await service.attributes(atPath: directory.path)

        try await service.delete(item)

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testDeleteMissingItemThrowsNotFound() async {
        let phantom = FileItem.fixture(path: root.appendingPathComponent("ghost.txt").path)

        do {
            try await service.delete(phantom)
            XCTFail("Expected delete to throw")
        } catch let failure as BrowseFailure {
            XCTAssertEqual(failure.kind, .notFound)
        } catch {
            XCTFail("Expected BrowseFailure, got \(error)")
        }
    }

    // MARK: - Rename and move

    func testRename() async throws {
        let url = try write("content", to: "before.txt")
        let item = try await service.attributes(atPath: url.path)

        try await service.rename(item, to: "after.txt")

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("after.txt").path))
    }

    func testRenameOntoExistingNameThrowsAlreadyExists() async throws {
        let url = try write("a", to: "one.txt")
        _ = try write("b", to: "two.txt")
        let item = try await service.attributes(atPath: url.path)

        do {
            try await service.rename(item, to: "two.txt")
            XCTFail("Expected rename to throw")
        } catch let failure as BrowseFailure {
            XCTAssertEqual(failure.kind, .alreadyExists)
        } catch {
            XCTFail("Expected BrowseFailure, got \(error)")
        }
    }

    func testMoveIntoSubdirectory() async throws {
        let url = try write("moving", to: "mover.txt")
        let destination = try makeDirectory("Dest")
        let target = destination.appendingPathComponent("mover.txt")

        try await service.move(fromPath: url.path, toPath: target.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    // MARK: - Copy

    func testCopyLeavesOriginalInPlace() async throws {
        let url = try write("duplicate me", to: "src.txt")
        let target = root.appendingPathComponent("copy.txt")

        try await service.copy(fromPath: url.path, toPath: target.path)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "duplicate me")
    }

    func testCopyOntoExistingPathThrowsAlreadyExists() async throws {
        let url = try write("a", to: "from.txt")
        _ = try write("b", to: "to.txt")

        do {
            try await service.copy(fromPath: url.path, toPath: root.appendingPathComponent("to.txt").path)
            XCTFail("Expected copy to throw")
        } catch let failure as BrowseFailure {
            XCTAssertEqual(failure.kind, .alreadyExists)
        } catch {
            XCTFail("Expected BrowseFailure, got \(error)")
        }
    }

    // MARK: - Name collision support

    func testExistingNamesReportsDirectoryContents() async throws {
        _ = try write("a", to: "one.txt")
        _ = try makeDirectory("Two")

        let names = await service.existingNames(inDirectory: root.path)

        XCTAssertEqual(names, ["one.txt", "Two"])
    }

    func testAttributesOfFile() async throws {
        let url = try write("seven!!", to: "attrs.txt")

        let item = try await service.attributes(atPath: url.path)

        XCTAssertEqual(item.name, "attrs.txt")
        XCTAssertEqual(item.size, 7)
        XCTAssertFalse(item.isDirectory)
        XCTAssertNotNil(item.modifiedDate)
    }
}
