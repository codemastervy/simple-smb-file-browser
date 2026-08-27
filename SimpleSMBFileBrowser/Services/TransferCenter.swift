import Foundation
import Observation

/// Thread-safe set of cancelled transfer ids.
///
/// Separate from `TransferCenter` because progress callbacks run on AMSMB2's own
/// queue, off the main actor, and must be able to check for cancellation
/// synchronously — the callback's Bool return value *is* the cancel signal.
final class TransferCancellationRegistry: @unchecked Sendable {
    private var cancelled: Set<UUID> = []
    private let lock = NSLock()

    func cancel(_ id: UUID) {
        lock.withLock { _ = cancelled.insert(id) }
    }

    func isCancelled(_ id: UUID) -> Bool {
        lock.withLock { cancelled.contains(id) }
    }

    func forget(_ id: UUID) {
        lock.withLock { _ = cancelled.remove(id) }
    }
}

/// Tracks active and recent transfers for the Transfers panel.
@MainActor
@Observable
final class TransferCenter {
    private(set) var transfers: [Transfer] = []

    /// Shared with progress callbacks so cancellation is visible off-main.
    let cancellation = TransferCancellationRegistry()

    /// How many finished transfers are kept for the history list.
    var historyLimit: Int = 50

    var active: [Transfer] { transfers.filter { !$0.state.isFinished } }
    var recent: [Transfer] { transfers.filter(\.state.isFinished) }
    var hasActivity: Bool { !transfers.isEmpty }

    /// Combined progress across active transfers, for the toolbar indicator.
    var overallFraction: Double? {
        let running = active
        guard !running.isEmpty else { return nil }
        let known = running.compactMap(\.fractionCompleted)
        guard !known.isEmpty else { return nil }
        return known.reduce(0, +) / Double(known.count)
    }

    // MARK: - Lifecycle of one transfer

    func begin(
        fileName: String,
        direction: TransferDirection,
        destinationLabel: String,
        totalBytes: Int64 = 0
    ) -> UUID {
        let transfer = Transfer(
            fileName: fileName,
            direction: direction,
            destinationLabel: destinationLabel,
            totalBytes: totalBytes,
            state: .active
        )
        transfers.insert(transfer, at: 0)
        return transfer.id
    }

    func update(_ id: UUID, transferred: Int64, total: Int64) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].transferredBytes = transferred
        if total > 0 { transfers[index].totalBytes = total }
    }

    func finish(_ id: UUID, state: TransferState) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].state = state
        transfers[index].finishedAt = Date()
        if state == .completed, transfers[index].totalBytes > 0 {
            // Snap to 100% so a completed row never reads 99%.
            transfers[index].transferredBytes = transfers[index].totalBytes
        }
        cancellation.forget(id)
        trimHistory()
    }

    /// Marks a transfer cancelled. The running operation notices on its next
    /// progress callback and unwinds; `finish` is then called by the caller.
    func requestCancel(_ id: UUID) {
        cancellation.cancel(id)
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        if !transfers[index].state.isFinished {
            transfers[index].state = .cancelled
            transfers[index].finishedAt = Date()
        }
        trimHistory()
    }

    func cancelAll() {
        for transfer in active { requestCancel(transfer.id) }
    }

    func clearHistory() {
        transfers.removeAll { $0.state.isFinished }
    }

    private func trimHistory() {
        let finished = transfers.filter(\.state.isFinished)
        guard finished.count > historyLimit else { return }
        let doomed = Set(finished.dropFirst(historyLimit).map(\.id))
        transfers.removeAll { doomed.contains($0.id) }
    }

    /// Builds a progress callback for `SMBService`/`DeviceFileService`.
    ///
    /// Returning `false` is what actually aborts the transfer inside AMSMB2, so
    /// the cancelled check happens here rather than in the caller.
    func progressHandler(for id: UUID) -> TransferProgress {
        let registry = cancellation
        return { [weak self] transferred, total in
            if registry.isCancelled(id) { return false }
            Task { @MainActor [weak self] in
                self?.update(id, transferred: transferred, total: total)
            }
            return true
        }
    }
}
