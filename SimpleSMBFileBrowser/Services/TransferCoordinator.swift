import Foundation

/// Runs copy/move operations, including between two different providers.
///
/// A same-provider copy is handed to the provider directly (SMB can do a
/// server-side copy). A cross-provider copy has to round-trip through a local
/// temporary file, because there is no path that lets a share write straight
/// into iCloud. Directories recurse.
@MainActor
final class TransferCoordinator {
    enum Mode {
        case copy
        case move

        var direction: TransferDirection { self == .copy ? .copy : .move }
    }

    private let center: TransferCenter

    init(center: TransferCenter) {
        self.center = center
    }

    /// Transfers `items` into `destinationDirectory` of `destination`.
    /// Returns the failures encountered; an empty array means everything
    /// succeeded. One bad item does not abort the rest.
    @discardableResult
    func transfer(
        _ items: [FileItem],
        from source: any FileProviding,
        to destination: any FileProviding,
        destinationDirectory: String,
        mode: Mode
    ) async -> [BrowseFailure] {
        var failures: [BrowseFailure] = []
        // Read the destination listing once per batch so a batch of ten files
        // does not re-list ten times, and so names stay unique within the batch.
        var taken = await destination.existingNames(at: destinationDirectory)

        for item in items {
            let name = BrowsePath.uniqueName(for: item.name, avoiding: taken)
            taken.insert(name)
            do {
                try await transferOne(
                    item, named: name, from: source, to: destination,
                    destinationDirectory: destinationDirectory, mode: mode
                )
            } catch is CancellationError {
                failures.append(BrowseFailure(kind: .cancelled, target: source.label))
            } catch {
                failures.append(BrowseFailure(error: error, target: source.label))
            }
        }
        return failures
    }

    private func transferOne(
        _ item: FileItem,
        named name: String,
        from source: any FileProviding,
        to destination: any FileProviding,
        destinationDirectory: String,
        mode: Mode
    ) async throws {
        let destinationPath = destination.joining(name, to: destinationDirectory)

        if item.isDirectory {
            try await transferDirectory(
                item, to: destinationPath, from: source, destination: destination, mode: mode
            )
            return
        }

        let transferID = center.begin(
            fileName: item.name,
            direction: mode.direction,
            destinationLabel: destination.label,
            totalBytes: item.size
        )
        let progress = center.progressHandler(for: transferID)

        do {
            if source.providerID == destination.providerID {
                switch mode {
                case .copy:
                    try await source.copy(from: item.path, to: destinationPath, progress: progress)
                case .move:
                    // A same-provider move is a rename, not a copy-then-delete.
                    try await source.move(from: item.path, to: destinationPath)
                }
            } else {
                try await transferAcrossProviders(
                    item, to: destinationPath, from: source, destination: destination, progress: progress
                )
                if mode == .move {
                    try await source.delete(item)
                }
            }
        } catch {
            let failure = BrowseFailure(error: error, target: destination.label)
            // A user cancel already set the row to .cancelled; don't overwrite
            // it with the EINTR-ish error the abort produced.
            if center.cancellation.isCancelled(transferID) {
                center.finish(transferID, state: .cancelled)
            } else {
                center.finish(transferID, state: .failed(failure))
            }
            throw failure
        }

        center.finish(transferID, state: .completed)
    }

    /// Staging through a temporary file: the only way to get bytes from one
    /// provider to another.
    private func transferAcrossProviders(
        _ item: FileItem,
        to destinationPath: String,
        from source: any FileProviding,
        destination: any FileProviding,
        progress: TransferProgress?
    ) async throws {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let stagedFile = staging.appendingPathComponent(item.name)
        defer { try? FileManager.default.removeItem(at: staging) }

        // Split the reported progress: the read is the first half, the write the
        // second, so the bar doesn't jump to 100% then sit there during upload.
        try await source.export(from: item.path, to: stagedFile, progress: progress.map { report in
            { @Sendable transferred, total in report(transferred / 2, max(total, 1)) }
        })
        try await destination.importItem(from: stagedFile, to: destinationPath, progress: progress.map { report in
            { @Sendable transferred, total in
                let half = max(total, 1) / 2
                return report(half + transferred / 2, max(total, 1))
            }
        })
    }

    private func transferDirectory(
        _ item: FileItem,
        to destinationPath: String,
        from source: any FileProviding,
        destination: any FileProviding,
        mode: Mode
    ) async throws {
        // Same-provider directory moves are a single rename; no need to walk.
        if source.providerID == destination.providerID, mode == .move {
            try await source.move(from: item.path, to: destinationPath)
            return
        }

        try await destination.createDirectory(at: destinationPath)
        let children = try await source.list(at: item.path)
        var failures: [BrowseFailure] = []
        var taken: Set<String> = []

        for child in children {
            let name = BrowsePath.uniqueName(for: child.name, avoiding: taken)
            taken.insert(name)
            do {
                try await transferOne(
                    child, named: name, from: source, to: destination,
                    destinationDirectory: destinationPath, mode: mode
                )
            } catch {
                failures.append(BrowseFailure(error: error, target: source.label))
            }
        }

        // Only remove the source directory if everything inside it made it.
        if mode == .move, failures.isEmpty {
            try await source.delete(item)
        }
        if let first = failures.first { throw first }
    }
}
