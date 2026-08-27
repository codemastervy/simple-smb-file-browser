import Foundation
@testable import SimpleSMBFileBrowser

/// Programmable `SMBClient` double.
///
/// This is what lets the failure paths be tested at all: an auth rejection, an
/// unreachable host and a timeout are all `POSIXError`s from libsmb2 in
/// production, and none of them can be provoked reliably against a real server.
final class MockSMBClient: SMBClient, @unchecked Sendable {
    /// Thrown by `connect()` when set.
    var connectError: (any Error)?
    /// Thrown by every browsing/mutating call when set.
    var operationError: (any Error)?

    var directoryListing: [FileItem] = []
    var shares: [String] = []
    var streamChunks: [Data] = []

    // Recorded calls, so tests can assert the service passed the right paths.
    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0
    private(set) var listedPaths: [String] = []
    private(set) var createdDirectories: [String] = []
    private(set) var removedFiles: [String] = []
    private(set) var removedDirectories: [(path: String, recursive: Bool)] = []
    private(set) var moves: [(from: String, to: String)] = []
    private(set) var copies: [(from: String, to: String)] = []
    private(set) var uploads: [(from: URL, to: String)] = []
    private(set) var downloads: [(from: String, to: URL)] = []

    /// Bytes reported through the progress handler for transfers.
    var progressSteps: [(transferred: Int64, total: Int64)] = [(50, 100), (100, 100)]
    /// Set when a progress handler returned false, i.e. the caller cancelled.
    private(set) var wasCancelled = false

    func connect() async throws {
        connectCallCount += 1
        if let connectError { throw connectError }
    }

    func disconnect() async {
        disconnectCallCount += 1
    }

    func listShares() async throws -> [String] {
        if let operationError { throw operationError }
        return shares
    }

    func listDirectory(at path: String, recursive: Bool) async throws -> [FileItem] {
        listedPaths.append(path)
        if let operationError { throw operationError }
        return directoryListing
    }

    func attributes(at path: String) async throws -> FileItem {
        if let operationError { throw operationError }
        guard let match = directoryListing.first(where: { $0.path == path }) else {
            throw POSIXError(.ENOENT)
        }
        return match
    }

    func createDirectory(at path: String) async throws {
        createdDirectories.append(path)
        if let operationError { throw operationError }
    }

    func removeFile(at path: String) async throws {
        removedFiles.append(path)
        if let operationError { throw operationError }
    }

    func removeDirectory(at path: String, recursive: Bool) async throws {
        removedDirectories.append((path, recursive))
        if let operationError { throw operationError }
    }

    func move(from source: String, to destination: String) async throws {
        moves.append((source, destination))
        if let operationError { throw operationError }
    }

    func copy(from source: String, to destination: String, recursive: Bool, progress: TransferProgress?) async throws {
        copies.append((source, destination))
        if let operationError { throw operationError }
        reportProgress(progress)
    }

    func upload(from localURL: URL, to path: String, progress: TransferProgress?) async throws {
        uploads.append((localURL, path))
        if let operationError { throw operationError }
        reportProgress(progress)
    }

    func download(from path: String, to localURL: URL, progress: TransferProgress?) async throws {
        downloads.append((path, localURL))
        if let operationError { throw operationError }
        reportProgress(progress)
        // Produce a real file so callers that read it back behave normally.
        FileManager.default.createFile(
            atPath: localURL.path,
            contents: streamChunks.reduce(into: Data()) { $0.append($1) }
        )
    }

    func readStream(at path: String) -> AsyncThrowingStream<Data, any Error> {
        let chunks = streamChunks
        let error = operationError
        return AsyncThrowingStream { continuation in
            if let error {
                continuation.finish(throwing: error)
                return
            }
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }

    private func reportProgress(_ progress: TransferProgress?) {
        guard let progress else { return }
        for step in progressSteps {
            if !progress(step.transferred, step.total) {
                wasCancelled = true
                return
            }
        }
    }
}

/// Hands out a preconfigured `MockSMBClient`.
struct MockSMBClientFactory: SMBClientFactory {
    let client: MockSMBClient
    /// Thrown instead of returning a client — models a URL that AMSMB2's
    /// failable initialiser rejects.
    let makeError: (any Error)?
    /// Records the timeout the service asked for.
    final class Record: @unchecked Sendable {
        var requestedTimeout: TimeInterval?
    }
    let record = Record()

    init(client: MockSMBClient, makeError: (any Error)? = nil) {
        self.client = client
        self.makeError = makeError
    }

    func makeClient(for profile: ServerProfile, password: String?, timeout: TimeInterval) throws -> any SMBClient {
        record.requestedTimeout = timeout
        if let makeError { throw makeError }
        return client
    }
}

// MARK: - Fixtures

extension ServerProfile {
    static func fixture(
        name: String = "Test NAS",
        host: String = "192.168.1.50",
        port: Int = 445,
        share: String = "Media",
        username: String = "tester",
        saveCredentials: Bool = true
    ) -> ServerProfile {
        ServerProfile(
            name: name, host: host, port: port, shareName: share,
            username: username, saveCredentials: saveCredentials
        )
    }
}

extension FileItem {
    static func fixture(
        path: String,
        name: String? = nil,
        isDirectory: Bool = false,
        size: Int64 = 1024,
        modified: Date? = nil
    ) -> FileItem {
        FileItem(
            path: path,
            name: name ?? (path as NSString).lastPathComponent,
            isDirectory: isDirectory,
            size: isDirectory ? 0 : size,
            modifiedDate: modified
        )
    }
}
