import SwiftUI

/// Active and recent transfers.
struct TransfersPanel: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.transfers.transfers.isEmpty {
                    ContentUnavailableView {
                        Label("No Transfers", systemImage: "arrow.up.arrow.down.circle")
                    } description: {
                        Text("Uploads, downloads, copies and moves appear here while they run, and stay in the list afterwards.")
                    }
                } else {
                    List {
                        if !model.transfers.active.isEmpty {
                            Section("Active") {
                                ForEach(model.transfers.active) { transfer in
                                    TransferRow(transfer: transfer) {
                                        model.transfers.requestCancel(transfer.id)
                                    }
                                }
                            }
                        }
                        if !model.transfers.recent.isEmpty {
                            Section("Recent") {
                                ForEach(model.transfers.recent) { transfer in
                                    TransferRow(transfer: transfer, onCancel: nil)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Transfers")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            model.transfers.cancelAll()
                        } label: {
                            Label("Cancel All", systemImage: "xmark.circle")
                        }
                        .disabled(model.transfers.active.isEmpty)

                        Button(role: .destructive) {
                            model.transfers.clearHistory()
                        } label: {
                            Label("Clear History", systemImage: "trash")
                        }
                        .disabled(model.transfers.recent.isEmpty)
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("transfers.menu")
                }
            }
        }
        .frame(minWidth: 420, minHeight: 460)
        .accessibilityIdentifier("transfersPanel")
    }
}

struct TransferRow: View {
    let transfer: Transfer
    let onCancel: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: transfer.direction.symbolName)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(transfer.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if transfer.state == .active {
                    // Indeterminate when the total isn't known yet, rather than
                    // showing a bar stuck at zero.
                    if let fraction = transfer.fractionCompleted {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                }

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            if let onCancel {
                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel transfer")
                .accessibilityIdentifier("transfers.cancel")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        switch transfer.state {
        case .failed(let failure):
            return failure.message
        case .active, .waiting:
            return "\(transfer.direction.title) to \(transfer.destinationLabel) · \(transfer.progressDescription)"
        case .completed, .cancelled:
            return "\(transfer.state.title) · \(transfer.destinationLabel)"
        }
    }

    private var tint: Color {
        switch transfer.state {
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        case .active, .waiting: return .accentColor
        }
    }
}
