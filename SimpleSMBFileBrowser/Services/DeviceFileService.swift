import Foundation

/// Filesystem access for the two Device Files locations.
///
/// Deliberately mirrors `SMBService`'s shape — same operations, same
/// `BrowseFailure` errors, `FileItem` results — so the browser UI is written
/// once and works against a share or the device without branching.
///
/// Scope is limited by the sandbox, and that limit is real rather than worked
/// around. See README "Known limitations": on iOS/iPadOS there is no API for
/// browsing the whole device, so `onMyDevice` starts at the app's own Documents
/// directory (surfaced in the Files app via `UIFileSharingEnabled`), and
/// anything outside it is reached only through a user-granted URL from the
/// document picker.
actor DeviceFileService {
    private let fileManager: FileManager
    /// Overridable roots — used by tests to point both locations at a temporary
    /// directory instead of the real container.
    private let onMyDeviceOverride: URL?
    private let iCloudOverride: URL?

    init(
        fileManager: FileManager = .default,
        onMyDeviceRoot: URL? = nil,
        iCloudRoot: URL? = nil
    ) {
        self.fileManager = fileManager
        self.onMyDeviceOverride = onMyDeviceRoot
        self.iCloudOverride = iCloudRoot
    }

    // MARK: - Roots

    /// The app's Documents directory: the largest area of the local filesystem
    /// a sandboxed app can enumerate without the user picking a folder.
    var onMyDeviceRoot: URL {
        if let onMyDeviceOverride { return onMyDeviceOverride }
        return fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
    }

    /// The iCloud Drive Documents directory, when the app has an iCloud
    /// container. Nil without one — which is the default here, because the
    /// ubiquity-container entitlement requires a provisioned Apple Developer
    /// team. Callers fall back to the document picker.
    var iCloudDriveRoot: URL? {
        if let iCloudOverride { return iCloudOverride }
        guard let container = fileManager.url(forUbiquityContainerIdentifier: nil) else {
            return nil
        }
        return container.appendingPathComponent("Documents", isDirectory: true)
    }

    var isICloudAvailable: Bool { iCloudDriveRoot != nil }

    func root(for location: DeviceLocation) throws -> URL {
        switch location {
        case .onMyDevice:
            return onMyDeviceRoot
        case .iCloudDrive:
            guard let iCloudDriveRoot else {
                throw BrowseFailure(
                    kind: .permissionDenied,
                    target: location.title,
                    underlyingDescription: "iCloud Drive isn't available. Sign in to iCloud, or open a folder with the document picker."
                )
            }
            // The container's Documents directory does not exist until first use.
            try ensureDirectoryExists(iCloudDriveRoot, target: location.title)
            return iCloudDriveRoot
        }
    }

    // MARK: - Browsing

    func listDirectory(atPath path: String, recursive: Bool = false) throws -> [FileItem] {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let keys: [URLResourceKey] = [
            .nameKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
            .contentModificationDateKey, .creationDateKey,
        ]

        do {
            if recursive {
                guard let enumerator = fileManager.enumerator(
                    at: directory, includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { return [] }
                return enumerator.compactMap { ($0 as? URL).flatMap(FileItem.init(localURL:)) }
            }
            let contents = try fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
            return contents.compactMap(FileItem.init(localURL:))
        } catch {
            throw BrowseFailure(localError: error, target: directory.lastPathComponent)
        }
    }

    func attributes(atPath path: String) throws -> FileItem {
        let url = URL(fileURLWithPath: path)
        guard let item = FileItem(localURL: url) else {
            throw BrowseFailure(kind: .notFound, target: url.lastPathComponent)
        }
        return item
    }

    // MARK: - Mutations

    func createDirectory(atPath path: String) throws {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard !fileManager.fileExists(atPath: url.path) else {
            throw BrowseFailure(kind: .alreadyExists, target: url.lastPathComponent)
        }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            throw BrowseFailure(localError: error, target: url.lastPathComponent)
        }
    }

    func delete(_ item: FileItem) throws {
        do {
            try fileManager.removeItem(at: URL(fileURLWithPath: item.path))
        } catch {
            throw BrowseFailure(localError: error, target: item.name)
        }
    }

    func rename(_ item: FileItem, to newName: String) throws {
        let parent = (item.path as NSString).deletingLastPathComponent
        let destination = (parent as NSString).appendingPathComponent(newName)
        try move(fromPath: item.path, toPath: destination)
    }

    func move(fromPath source: String, toPath destination: String) throws {
        let sourceURL = URL(fileURLWithPath: source)
        let destinationURL = URL(fileURLWithPath: destination)
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw BrowseFailure(kind: .alreadyExists, target: destinationURL.lastPathComponent)
        }
        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            throw BrowseFailure(localError: error, target: sourceURL.lastPathComponent)
        }
    }

    func copy(fromPath source: String, toPath destination: String) throws {
        let sourceURL = URL(fileURLWithPath: source)
        let destinationURL = URL(fileURLWithPath: destination)
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw BrowseFailure(kind: .alreadyExists, target: destinationURL.lastPathComponent)
        }
        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            throw BrowseFailure(localError: error, target: sourceURL.lastPathComponent)
        }
    }

    /// Names already taken in `directory`, used to de-duplicate a transfer
    /// destination rather than failing on collision.
    func existingNames(inDirectory directory: String) -> Set<String> {
        let contents = (try? fileManager.contentsOfDirectory(atPath: directory)) ?? []
        return Set(contents)
    }

    private func ensureDirectoryExists(_ url: URL, target: String) throws {
        guard !fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw BrowseFailure(localError: error, target: target)
        }
    }
}

// MARK: - Mapping local URLs to FileItem

extension FileItem {
    init?(localURL url: URL) {
        let values = try? url.resourceValues(forKeys: [
            .nameKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
            .contentModificationDateKey, .creationDateKey,
        ])
        let isDirectory = values?.isDirectory ?? false
        self.init(
            path: url.path,
            name: values?.name ?? url.lastPathComponent,
            isDirectory: isDirectory,
            isSymbolicLink: values?.isSymbolicLink ?? false,
            size: isDirectory ? 0 : Int64(values?.fileSize ?? 0),
            modifiedDate: values?.contentModificationDate,
            creationDate: values?.creationDate
        )
    }
}
