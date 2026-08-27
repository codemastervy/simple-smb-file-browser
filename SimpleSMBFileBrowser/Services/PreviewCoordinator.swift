import Foundation
import Observation

/// Prepares a file for QuickLook.
///
/// QuickLook needs a file URL, so a remote file has to land on disk before it
/// can be shown. What this avoids is buffering the whole file in memory: it
/// consumes `FileProviding.readStream` and appends each chunk to a temporary
/// file, so previewing a 4 GB video costs one chunk of RAM, and the transfer is
/// cancellable and reports progress like any other.
///
/// It is not partial-file preview — QuickLook cannot render an incomplete file.
/// See README "Known limitations".
@MainActor
@Observable
final class PreviewCoordinator {
    struct Request: Identifiable {
        let id = UUID()
        let item: FileItem
        let url: URL
    }

    private(set) var request: Request?
    private(set) var isPreparing = false
    private(set) var failure: BrowseFailure?
    private(set) var preparingItemName: String?

    private let center: TransferCenter
    private var task: Task<Void, Never>?
    /// Temporary files to remove when the preview closes.
    private var scratchDirectories: [URL] = []

    init(center: TransferCenter) {
        self.center = center
    }

    /// Chunk size for streamed reads. 256 KB keeps syscall overhead low without
    /// holding much memory.
    private static let chunkSize = 1 << 18

    func preview(_ item: FileItem, using provider: any FileProviding) {
        cancel()
        guard !item.isDirectory else { return }

        // Local files are already on disk — no copy needed.
        if !provider.isRemote {
            request = Request(item: item, url: URL(fileURLWithPath: item.path))
            return
        }

        isPreparing = true
        preparingItemName = item.name
        failure = nil

        let transferID = center.begin(
            fileName: item.name,
            direction: .download,
            destinationLabel: "Preview",
            totalBytes: item.size
        )

        task = Task { @MainActor in
            defer {
                isPreparing = false
                preparingItemName = nil
            }
            do {
                let url = try await stage(item, using: provider, transferID: transferID)
                guard !Task.isCancelled else {
                    center.finish(transferID, state: .cancelled)
                    return
                }
                center.finish(transferID, state: .completed)
                request = Request(item: item, url: url)
            } catch is CancellationError {
                center.finish(transferID, state: .cancelled)
            } catch {
                let browseFailure = BrowseFailure(error: error, target: provider.label)
                center.finish(transferID, state: .failed(browseFailure))
                failure = browseFailure
            }
        }
    }

    private func stage(
        _ item: FileItem,
        using provider: any FileProviding,
        transferID: UUID
    ) async throws -> URL {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        scratchDirectories.append(scratch)

        let destination = scratch.appendingPathComponent(item.name)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var written: Int64 = 0
        let stream = try await provider.readStream(at: item.path)
        for try await chunk in stream {
            if Task.isCancelled || center.cancellation.isCancelled(transferID) {
                throw CancellationError()
            }
            try handle.write(contentsOf: chunk)
            written += Int64(chunk.count)
            center.update(transferID, transferred: written, total: item.size)
        }
        return destination
    }

    func cancel() {
        task?.cancel()
        task = nil
        isPreparing = false
        preparingItemName = nil
    }

    /// Called when the preview sheet closes.
    func dismiss() {
        cancel()
        request = nil
        for directory in scratchDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        scratchDirectories.removeAll()
    }

    func clearFailure() {
        failure = nil
    }
}
