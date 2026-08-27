import SwiftUI

/// App shell: persistent sidebar plus the browser detail column.
///
/// The app opens straight into the browser — there is no onboarding screen.
/// When nothing is configured yet, the prompt to add a server appears inline in
/// the detail column rather than as a blocking modal.
struct RootView: View {
    // UITestSupport returns a plain AppModel unless the process was launched
    // with -uiTesting, so this is a no-op in normal use.
    @State private var model = UITestSupport.makeAppModel()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(model: model)
        } detail: {
            DetailView(model: model)
        }
        .task {
            await model.performLaunchConnect()
        }
        .sheet(isPresented: $model.isAddingServer) {
            ServerFormView(model: model)
        }
        .sheet(item: $model.editingServer) { profile in
            ServerFormView(model: model, existing: profile)
        }
        .sheet(isPresented: $model.isShowingSettings) {
            SettingsView(model: model)
        }
        .sheet(isPresented: $model.isShowingTransfers) {
            TransfersPanel(model: model)
        }
        .fullScreenFailure(item: $model.presentedFailure) { presented in
            ConnectionFailureView(
                model: model,
                failure: presented.failure,
                serverID: presented.serverID
            )
        }
        .filePreview(model.preview)
    }
}

/// Detail column: one pane, two panes, or the inline setup prompt.
struct DetailView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if let location = model.selectedLocation, let browser = model.browser(for: location) {
                if model.isDualPaneEnabled,
                   let secondary = model.secondaryLocation,
                   let secondaryBrowser = model.browser(for: secondary) {
                    dualPane(primary: browser, secondary: secondaryBrowser)
                } else {
                    BrowserPaneView(model: model, browser: browser)
                }
            } else if model.hasNoServers {
                AddFirstServerPrompt(model: model)
            } else {
                ContentUnavailableView(
                    "Choose a Location",
                    systemImage: "sidebar.left",
                    description: Text("Pick a server or a Device Files location from the sidebar.")
                )
            }
        }
        .overlay(alignment: .bottom) {
            if !model.transfers.active.isEmpty { activeTransfersBar }
        }
    }

    /// Side-by-side panes for iPad and Mac, so files can be dragged between two
    /// shares, or a share and Device Files.
    private func dualPane(
        primary: FileBrowserViewModel,
        secondary: FileBrowserViewModel
    ) -> some View {
        HStack(spacing: 0) {
            BrowserPaneView(
                model: model, browser: primary,
                showsPaneHeader: true,
                paneIdentifier: "browser.primary"
            )
            Divider()
            BrowserPaneView(
                model: model,
                browser: secondary,
                showsPaneHeader: true,
                paneIdentifier: "browser.secondary",
                onClosePane: { model.closeSecondPane() }
            )
        }
    }

    /// Compact always-visible progress strip; tapping opens the full panel.
    private var activeTransfersBar: some View {
        Button {
            model.isShowingTransfers = true
        } label: {
            HStack(spacing: 12) {
                if let fraction = model.transfers.overallFraction {
                    ProgressView(value: fraction)
                        .frame(width: 90)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(transfersSummary)
                    .font(.footnote.weight(.medium))
                Spacer(minLength: 8)
                Image(systemName: "chevron.up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .glassPanel()
        .softDepth()
        .padding(14)
        .accessibilityIdentifier("transfers.miniBar")
    }

    private var transfersSummary: String {
        let count = model.transfers.active.count
        return count == 1
            ? (model.transfers.active.first?.fileName ?? "1 transfer")
            : "\(count) transfers"
    }
}

/// Inline first-run prompt. Not a modal: the requirement is that the browser is
/// what launches, with setup offered in place.
struct AddFirstServerPrompt: View {
    @Bindable var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("No SMB Servers Yet", systemImage: "externaldrive.badge.plus")
        } description: {
            Text("Add a connection to start browsing a share. You can also open Device Files in the sidebar to browse iCloud Drive or this device.")
        } actions: {
            Button {
                model.isAddingServer = true
            } label: {
                Label("Add SMB Server", systemImage: "plus")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("detail.addFirstServer")

            Button("Browse Device Files") {
                model.isDeviceFilesExpanded = true
                model.selectedLocation = .device(.onMyDevice)
            }
            .accessibilityIdentifier("detail.browseDeviceFiles")
        }
        .accessibilityIdentifier("detail.noServers")
    }
}

// MARK: - Full-screen presentation

extension View {
    /// Presents `content` full-screen. `fullScreenCover` is iOS-only, so macOS
    /// gets a sheet, which is that platform's equivalent modal.
    @ViewBuilder
    func fullScreenFailure<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        #if os(macOS)
        sheet(item: item, content: content)
        #else
        fullScreenCover(item: item, content: content)
        #endif
    }
}
