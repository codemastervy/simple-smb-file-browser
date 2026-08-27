import SwiftUI

/// One browser pane. Identical for SMB shares and Device Files locations,
/// which is the point of `FileProviding`.
struct BrowserPaneView: View {
    @Bindable var model: AppModel
    @Bindable var browser: FileBrowserViewModel
    /// Shown in the pane header when two panes are visible.
    var showsPaneHeader = false
    /// Distinguishes the two panes for accessibility and UI tests; a shared
    /// identifier would make a drop target ambiguous.
    var paneIdentifier = "browser.pane"
    var onClosePane: (() -> Void)?

    @State private var isSelecting = false
    @State private var renameTarget: FileItem?
    @State private var renameText = ""
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var pendingDeletion: [FileItem] = []
    @State private var isConfirmingDelete = false
    @State private var isImportingFiles = false
    @State private var destinationRequest: DestinationRequest?
    @State private var isDropTargeted = false

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
        .alert("New Folder", isPresented: $isCreatingFolder) {
            TextField("Folder name", text: $newFolderName)
                .accessibilityIdentifier("newFolder.nameField")
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") {
                let name = newFolderName
                newFolderName = ""
                Task { await browser.createFolder(named: name) }
            }
        } message: {
            Text("Create a folder in \(browser.breadcrumbs.last?.title ?? browser.provider.label).")
        }
        .alert("Rename", isPresented: renameBinding) {
            TextField("Name", text: $renameText)
                .accessibilityIdentifier("rename.nameField")
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") {
                if let target = renameTarget {
                    let name = renameText
                    Task { await browser.rename(target, to: name) }
                }
                renameTarget = nil
            }
        }
        // An alert rather than a confirmationDialog. On iOS 26 the dialog's
        // .cancel-role button is not exposed to the accessibility tree at all —
        // verified by dumping the element hierarchy while it was presented —
        // which leaves a VoiceOver user unable to cancel a destructive action.
        // An alert exposes both buttons properly and reads correctly on macOS too.
        .alert(deletionPrompt, isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) {
                let doomed = pendingDeletion
                pendingDeletion = []
                isSelecting = false
                Task { await browser.delete(doomed) }
            }
            Button("Cancel", role: .cancel) { pendingDeletion = [] }
        } message: {
            Text(pendingDeletion.count == 1
                 ? "This can't be undone."
                 : "These \(pendingDeletion.count) items will be deleted. This can't be undone.")
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
        .overlay(alignment: .bottom) {
            if isSelecting, !browser.selection.isEmpty { batchActionBar }
        }
        .accessibilityIdentifier(paneIdentifier)
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
        .accessibilityIdentifier("browser.list")
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
        .accessibilityIdentifier("browser.grid")
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
                Button("New Folder") { isCreatingFolder = true }
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
                pendingDeletion = browser.selectedItems
                isConfirmingDelete = true
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
                    isCreatingFolder = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                Button {
                    isImportingFiles = true
                } label: {
                    Label("Upload Files…", systemImage: "arrow.up.doc")
                }
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
            renameText = item.name
            renameTarget = item
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
            pendingDeletion = [item]
            isConfirmingDelete = true
        } label: {
            Label("Delete", systemImage: "trash")
        }
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

    // MARK: - Small helpers

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }

    private var deletionPrompt: String {
        if pendingDeletion.count == 1 {
            return "Delete “\(pendingDeletion[0].name)”?"
        }
        return "Delete \(pendingDeletion.count) items?"
    }

    private var searchPrompt: String {
        browser.recursiveSearch ? "Search this folder and subfolders" : "Search this folder"
    }
}
