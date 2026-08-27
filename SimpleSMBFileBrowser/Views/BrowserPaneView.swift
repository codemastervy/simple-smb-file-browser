import SwiftUI

/// One browser pane. Identical for SMB shares and Device Files locations,
/// which is the point of `FileProviding`.
struct BrowserPaneView: View {
    @Bindable var model: AppModel
    @Bindable var browser: FileBrowserViewModel
    /// Shown in the pane header when two panes are visible.
    var showsPaneHeader = false
    /// Namespace for this pane's element identifiers. Defaults to "browser", so a
    /// single pane exposes "browser.list" / "browser.grid"; the dual-pane layout
    /// passes "browser.primary" / "browser.secondary" so the two panes are
    /// distinguishable and a drop target is unambiguous.
    ///
    /// The identifier goes on the list and grid, not on a wrapper: putting an
    /// accessibilityIdentifier on the containing view makes it one accessibility
    /// element and hides every child inside it.
    var paneIdentifier = "browser"
    var onClosePane: (() -> Void)?

    @State private var isSelecting = false
    @State private var activeAlert: PaneAlert?
    @State private var alertText = ""
    @State private var isImportingFiles = false
    @State private var destinationRequest: DestinationRequest?
    @State private var isDropTargeted = false

    /// The single alert this pane can present. See the .alert modifier below for
    /// why there is exactly one.
    enum PaneAlert: Identifiable {
        case newFolder
        case rename(FileItem)
        case delete([FileItem])

        var id: String {
            switch self {
            case .newFolder: return "newFolder"
            case .rename(let item): return "rename:\(item.path)"
            case .delete(let items): return "delete:" + items.map(\.path).joined(separator: "|")
            }
        }
    }

    struct DestinationRequest: Identifiable {
        let id = UUID()
        let items: [FileItem]
        let mode: TransferCoordinator.Mode
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsPaneHeader { paneHeader }
            navigationHeader
            content
        }
        .background(.background)
        .toolbar { paneToolbar }
        .searchable(text: $browser.searchText, prompt: searchPrompt)
        .onChange(of: browser.searchText) { _, _ in
            // Recursive search happens provider-side, so a query change has to
            // re-list rather than just re-filter.
            guard browser.recursiveSearch else { return }
            Task { await browser.searchModeChanged() }
        }
        .task(id: browser.location.id) { await browser.load() }
        .dropDestination(for: FileTransferPayload.self) { payloads, _ in
            handleDrop(payloads)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted { dropHighlight }
        }
        .sheet(item: $destinationRequest) { request in
            DestinationPickerView(
                provider: browser.provider,
                startingPath: browser.provider.rootPath,
                title: request.mode == .copy ? "Copy To" : "Move To"
            ) { directory in
                performTransfer(request.items, to: directory, mode: request.mode)
            }
        }
        // ONE alert modifier, routed by `activeAlert`.
        //
        // This was previously three stacked .alert modifiers on the same view.
        // SwiftUI does not reliably honour more than one presentation modifier
        // per view: on iPhone all three happened to work, but on iPad only the
        // first was ever presented, so New Folder worked and Rename and Delete
        // silently did nothing. Routing through a single modifier removes the
        // ambiguity entirely.
        .alert(
            alertTitle,
            isPresented: Binding(
                get: { activeAlert != nil },
                set: { if !$0 { dismissAlert() } }
            ),
            presenting: activeAlert
        ) { route in
            alertActions(for: route)
        } message: { route in
            alertMessage(for: route)
        }
        .fileImporter(
            isPresented: $isImportingFiles,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
    }

    // MARK: - Header

    private var paneHeader: some View {
        HStack {
            Label(browser.provider.label, systemImage: browser.provider.isRemote ? "externaldrive.connected.to.line.below" : "internaldrive")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer()
            if let onClosePane {
                Button {
                    onClosePane()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close pane")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassBar()
    }

    /// Breadcrumbs on iPad/Mac; a back button on iPhone, where a trail
    /// wouldn't fit.
    @ViewBuilder
    private var navigationHeader: some View {
        #if os(macOS)
        BreadcrumbBar(crumbs: browser.breadcrumbs) { path in
            Task { await browser.navigate(to: path) }
        }
        #else
        if UIDevice.current.userInterfaceIdiom == .pad {
            BreadcrumbBar(crumbs: browser.breadcrumbs) { path in
                Task { await browser.navigate(to: path) }
            }
        } else {
            HStack(spacing: 10) {
                if browser.canGoUp {
                    Button {
                        Task { await browser.goUp() }
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .labelStyle(.titleAndIcon)
                            .font(.callout)
                    }
                    .accessibilityIdentifier("browser.back")
                }
                Text(browser.breadcrumbs.last?.title ?? browser.provider.label)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassBar()
        }
        #endif
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        ZStack {
            if browser.viewMode == .list {
                listView
            } else {
                gridView
            }

            if browser.isLoading, browser.items.isEmpty {
                ProgressView("Connecting…")
                    .padding(24)
                    .glassPanel()
                    .accessibilityIdentifier("browser.loading")
            } else if browser.isEmptyDirectory {
                emptyState
            }
        }
        // safeAreaInset rather than overlay. An overlay sits on top of the
        // List's own scroll content, which covers the last row and — on iPad —
        // left the buttons reachable by accessibility but not actually firing
        // their actions. An inset reserves real layout space for the bar.
        .safeAreaInset(edge: .bottom) {
            if isSelecting, !browser.selection.isEmpty { batchActionBar }
        }
        // Local failures appear inline; remote ones are escalated below.
        .safeAreaInset(edge: .top) {
            if let failure = browser.failure, !browser.provider.isRemote {
                failureBanner(failure)
            }
        }
        // Any failure from a remote provider — a failed listing, delete, rename
        // or folder creation, not just the initial connect — raises the
        // full-screen modal, which is where the recovery actions live. Without
        // this the view model recorded failures that nothing ever displayed.
        .onChange(of: browser.failure) { _, failure in
            guard let failure, browser.provider.isRemote else { return }
            model.presentedFailure = AppModel.PresentedFailure(
                failure: failure,
                serverID: browser.location.serverID
            )
            browser.clearFailure()
        }
    }

    /// Inline error for on-device locations, where a full-screen connection
    /// modal would be nonsense — there is no connection to retry.
    private func failureBanner(_ failure: BrowseFailure) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: failure.symbolName)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(failure.title)
                    .font(.footnote.weight(.semibold))
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                browser.clearFailure()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassPanel(cornerRadius: 14)
        .softDepth()
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .accessibilityIdentifier("browser.errorBanner")
    }

    private var listView: some View {
        List(selection: isSelecting ? $browser.selection : .constant([])) {
            ForEach(browser.displayedItems) { item in
                FileRowView(item: item, isSelected: browser.selection.contains(item.id))
                    .onTapGesture { handleTap(item) }
                    .contextMenu { itemMenu(item) }
                    .draggable(payload(for: item))
                    .tag(item.id)
            }
        }
        .listStyle(.inset)
        #if !os(macOS)
        .refreshable { await browser.refresh() }
        #endif
        .accessibilityIdentifier("\(paneIdentifier).list")
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 108, maximum: 180), spacing: 12)],
                spacing: 12
            ) {
                ForEach(browser.displayedItems) { item in
                    FileGridCell(item: item, isSelected: browser.selection.contains(item.id))
                        .onTapGesture { handleTap(item) }
                        .contextMenu { itemMenu(item) }
                        .draggable(payload(for: item))
                }
            }
            .padding(14)
        }
        #if !os(macOS)
        .refreshable { await browser.refresh() }
        #endif
        .accessibilityIdentifier("\(paneIdentifier).grid")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                browser.searchText.isEmpty ? "Empty Folder" : "No Matches",
                systemImage: browser.searchText.isEmpty ? "folder" : "magnifyingglass"
            )
        } description: {
            Text(browser.searchText.isEmpty
                 ? "Nothing here yet. Upload a file or create a folder."
                 : "Nothing in this folder matches “\(browser.searchText)”.")
        } actions: {
            if browser.searchText.isEmpty {
                Button("New Folder") { activeAlert = .newFolder }
                    .glassButton()
            }
        }
        .accessibilityIdentifier("browser.empty")
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
            .padding(6)
            .allowsHitTesting(false)
    }

    // MARK: - Batch actions

    private var batchActionBar: some View {
        HStack(spacing: 18) {
            Text("\(browser.selection.count) selected")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                destinationRequest = DestinationRequest(items: browser.selectedItems, mode: .copy)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button {
                destinationRequest = DestinationRequest(items: browser.selectedItems, mode: .move)
            } label: {
                Label("Move", systemImage: "folder")
            }
            Button {
                downloadSelected()
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .disabled(!browser.provider.isRemote)
            Button(role: .destructive) {
                activeAlert = .delete(browser.selectedItems)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier("browser.batchDelete")
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassPanel()
        .softDepth()
        .padding(14)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var paneToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                isSelecting.toggle()
                if !isSelecting { browser.selection.removeAll() }
            } label: {
                Label(isSelecting ? "Done" : "Select", systemImage: "checkmark.circle")
            }
            .accessibilityIdentifier("browser.select")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                browser.viewMode = browser.viewMode.toggled
            } label: {
                Label("View", systemImage: browser.viewMode.toggled.symbolName)
            }
            .keyboardShortcut("1", modifiers: .command)
            .accessibilityIdentifier("browser.viewMode")
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Sort By", selection: $browser.sort.field) {
                    ForEach(SortField.allCases, id: \.self) { field in
                        Label(field.title, systemImage: field.symbolName).tag(field)
                    }
                }
                Divider()
                Picker("Order", selection: $browser.sort.direction) {
                    Label("Ascending", systemImage: "chevron.up").tag(SortDirection.ascending)
                    Label("Descending", systemImage: "chevron.down").tag(SortDirection.descending)
                }
                Divider()
                Toggle("Search Subfolders", isOn: $browser.recursiveSearch)
                    .onChange(of: browser.recursiveSearch) { _, _ in
                        Task { await browser.searchModeChanged() }
                    }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .accessibilityIdentifier("browser.sort")
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    activeAlert = .newFolder
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                Button {
                    isImportingFiles = true
                } label: {
                    Label("Upload Files…", systemImage: "arrow.up.doc")
                }
                .keyboardShortcut("u", modifiers: .command)
            } label: {
                Label("Add", systemImage: "plus")
            }
            .accessibilityIdentifier("browser.add")
        }

        #if os(macOS)
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await browser.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .accessibilityIdentifier("browser.refresh")
        }
        #endif
    }

    // MARK: - Item menu

    @ViewBuilder
    private func itemMenu(_ item: FileItem) -> some View {
        if item.isDirectory {
            Button {
                Task { await browser.open(item) }
            } label: {
                Label("Open", systemImage: "folder")
            }
        } else {
            Button {
                model.preview.preview(item, using: browser.provider)
            } label: {
                Label("Quick Look", systemImage: "eye")
            }
        }

        if browser.provider.isRemote {
            Button {
                download([item])
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        }

        Divider()

        Button {
            alertText = item.name
            activeAlert = .rename(item)
        } label: {
            Label("Rename…", systemImage: "pencil")
        }
        Button {
            destinationRequest = DestinationRequest(items: [item], mode: .copy)
        } label: {
            Label("Copy To…", systemImage: "doc.on.doc")
        }
        Button {
            destinationRequest = DestinationRequest(items: [item], mode: .move)
        } label: {
            Label("Move To…", systemImage: "folder")
        }

        Divider()

        Button(role: .destructive) {
            activeAlert = .delete([item])
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .keyboardShortcut(.delete, modifiers: .command)
    }

    // MARK: - Actions

    private func handleTap(_ item: FileItem) {
        if isSelecting {
            if browser.selection.contains(item.id) {
                browser.selection.remove(item.id)
            } else {
                browser.selection.insert(item.id)
            }
            return
        }
        if item.isDirectory {
            Task { await browser.open(item) }
        } else {
            model.preview.preview(item, using: browser.provider)
        }
    }

    private func payload(for item: FileItem) -> FileTransferPayload {
        // Dragging an item that is part of the current selection drags the whole
        // selection, which is what every file manager does.
        let dragged = browser.selection.contains(item.id) ? browser.selectedItems : [item]
        return FileTransferPayload(
            sourceProviderID: browser.provider.providerID,
            sourcePaneID: browser.paneID,
            items: dragged.map(FileTransferPayload.Item.init)
        )
    }

    private func handleDrop(_ payloads: [FileTransferPayload]) {
        for payload in payloads {
            // A drag released back onto its own pane is a no-op. A drop from the
            // *other* pane always transfers, even into the same directory, where
            // it produces a de-duplicated copy.
            guard payload.sourcePaneID != browser.paneID else { continue }
            guard let source = model.provider(withID: payload.sourceProviderID) else { continue }
            let items = payload.fileItems
            let destination = browser.provider
            let directory = browser.path
            Task {
                await model.transferCoordinator.transfer(
                    items, from: source, to: destination,
                    destinationDirectory: directory, mode: .copy
                )
                await browser.refresh()
            }
        }
    }

    private func handleImport(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        let destination = browser.provider
        let directory = browser.path
        Task {
            for url in urls {
                // Document-picker URLs are security-scoped; access must be
                // opened explicitly and closed after, or the read fails.
                let needsScope = url.startAccessingSecurityScopedResource()
                defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                let transferID = model.transfers.begin(
                    fileName: url.lastPathComponent,
                    direction: .upload,
                    destinationLabel: destination.label,
                    totalBytes: size
                )
                let progress = model.transfers.progressHandler(for: transferID)
                let target = destination.joining(url.lastPathComponent, to: directory)
                do {
                    try await destination.importItem(from: url, to: target, progress: progress)
                    model.transfers.finish(transferID, state: .completed)
                } catch {
                    model.transfers.finish(
                        transferID,
                        state: .failed(BrowseFailure(error: error, target: destination.label))
                    )
                }
            }
            await browser.refresh()
        }
    }

    private func downloadSelected() {
        download(browser.selectedItems)
        isSelecting = false
    }

    private func download(_ items: [FileItem]) {
        guard !items.isEmpty, let destination = model.downloadDestination() else { return }
        let source = browser.provider
        Task {
            await model.transferCoordinator.transfer(
                items, from: source, to: destination.provider,
                destinationDirectory: destination.directory, mode: .copy
            )
        }
    }

    private func performTransfer(
        _ items: [FileItem],
        to directory: String,
        mode: TransferCoordinator.Mode
    ) {
        let provider = browser.provider
        Task {
            await model.transferCoordinator.transfer(
                items, from: provider, to: provider,
                destinationDirectory: directory, mode: mode
            )
            browser.selection.removeAll()
            isSelecting = false
            await browser.refresh()
        }
    }

    // MARK: - Alert routing

    private var alertTitle: String {
        switch activeAlert {
        case .newFolder: return "New Folder"
        case .rename: return "Rename"
        case .delete(let items):
            return items.count == 1
                ? "Delete \u{201C}\(items[0].name)\u{201D}?"
                : "Delete \(items.count) items?"
        case nil: return ""
        }
    }

    @ViewBuilder
    private func alertActions(for route: PaneAlert) -> some View {
        switch route {
        case .newFolder:
            TextField("Folder name", text: $alertText)
                .accessibilityIdentifier("alert.textField")
            Button("Cancel", role: .cancel) { dismissAlert() }
            Button("Create") {
                let name = alertText
                dismissAlert()
                Task { await browser.createFolder(named: name) }
            }
        case .rename(let item):
            TextField("Name", text: $alertText)
                .accessibilityIdentifier("alert.textField")
            Button("Cancel", role: .cancel) { dismissAlert() }
            Button("Rename") {
                let name = alertText
                dismissAlert()
                Task { await browser.rename(item, to: name) }
            }
        case .delete(let items):
            Button("Delete", role: .destructive) {
                dismissAlert()
                isSelecting = false
                Task { await browser.delete(items) }
            }
            Button("Cancel", role: .cancel) { dismissAlert() }
        }
    }

    @ViewBuilder
    private func alertMessage(for route: PaneAlert) -> some View {
        switch route {
        case .newFolder:
            Text("Create a folder in \(browser.breadcrumbs.last?.title ?? browser.provider.label).")
        case .rename:
            EmptyView()
        case .delete(let items):
            Text(items.count == 1
                 ? "This can't be undone."
                 : "These \(items.count) items will be deleted. This can't be undone.")
        }
    }

    private func dismissAlert() {
        activeAlert = nil
        alertText = ""
    }

    // MARK: - Small helpers

    private var searchPrompt: String {
        browser.recursiveSearch ? "Search this folder and subfolders" : "Search this folder"
    }
}
