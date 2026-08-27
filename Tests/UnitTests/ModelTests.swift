import XCTest
@testable import SimpleSMBFileBrowser

final class BrowsePathTests: XCTestCase {
    func testAppendingToRootProducesAbsolutePath() {
        // Matches the absolute .pathKey values AMSMB2 returns from a listing.
        XCTAssertEqual(BrowsePath.appending("Movies", to: "/"), "/Movies")
    }

    func testAppendingToSubdirectory() {
        XCTAssertEqual(BrowsePath.appending("2026", to: "Movies"), "Movies/2026")
    }

    func testAppendingDoesNotDoubleSlash() {
        XCTAssertEqual(BrowsePath.appending("b", to: "a/"), "a/b")
    }

    func testParentOfNestedPath() {
        XCTAssertEqual(BrowsePath.parent(of: "Movies/2026/file.mkv"), "Movies/2026")
    }

    func testParentOfTopLevelReturnsRootMarker() {
        XCTAssertEqual(BrowsePath.parent(of: "Movies"), "")
        XCTAssertEqual(BrowsePath.parent(of: "/Movies"), "/")
    }

    func testParentOfRootIsNil() {
        XCTAssertNil(BrowsePath.parent(of: "/"))
        XCTAssertNil(BrowsePath.parent(of: ""))
    }

    func testBreadcrumbsIncludeRootFirst() {
        let crumbs = BrowsePath.breadcrumbs(for: "Movies/2026", rootTitle: "Media")

        XCTAssertEqual(crumbs.map(\.title), ["Media", "Movies", "2026"])
        XCTAssertEqual(crumbs.map(\.path), ["/", "Movies", "Movies/2026"])
    }

    func testUniqueNameLeavesFreeNameAlone() {
        XCTAssertEqual(BrowsePath.uniqueName(for: "a.txt", avoiding: []), "a.txt")
    }

    func testUniqueNameInsertsCounterBeforeExtension() {
        XCTAssertEqual(BrowsePath.uniqueName(for: "a.txt", avoiding: ["a.txt"]), "a 2.txt")
    }

    func testUniqueNameSkipsRunsOfCollisions() {
        let taken: Set<String> = ["a.txt", "a 2.txt", "a 3.txt"]
        XCTAssertEqual(BrowsePath.uniqueName(for: "a.txt", avoiding: taken), "a 4.txt")
    }

    func testUniqueNameHandlesExtensionlessNames() {
        XCTAssertEqual(BrowsePath.uniqueName(for: "README", avoiding: ["README"]), "README 2")
    }
}

final class SortingTests: XCTestCase {
    private let folder = FileItem.fixture(path: "/B-folder", isDirectory: true)
    private let apple = FileItem.fixture(path: "/apple.txt", size: 300, modified: Date(timeIntervalSince1970: 3_000))
    private let banana = FileItem.fixture(path: "/banana.md", size: 100, modified: Date(timeIntervalSince1970: 1_000))

    func testDirectoriesSortAboveFilesRegardlessOfField() {
        let sorted = [apple, banana, folder].sorted(by: SortOption(field: .size, direction: .ascending))
        XCTAssertEqual(sorted.first?.name, "B-folder")
    }

    func testSortByNameAscending() {
        let sorted = [banana, apple].sorted(by: SortOption(field: .name, direction: .ascending))
        XCTAssertEqual(sorted.map(\.name), ["apple.txt", "banana.md"])
    }

    func testSortByNameDescending() {
        let sorted = [apple, banana].sorted(by: SortOption(field: .name, direction: .descending))
        XCTAssertEqual(sorted.map(\.name), ["banana.md", "apple.txt"])
    }

    func testSortBySize() {
        let sorted = [apple, banana].sorted(by: SortOption(field: .size, direction: .ascending))
        XCTAssertEqual(sorted.map(\.name), ["banana.md", "apple.txt"])
    }

    func testSortByDateModified() {
        let sorted = [apple, banana].sorted(by: SortOption(field: .dateModified, direction: .ascending))
        XCTAssertEqual(sorted.map(\.name), ["banana.md", "apple.txt"])
    }

    func testSortByTypeUsesExtensionThenName() {
        let sorted = [apple, banana].sorted(by: SortOption(field: .type, direction: .ascending))
        // .md sorts before .txt
        XCTAssertEqual(sorted.map(\.name), ["banana.md", "apple.txt"])
    }

    func testNameSortIsNaturalNotLexicographic() {
        let two = FileItem.fixture(path: "/file2.txt")
        let ten = FileItem.fixture(path: "/file10.txt")
        let sorted = [ten, two].sorted(by: SortOption(field: .name, direction: .ascending))
        XCTAssertEqual(sorted.map(\.name), ["file2.txt", "file10.txt"])
    }
}

final class BrowseFailureTests: XCTestCase {
    func testTimeoutMapping() {
        let failure = BrowseFailure(error: POSIXError(.ETIMEDOUT), target: "nas.local")
        XCTAssertEqual(failure.kind, .timedOut)
        XCTAssertTrue(failure.message.contains("nas.local"))
        XCTAssertTrue(failure.suggestsRecoveryApp)
        XCTAssertFalse(failure.suggestsEditingConnection)
    }

    func testAuthMapping() {
        XCTAssertEqual(BrowseFailure(error: POSIXError(.EACCES), target: "h").kind, .authenticationFailed)
        XCTAssertEqual(BrowseFailure(error: POSIXError(.EPERM), target: "h").kind, .authenticationFailed)
    }

    func testUnreachableMapping() {
        XCTAssertEqual(BrowseFailure(error: POSIXError(.EHOSTUNREACH), target: "h").kind, .hostUnreachable)
        XCTAssertEqual(BrowseFailure(error: POSIXError(.ENETDOWN), target: "h").kind, .hostUnreachable)
    }

    func testCocoaNotFoundMapping() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        XCTAssertEqual(BrowseFailure(error: error, target: "iCloud Drive").kind, .notFound)
    }

    func testCocoaExistsMapping() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError)
        XCTAssertEqual(BrowseFailure(error: error, target: "x").kind, .alreadyExists)
    }

    func testLocalVariantTreatsEaccesAsPermission() {
        // Locally, EACCES means the file, not a rejected login.
        let remote = BrowseFailure(error: POSIXError(.EACCES), target: "nas")
        let local = BrowseFailure(localError: POSIXError(.EACCES), target: "On My Mac")
        XCTAssertEqual(remote.kind, .authenticationFailed)
        XCTAssertEqual(local.kind, .permissionDenied)
    }

    func testCancellationMapping() {
        XCTAssertEqual(BrowseFailure(error: CancellationError(), target: "h").kind, .cancelled)
    }

    func testPassthroughOfExistingFailure() {
        let original = BrowseFailure(kind: .shareNotFound, target: "nas")
        let wrapped = BrowseFailure(error: original, target: "ignored")
        XCTAssertEqual(wrapped.kind, .shareNotFound)
        XCTAssertEqual(wrapped.target, "nas")
    }

    func testUnknownErrorKeepsUnderlyingDescription() {
        let error = NSError(
            domain: "com.example", code: 99,
            userInfo: [NSLocalizedDescriptionKey: "something odd"]
        )
        let failure = BrowseFailure(error: error, target: "nas")
        XCTAssertEqual(failure.kind, .other)
        XCTAssertTrue(failure.message.contains("something odd"))
    }

    func testEmptyTargetFallsBackToGenericWording() {
        let failure = BrowseFailure(kind: .timedOut, target: "")
        XCTAssertTrue(failure.message.contains("the server"))
    }
}

final class ServerProfileTests: XCTestCase {
    func testSMBURLOmitsDefaultPort() {
        let profile = ServerProfile.fixture(host: "nas.local", port: 445)
        XCTAssertEqual(profile.smbURL?.absoluteString, "smb://nas.local")
    }

    func testSMBURLIncludesNonDefaultPort() {
        let profile = ServerProfile.fixture(host: "nas.local", port: 4450)
        XCTAssertEqual(profile.smbURL?.absoluteString, "smb://nas.local:4450")
    }

    func testEmptyHostHasNoURL() {
        XCTAssertNil(ServerProfile.fixture(host: "").smbURL)
    }

    func testValidationRequiresHost() {
        XCTAssertEqual(ServerProfile.fixture(host: "").validationError, "Host or IP address is required.")
    }

    func testValidationRequiresShare() {
        XCTAssertEqual(ServerProfile.fixture(share: "").validationError, "Share name is required.")
    }

    func testValidationRejectsOutOfRangePort() {
        XCTAssertNotNil(ServerProfile.fixture(port: 0).validationError)
        XCTAssertNotNil(ServerProfile.fixture(port: 70_000).validationError)
    }

    func testValidProfilePasses() {
        XCTAssertTrue(ServerProfile.fixture().isValid)
    }

    func testDisplayNameFallsBackToHost() {
        XCTAssertEqual(ServerProfile.fixture(name: "  ", host: "10.0.0.4").displayName, "10.0.0.4")
    }

    func testSubtitleShowsHostAndShare() {
        XCTAssertEqual(ServerProfile.fixture(host: "nas", share: "Media").subtitle, "nas/Media")
    }

    func testSubtitleIncludesNonDefaultPort() {
        XCTAssertEqual(ServerProfile.fixture(host: "nas", port: 4450, share: "Media").subtitle, "nas:4450/Media")
    }

    func testProfileCodableRoundTripCarriesNoPassword() throws {
        let profile = ServerProfile.fixture()
        let data = try JSONEncoder().encode(profile)
        // The password is intentionally not part of the model.
        XCTAssertFalse(String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains("password"))
        XCTAssertEqual(try JSONDecoder().decode(ServerProfile.self, from: data), profile)
    }
}

final class FileItemTests: XCTestCase {
    func testDirectorySymbol() {
        XCTAssertEqual(FileItem.fixture(path: "/d", isDirectory: true).symbolName, "folder.fill")
    }

    func testImageIsPreviewable() {
        XCTAssertTrue(FileItem.fixture(path: "/photo.jpg").isPreviewable)
    }

    func testPDFIsPreviewable() {
        XCTAssertTrue(FileItem.fixture(path: "/doc.pdf").isPreviewable)
    }

    func testUnknownBinaryIsNotPreviewable() {
        XCTAssertFalse(FileItem.fixture(path: "/firmware.bin2xyz").isPreviewable)
    }

    func testDirectoryHasNoFormattedSize() {
        XCTAssertNil(FileItem.fixture(path: "/d", isDirectory: true).formattedSize)
    }

    func testFileExtensionIsLowercased() {
        XCTAssertEqual(FileItem.fixture(path: "/A.TXT").fileExtension, "txt")
    }

    func testSMBAttributeMappingStripsTrailingSlashOnDirectories() {
        let attributes: [URLResourceKey: Any] = [
            .nameKey: "Movies",
            .pathKey: "/Movies/",
            .isDirectoryKey: NSNumber(value: true),
            .fileSizeKey: NSNumber(value: 4096),
        ]
        let item = FileItem(smbAttributes: attributes)
        XCTAssertEqual(item?.path, "/Movies")
        XCTAssertTrue(item?.isDirectory == true)
        XCTAssertEqual(item?.size, 0, "Directories should not report a size")
    }

    func testSMBAttributeMappingTreatsEpochZeroAsNoDate() {
        let attributes: [URLResourceKey: Any] = [
            .nameKey: "old.txt",
            .pathKey: "/old.txt",
            .isDirectoryKey: NSNumber(value: false),
            .contentModificationDateKey: Date(timeIntervalSince1970: 0),
        ]
        // Servers that don't track mtime report 0, which would otherwise show
        // as 1 January 1970.
        XCTAssertNil(FileItem(smbAttributes: attributes)?.modifiedDate)
    }

    func testSMBAttributeMappingRequiresAPath() {
        XCTAssertNil(FileItem(smbAttributes: [.nameKey: "orphan"]))
    }
}

final class TransferModelTests: XCTestCase {
    func testFractionIsNilWhenTotalUnknown() {
        let transfer = Transfer(fileName: "a", direction: .upload, destinationLabel: "nas")
        XCTAssertNil(transfer.fractionCompleted)
    }

    func testFractionIsClamped() {
        var transfer = Transfer(fileName: "a", direction: .upload, destinationLabel: "nas", totalBytes: 100)
        transfer.transferredBytes = 250
        XCTAssertEqual(transfer.fractionCompleted, 1)
    }

    func testStateFinishedFlags() {
        XCTAssertFalse(TransferState.active.isFinished)
        XCTAssertFalse(TransferState.waiting.isFinished)
        XCTAssertTrue(TransferState.completed.isFinished)
        XCTAssertTrue(TransferState.cancelled.isFinished)
        XCTAssertTrue(TransferState.failed(BrowseFailure(kind: .other, target: "x")).isFinished)
    }

    func testProgressDescriptionWithoutTotal() {
        var transfer = Transfer(fileName: "a", direction: .download, destinationLabel: "x")
        transfer.transferredBytes = 2048
        XCTAssertFalse(transfer.progressDescription.contains("of"))
    }
}

final class RecoveryAppTests: XCTestCase {
    func testLaunchURLBuildsFromScheme() {
        XCTAssertEqual(RecoveryApp(name: "Tailscale", scheme: "tailscale").launchURL?.absoluteString, "tailscale://")
    }

    func testLaunchURLTolerantOfPastedScheme() {
        // Users paste "tailscale://" or "tailscale:" — both should work.
        XCTAssertEqual(RecoveryApp(name: "T", scheme: "tailscale://").launchURL?.absoluteString, "tailscale://")
        XCTAssertEqual(RecoveryApp(name: "T", scheme: "tailscale:").launchURL?.absoluteString, "tailscale://")
    }

    func testEmptySchemeHasNoURL() {
        XCTAssertNil(RecoveryApp(name: "T", scheme: "   ").launchURL)
    }
}
