import SwiftUI

/// Full-screen failure modal shown when a server can't be reached or browsed.
///
/// Button order follows what is most likely to fix the specific failure:
/// `BrowseFailure` reports whether editing the connection or launching a
/// VPN/tunnel app is the plausible remedy, and the prominent action changes
/// accordingly — a rejected password leads with Edit Connection, a timeout
/// leads with the recovery app.
struct ConnectionFailureView: View {
    @Bindable var model: AppModel
    let failure: BrowseFailure
    let serverID: UUID?

    @Environment(\.dismiss) private var dismiss
    @State private var isRetrying = false
    @State private var recoveryLaunchFailed = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 24)

                Image(systemName: failure.symbolName)
                    .font(.system(size: 56))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)

                VStack(spacing: 10) {
                    Text(failure.title)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text(failure.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 8)

                if let detail = failure.underlyingDescription, !detail.isEmpty {
                    DisclosureGroup("Technical details") {
                        Text(detail)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .font(.footnote)
                    .padding(14)
                    .glassPanel(cornerRadius: 14)
                }

                actions

                if recoveryLaunchFailed {
                    Text("Couldn't open that app. Check the URL scheme in Settings.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }

                Spacer(minLength: 24)
            }
            .frame(maxWidth: 460)
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .accessibilityIdentifier("failureModal")
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 12) {
            if failure.suggestsRecoveryApp, let app = model.recoveryApp {
                actionButton(
                    "Open \(app.name)",
                    systemImage: "arrow.up.forward.app",
                    prominent: true
                ) {
                    let launched = await model.launchRecoveryApp()
                    recoveryLaunchFailed = !launched
                }
                .accessibilityIdentifier("failureModal.recoveryApp")
            }

            if serverID != nil, failure.suggestsEditingConnection {
                actionButton("Edit Connection", systemImage: "pencil", prominent: true) {
                    editConnection()
                }
                .accessibilityIdentifier("failureModal.editConnection")
            }

            actionButton("Retry", systemImage: "arrow.clockwise", prominent: !hasProminentAction) {
                isRetrying = true
                await model.retryConnection(for: serverID)
                isRetrying = false
                dismiss()
            }
            .disabled(isRetrying)
            .accessibilityIdentifier("failureModal.retry")

            if serverID != nil, !failure.suggestsEditingConnection {
                actionButton("Edit Connection", systemImage: "pencil", prominent: false) {
                    editConnection()
                }
                .accessibilityIdentifier("failureModal.editConnection")
            }

            if !failure.suggestsRecoveryApp, let app = model.recoveryApp {
                actionButton("Open \(app.name)", systemImage: "arrow.up.forward.app", prominent: false) {
                    let launched = await model.launchRecoveryApp()
                    recoveryLaunchFailed = !launched
                }
                .accessibilityIdentifier("failureModal.recoveryApp")
            }

            actionButton("Open Settings", systemImage: "gearshape", prominent: false) {
                model.presentedFailure = nil
                model.isShowingSettings = true
            }
            .accessibilityIdentifier("failureModal.openSettings")

            Button("Dismiss") {
                model.presentedFailure = nil
                dismiss()
            }
            .font(.footnote)
            .padding(.top, 4)
            .accessibilityIdentifier("failureModal.dismiss")
        }
    }

    /// True when a more specific action already claimed the prominent slot, so
    /// Retry doesn't compete with it.
    private var hasProminentAction: Bool {
        (failure.suggestsRecoveryApp && model.recoveryApp != nil)
            || (serverID != nil && failure.suggestsEditingConnection)
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        prominent: Bool,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .tint(prominent ? .accentColor : .gray.opacity(0.25))
        .foregroundStyle(prominent ? .white : Color.primary)
        .controlSize(.large)
    }

    private func editConnection() {
        guard let serverID, let profile = model.servers.profile(id: serverID) else { return }
        model.presentedFailure = nil
        dismiss()
        model.editingServer = profile
    }
}
