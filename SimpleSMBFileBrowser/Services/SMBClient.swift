import Foundation
import AMSMB2

/// Progress callback for a transfer. Return `false` to cancel.
///
/// The Bool return is AMSMB2's own cancellation mechanism (see
/// `ReadProgressHandler`/`WriteProgressHandler` in the package), surfaced here
/// unchanged rather than wrapped in something that would need bridging back.
typealias TransferProgress = @Sendable (_ transferred: Int64, _ total: Int64) -> Bool

/// The SMB operations the app needs, expressed without reference to AMSMB2.
///
/// This seam exists for testability: `SMBService`'s unit tests cover auth
/// failure, unreachable hosts and timeouts, none of which can be provoked
/// reliably against a real server in CI.
protocol SMBClient: Sendable {
    func connect() async throws
    func disconnect() async
    func listShares() async throws -> [String]
    func listDirectory(at path: String, recursive: Bool) async throws -> [FileItem]
    func attributes(at path: String) async throws -> FileItem
    func createDirectory(at path: String) async throws
    func removeFile(at path: String) async throws
    func removeDirectory(at path: String, recursive: Bool) async throws
    func move(from source: String, to destination: String) async throws
    func copy(from source: String, to destination: String, recursive: Bool, progress: TransferProgress?) async throws
    func upload(from localURL: URL, to path: String, progress: TransferProgress?) async throws
    func download(from path: String, to localURL: URL, progress: TransferProgress?) async throws
    /// Streaming read, used to feed QuickLook without downloading whole files.
    func readStream(at path: String) -> AsyncThrowingStream<Data, any Error>
}

/// Creates clients. Injectable so `SMBService` can be tested against doubles.
protocol SMBClientFactory: Sendable {
    func makeClient(for profile: ServerProfile, password: String?, timeout: TimeInterval) throws -> any SMBClient
}

// MARK: - AMSMB2-backed implementation

struct AMSMB2ClientFactory: SMBClientFactory {
    func makeClient(for profile: ServerProfile, password: String?, timeout: TimeInterval) throws -> any SMBClient {
        guard let url = profile.smbURL else {
            throw BrowseFailure(kind: .invalidConfiguration, target: profile.host)
        }
        let credential = URLCredential(
            user: profile.username,
            password: password ?? "",
            persistence: .forSession
        )
        guard let manager = SMB2Manager(url: url, domain: profile.domain, credential: credential) else {
            throw BrowseFailure(kind: .invalidConfiguration, target: profile.host)
        }
        manager.timeout = timeout
        return AMSMB2Client(manager: manager, shareName: profile.shareName)
    }
}

/// Thin adapter over `SMB2Manager`.
///
/// An actor because `SMB2Manager` is `@unchecked Sendable` with an internal
/// concurrent queue; serialising our calls keeps connect/disconnect ordering
/// predictable per connection.
actor AMSMB2Client: SMBClient {
    private let manager: SMB2Manager
    private let shareName: String
    private var isConnected = false

    init(manager: SMB2Manager, shareName: String) {
        self.manager = manager
        self.shareName = shareName
    }

    func connect() async throws {
        guard !isConnected else { return }
        try await manager.connectShare(name: shareName)
        isConnected = true
    }

    func disconnect() async {
        guard isConnected else { return }
        isConnected = false
        // A failure while tearing down is not actionable for the user.
        try? await manager.disconnectShare(gracefully: true)
    }

    func listShares() async throws -> [String] {
        try await manager.listShares().map(\.name)
    }

    func listDirectory(at path: String, recursive: Bool) async throws -> [FileItem] {
        let entries = try await manager.contentsOfDirectory(atPath: path, recursive: recursive)
        return entries.compactMap { FileItem(smbAttributes: $0) }
    }

    func attributes(at path: String) async throws -> FileItem {
        let attributes = try await manager.attributesOfItem(atPath: path)
        guard let item = FileItem(smbAttributes: attributes, fallbackPath: path) else {
            throw BrowseFailure(kind: .notFound, target: "")
        }
        return item
    }

    func createDirectory(at path: String) async throws {
        try await manager.createDirectory(atPath: path)
    }

    func removeFile(at path: String) async throws {
        try await manager.removeFile(atPath: path)
    }

    func removeDirectory(at path: String, recursive: Bool) async throws {
        try await manager.removeDirectory(atPath: path, recursive: recursive)
    }

    func move(from source: String, to destination: String) async throws {
        try await manager.moveItem(atPath: source, toPath: destination)
    }

    func copy(from source: String, to destination: String, recursive: Bool, progress: TransferProgress?) async throws {
        try await manager.copyItem(
            atPath: source, toPath: destination, recursive: recursive,
            progress: progress.map { report in
                { @Sendable bytes, total in report(bytes, total) }
            }
        )
    }

    func upload(from localURL: URL, to path: String, progress: TransferProgress?) async throws {
        // AMSMB2's write progress reports bytes written but not the total, so
        // the total is taken from the local file and closed over here.
        let total = (try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? 0
        try await manager.uploadItem(
            at: localURL, toPath: path,
            progress: progress.map { report in
                { @Sendable bytes in report(bytes, total) }
            }
        )
    }

    func download(from path: String, to localURL: URL, progress: TransferProgress?) async throws {
        try await manager.downloadItem(
            atPath: path, to: localURL,
            progress: progress.map { report in
                { @Sendable bytes, total in report(bytes, total) }
            }
        )
    }

    // nonisolated: satisfies the synchronous protocol requirement without
    // hopping onto the actor. Safe because it reads only `manager`, an
    // immutable let of a Sendable type.
    nonisolated func readStream(at path: String) -> AsyncThrowingStream<Data, any Error> {
        manager.contents(atPath: path)
    }
}

// MARK: - Mapping SMB attributes to FileItem

extension FileItem {
    /// Builds a `FileItem` from one entry of an AMSMB2 directory listing.
    ///
    /// AMSMB2 populates `.nameKey` and `.pathKey` itself and fills the rest from
    /// the SMB stat struct. Directory paths arrive with a trailing slash, which
    /// is stripped so path joins stay uniform.
    init?(smbAttributes attributes: [URLResourceKey: Any], fallbackPath: String? = nil) {
        let rawPath = (attributes[.pathKey] as? String) ?? fallbackPath
        guard let rawPath else { return nil }

        var path = rawPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }

        let name = (attributes[.nameKey] as? String)
            ?? (path as NSString).lastPathComponent

        let isDirectory = (attributes[.isDirectoryKey] as? NSNumber)?.boolValue
            ?? (attributes[.fileResourceTypeKey] as? URLFileResourceType == .directory)
        let isSymbolicLink = (attributes[.isSymbolicLinkKey] as? NSNumber)?.boolValue ?? false
        let size = (attributes[.fileSizeKey] as? NSNumber)?.int64Value ?? 0

        self.init(
            path: path,
            name: name,
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            size: isDirectory ? 0 : size,
            modifiedDate: Self.meaningfulDate(attributes[.contentModificationDateKey]),
            creationDate: Self.meaningfulDate(attributes[.creationDateKey])
        )
    }

    /// SMB servers that don't track a timestamp report 0, which becomes
    /// 1970-01-01. Treat that as "no date" so the UI shows nothing rather than
    /// a misleading date.
    private static func meaningfulDate(_ value: Any?) -> Date? {
        guard let date = value as? Date else { return nil }
        return date.timeIntervalSince1970 > 1 ? date : nil
    }
}
