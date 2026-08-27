import Foundation

/// The operations the browser UI needs, regardless of what's behind them.
///
/// Both an SMB share and an on-device location conform, which is what lets one
/// `FileBrowserViewModel` drive every pane and lets a file move between a share
/// and iCloud without the views knowing which is which.
protocol FileProviding: Sendable {
    /// Stable identity for this provider. Providers are value types, so the
    /// transfer coordinator compares these to tell an in-place copy from a
    /// cross-provider one (share to iCloud, say).
    var providerID: String { get }
    /// Name shown in breadcrumbs and transfer rows.
    var label: String { get }
    /// Path the browser opens at.
    var rootPath: String { get }
    /// True when this provider reads from a remote host, which gates the
    /// connection-failure modal and the status dot.
    var isRemote: Bool { get }

    func connect() async throws
    func disconnect() async

    func list(at path: String, recursive: Bool) async throws -> [FileItem]
    func createDirectory(at path: String) async throws
    func delete(_ item: FileItem) async throws
    func rename(_ item: FileItem, to newName: String) async throws
    /// Move within this provider.
    func move(from source: String, to destination: String) async throws
    /// Copy within this provider.
    func copy(from source: String, to destination: String, progress: TransferProgress?) async throws

    /// Copies out to a local file — the read half of a cross-provider transfer.
    func export(from path: String, to localURL: URL, progress: TransferProgress?) async throws
    /// Copies in from a local file — the write half of a cross-provider transfer.
    func importItem(from localURL: URL, to path: String, progress: TransferProgress?) async throws

    func readStream(at path: String) async throws -> AsyncThrowingStream<Data, any Error>
    /// Names already present in a directory, used to avoid clobbering on
    /// transfer rather than failing.
    func existingNames(at directory: String) async -> Set<String>

    func joining(_ component: String, to directory: String) -> String
}

extension FileProviding {
    func list(at path: String) async throws -> [FileItem] {
        try await list(at: path, recursive: false)
    }
}

// MARK: - SMB

/// `FileProviding` over one SMB share.
struct SMBFileProvider: FileProviding {
    let service: SMBService
    let label: String

    let profileID: UUID

    var providerID: String { "smb:\(profileID.uuidString)" }
    var rootPath: String { BrowsePath.smbRoot }
    var isRemote: Bool { true }

    init(service: SMBService, label: String, profileID: UUID) {
        self.service = service
        self.label = label
        self.profileID = profileID
    }

    func connect() async throws { try await service.connect() }
    func disconnect() async { await service.disconnect() }

    func list(at path: String, recursive: Bool) async throws -> [FileItem] {
        try await service.listDirectory(at: path, recursive: recursive)
    }

    func createDirectory(at path: String) async throws {
        try await service.createDirectory(at: path)
    }

    func delete(_ item: FileItem) async throws {
        try await service.delete(item)
    }

    func rename(_ item: FileItem, to newName: String) async throws {
        try await service.rename(item, to: newName)
    }

    func move(from source: String, to destination: String) async throws {
        try await service.move(from: source, to: destination)
    }

    func copy(from source: String, to destination: String, progress: TransferProgress?) async throws {
        try await service.copy(from: source, to: destination, progress: progress)
    }

    func export(from path: String, to localURL: URL, progress: TransferProgress?) async throws {
        try await service.download(from: path, to: localURL, progress: progress)
    }

    func importItem(from localURL: URL, to path: String, progress: TransferProgress?) async throws {
        try await service.upload(from: localURL, to: path, progress: progress)
    }

    func readStream(at path: String) async throws -> AsyncThrowingStream<Data, any Error> {
        try await service.readStream(at: path)
    }

    func existingNames(at directory: String) async -> Set<String> {
        let items = try? await service.listDirectory(at: directory)
        return Set((items ?? []).map(\.name))
    }

    func joining(_ component: String, to directory: String) -> String {
        BrowsePath.appending(component, to: directory)
    }
}

// MARK: - Device

/// `FileProviding` over iCloud Drive or the local filesystem.
struct DeviceFileProvider: FileProviding {
    let service: DeviceFileService
    let location: DeviceLocation
    let rootPath: String

    var providerID: String { "device:\(location.rawValue)" }
    var label: String { location.title }
    var isRemote: Bool { false }

    init(service: DeviceFileService, location: DeviceLocation, rootPath: String) {
        self.service = service
        self.location = location
        self.rootPath = rootPath
    }

    /// Nothing to connect to; the root was already resolved at construction.
    func connect() async throws {}
    func disconnect() async {}

    func list(at path: String, recursive: Bool) async throws -> [FileItem] {
        try await service.listDirectory(atPath: path, recursive: recursive)
    }

    func createDirectory(at path: String) async throws {
        try await service.createDirectory(atPath: path)
    }

    func delete(_ item: FileItem) async throws {
        try await service.delete(item)
    }

    func rename(_ item: FileItem, to newName: String) async throws {
        try await service.rename(item, to: newName)
    }

    func move(from source: String, to destination: String) async throws {
        try await service.move(fromPath: source, toPath: destination)
    }

    func copy(from source: String, to destination: String, progress: TransferProgress?) async throws {
        try await service.copy(fromPath: source, toPath: destination)
        // FileManager copies are not incremental, so report a single completed
        // step rather than faking intermediate progress.
        _ = progress?(1, 1)
    }

    func export(from path: String, to localURL: URL, progress: TransferProgress?) async throws {
        try await service.copy(fromPath: path, toPath: localURL.path)
        _ = progress?(1, 1)
    }

    func importItem(from localURL: URL, to path: String, progress: TransferProgress?) async throws {
        try await service.copy(fromPath: localURL.path, toPath: path)
        _ = progress?(1, 1)
    }

    func readStream(at path: String) async throws -> AsyncThrowingStream<Data, any Error> {
        let url = URL(fileURLWithPath: path)
        return AsyncThrowingStream { continuation in
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while let chunk = try handle.read(upToCount: 1 << 18), !chunk.isEmpty {
                    continuation.yield(chunk)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: BrowseFailure(localError: error, target: url.lastPathComponent))
            }
        }
    }

    func existingNames(at directory: String) async -> Set<String> {
        await service.existingNames(inDirectory: directory)
    }

    func joining(_ component: String, to directory: String) -> String {
        (directory as NSString).appendingPathComponent(component)
    }
}
