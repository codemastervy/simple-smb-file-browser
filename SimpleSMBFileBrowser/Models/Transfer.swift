import Foundation

enum TransferDirection: String, Codable, Sendable {
    case upload, download, copy, move

    var title: String {
        switch self {
        case .upload: return "Uploading"
        case .download: return "Downloading"
        case .copy: return "Copying"
        case .move: return "Moving"
        }
    }

    var symbolName: String {
        switch self {
        case .upload: return "arrow.up.circle"
        case .download: return "arrow.down.circle"
        case .copy: return "doc.on.doc"
        case .move: return "arrow.right.doc.on.clipboard"
        }
    }
}

enum TransferState: Equatable, Sendable {
    case waiting
    case active
    case completed
    case cancelled
    case failed(BrowseFailure)

    var isFinished: Bool {
        switch self {
        case .waiting, .active: return false
        case .completed, .cancelled, .failed: return true
        }
    }

    var title: String {
        switch self {
        case .waiting: return "Waiting"
        case .active: return "In progress"
        case .completed: return "Completed"
        case .cancelled: return "Cancelled"
        case .failed: return "Failed"
        }
    }
}

/// One file transfer, shown as a row in the Transfers panel.
struct Transfer: Identifiable, Equatable, Sendable {
    let id: UUID
    let fileName: String
    let direction: TransferDirection
    /// Where the transfer is going, e.g. a server name or "On My iPhone".
    let destinationLabel: String
    var transferredBytes: Int64
    var totalBytes: Int64
    var state: TransferState
    let startedAt: Date
    var finishedAt: Date?

    init(
        id: UUID = UUID(),
        fileName: String,
        direction: TransferDirection,
        destinationLabel: String,
        transferredBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        state: TransferState = .waiting,
        startedAt: Date = Date(),
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.direction = direction
        self.destinationLabel = destinationLabel
        self.transferredBytes = transferredBytes
        self.totalBytes = totalBytes
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    /// Nil when the total isn't known yet, so the UI can show an
    /// indeterminate bar rather than a misleading 0%.
    var fractionCompleted: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, Double(transferredBytes) / Double(totalBytes))
    }

    var progressDescription: String {
        let done = ByteCountFormatter.string(fromByteCount: transferredBytes, countStyle: .file)
        guard totalBytes > 0 else { return done }
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(done) of \(total)"
    }
}
