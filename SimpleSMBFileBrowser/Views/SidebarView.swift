import SwiftUI

/// Persistent sidebar: saved servers, then the collapsible Device Files group.
struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.selectedLocation) {
            serversSection
            deviceFilesSection
        }
        .listStyle(.sidebar)
        .navigationTitle("Simple SMB")
        .toolbar { sidebarToolbar }
    }

    // MARK: - Servers

    private var serversSection: some View {
        Section("Servers") {
            ForEach(model.servers.profiles) { profile in
                serverRow(profile)
            }
            addServerRow
        }
    }

    private func serverRow(_ profile: ServerProfile) -> some View {
        Group {
            HStack(spacing: 10) {
                ConnectionStatusDot(state: model.connectionState(for: profile.id))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(profile.displayName)
                            .lineLimit(1)
                        if model.servers.defaultServerID == profile.id {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.tint)
                                .accessibilityLabel("Default server")
                        }
                    }
                    Text(profile.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel(for: profile))
        }
        .tag(BrowserLocation.server(profile.id))
        .contextMenu { serverMenu(profile) }
        #if !os(macOS)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { await model.removeServer(id: profile.id) }
            } label: {
                Label("Remove", systemImage: "trash")
            }
            Button {
                model.editingServer = profile
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.indigo)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                model.servers.setDefault(profile.id)
            } label: {
                Label("Default", systemImage: "star")
            }
            .tint(.orange)
        }
        #endif
    }

    @ViewBuilder
    private func serverMenu(_ profile: ServerProfile) -> some View {
        Button {
            model.editingServer = profile
        } label: {
            Label("Edit Connection…", systemImage: "pencil")
        }
        Button {
            model.servers.setDefault(profile.id)
        } label: {
            Label("Set as Default", systemImage: "star")
        }
        .disabled(model.servers.defaultServerID == profile.id)

        Divider()

        if model.connectionState(for: profile.id).isConnected {
            Button {
                Task { await model.disconnect(from: profile.id) }
            } label: {
                Label("Disconnect", systemImage: "eject")
            }
        } else {
            Button {
                Task { await model.connect(to: profile.id) }
            } label: {
                Label("Connect", systemImage: "bolt.horizontal")
            }
        }

        if model.isDualPaneSupported {
            Button {
                model.openInSecondPane(.server(profile.id))
            } label: {
                Label("Open in Second Pane", systemImage: "rectangle.split.2x1")
            }
        }

        Divider()

        Button(role: .destructive) {
            Task { await model.removeServer(id: profile.id) }
        } label: {
            Label("Remove Server", systemImage: "trash")
        }
    }

    private var addServerRow: some View {
        Button {
            model.isAddingServer = true
        } label: {
            Label("Add Server", systemImage: "plus.circle.fill")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .accessibilityIdentifier("sidebar.addServer")
    }

    // MARK: - Device Files

    private var deviceFilesSection: some View {
        Section {
            // Collapsed on every launch by design; the binding lives in AppModel
            // and is deliberately not persisted.
            DisclosureGroup(isExpanded: $model.isDeviceFilesExpanded) {
                ForEach(DeviceLocation.allCases) { location in
                    Label(location.title, systemImage: location.symbolName)
                    .tag(BrowserLocation.device(location))
                    .contextMenu {
                        if model.isDualPaneSupported {
                            Button {
                                model.openInSecondPane(.device(location))
                            } label: {
                                Label("Open in Second Pane", systemImage: "rectangle.split.2x1")
                            }
                        }
                    }
                }
            } label: {
                Label("Device Files", systemImage: "internaldrive")
                    .accessibilityIdentifier("sidebar.deviceFiles")
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var sidebarToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.isShowingTransfers = true
            } label: {
                Label("Transfers", systemImage: transfersSymbol)
            }
            .accessibilityIdentifier("sidebar.transfers")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.isShowingSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .accessibilityIdentifier("sidebar.settings")
        }
    }

    private var transfersSymbol: String {
        model.transfers.active.isEmpty ? "arrow.up.arrow.down.circle" : "arrow.up.arrow.down.circle.fill"
    }

    private func accessibilityLabel(for profile: ServerProfile) -> String {
        let status: String
        switch model.connectionState(for: profile.id) {
        case .connected: status = "connected"
        case .connecting: status = "connecting"
        case .failed: status = "connection failed"
        case .disconnected: status = "not connected"
        }
        return "\(profile.displayName), \(profile.subtitle), \(status)"
    }
}

/// Green/red/amber connection indicator.
struct ConnectionStatusDot: View {
    let state: ConnectionState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay {
                if state.isBusy {
                    Circle()
                        .stroke(color.opacity(0.5), lineWidth: 2)
                        .scaleEffect(1.8)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: color)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch state {
        case .connected: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .disconnected: return .secondary.opacity(0.5)
        }
    }
}
