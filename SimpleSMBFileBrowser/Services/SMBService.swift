import Foundation

/// One live connection to one SMB share.
///
/// Every method translates thrown errors into `BrowseFailure`, so callers never
/// see a raw `POSIXError` and the UI always has a sentence to show. The client
/// is created through an injected factory, which is what makes the failure
/// paths (auth rejected, host unreachable, timeout) testable without a server.
actor SMBService {
    /// Default per-operation timeout. AMSMB2's own default is considerably
    /// longer, which makes an unreachable host feel like a hang.
    static let defaultTimeout: TimeInterval = 15

    let profile: ServerProfile

    private let factory: any SMBClientFactory
    private let timeout: TimeInterval
    private var password: String?
    private var client: (any SMBClient)?

    init(
        profile: ServerProfile,
        password: String?,
        factory: any SMBClientFactory = AMSMB2ClientFactory(),
        timeout: TimeInterval = SMBService.defaultTimeout
    ) {
        self.profile = profile
        self.password = password
        self.factory = factory
        self.timeout = timeout
    }

    var isConnected: Bool { client != nil }

    /// Replaces the password used for subsequent connections, e.g. after the
    /// user corrects it in the failure modal.
    func updatePassword(_ newPassword: String?) {
        password = newPassword
    }

    // MARK: - Connection lifecycle

    func connect() async throws {
        if client != nil { return }
        if let error = profile.validationError {
            throw BrowseFailure(
                kind: .invalidConfiguration, target: profile.host, underlyingDescription: error
            )
        }
        let newClient = try await mapped {
            try self.factory.makeClient(for: self.profile, password: self.password, timeout: self.timeout)
        }
        try await mapped { try await newClient.connect() }
        client = newClient
    }

    func disconnect() async {
        guard let client else { return }
        self.client = nil
        await client.disconnect()
    }

    /// Drops the connection and establishes a fresh one.
    func reconnect() async throws {
        await disconnect()
        try await connect()
    }

    // MARK: - Browsing

    func listShares() async throws -> [String] {
        try await withClient { try await $0.listShares() }
    }

    func listDirectory(at path: String, recursive: Bool = false) async throws -> [FileItem] {
        try await withClient { try await $0.listDirectory(at: path, recursive: recursive) }
    }

    func attributes(at path: String) async throws -> FileItem {
        try await withClient { try await $0.attributes(at: path) }
    }

    // MARK: - Mutations

    func createDirectory(at path: String) async throws {
        try await withClient { try await $0.createDirectory(at: path) }
    }

    /// Deletes a file or directory, choosing the right call for the item type.
    func delete(_ item: FileItem) async throws {
        try await withClient {
            if item.isDirectory {
                try await $0.removeDirectory(at: item.path, recursive: true)
            } else {
                try await $0.removeFile(at: item.path)
            }
        }
    }

    /// Renames within the same directory. SMB has no distinct rename call —
    /// it is a move to a sibling path.
    func rename(_ item: FileItem, to newName: String) async throws {
        let parent = BrowsePath.parent(of: item.path) ?? BrowsePath.smbRoot
        let destination = BrowsePath.appending(newName, to: parent)
        try await move(from: item.path, to: destination)
    }

    func move(from source: String, to destination: String) async throws {
        try await withClient { try await $0.move(from: source, to: destination) }
    }

    func copy(
        from source: String,
        to destination: String,
        recursive: Bool = true,
        progress: TransferProgress? = nil
    ) async throws {
        try await withClient {
            try await $0.copy(from: source, to: destination, recursive: recursive, progress: progress)
        }
    }

    // MARK: - Transfers

    func upload(from localURL: URL, to path: String, progress: TransferProgress? = nil) async throws {
        try await withClient { try await $0.upload(from: localURL, to: path, progress: progress) }
    }

    func download(from path: String, to localURL: URL, progress: TransferProgress? = nil) async throws {
        try await withClient { try await $0.download(from: path, to: localURL, progress: progress) }
    }

    /// Streaming read for previews. Connects first if needed; the stream itself
    /// surfaces raw errors, since a partially consumed stream has no single
    /// failure point to translate.
    func readStream(at path: String) async throws -> AsyncThrowingStream<Data, any Error> {
        try await connect()
        guard let client else {
            throw BrowseFailure(kind: .other, target: profile.host)
        }
        return client.readStream(at: path)
    }

    // MARK: - Plumbing

    /// Runs `body` against a connected client, connecting on demand.
    private func withClient<T>(_ body: (any SMBClient) async throws -> T) async throws -> T {
        try await connect()
        guard let client else {
            throw BrowseFailure(kind: .other, target: profile.host)
        }
        return try await mapped { try await body(client) }
    }

    /// Translates anything thrown into an `BrowseFailure` carrying this profile's
    /// host, so messages can name the machine that failed.
    private func mapped<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw BrowseFailure(error: error, target: profile.host)
        }
    }
}
